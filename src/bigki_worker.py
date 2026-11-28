#!/usr/bin/env python3
"""Restricted, stdin-driven worker for the user's existing bigki installation."""
import base64
import fcntl
import random
import re
from collections import deque
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import threading
import queue
import socket
import time
import uuid

ROOT = Path.home() / 'hunyuan3d-2mv'
VIEWS = ('front', 'left', 'back', 'right')
MAX_IMAGE = 25 * 1024 * 1024
MAX_REQUEST = 150 * 1024 * 1024
KEEP_JOBS_SECONDS = 2 * 24 * 3600
ROCM = Path.home() / '.local' / 'opt' / 'rocm-gfx906-7.14'
BASE = Path.home() / '.local' / 'share' / '3d-modelle-app'
BROKER = Path(__file__).with_name('gpu_broker.py')
CPU_THREADS = '6'  # bigki has 12 threads; CPU stages run at nice 15 next to Blender
cancelled = threading.Event()
active = set()
active_lock = threading.Lock()
emit_lock = threading.Lock()
# Blender renders with a pickup ticket keep running when the connection to the Mac drops (Tailscale hiccup):
# output is then dropped and the result waits in blender/<session>/abholung/<ticket>/ for action "abholen".
detachable = threading.Event()
detached = threading.Event()
aborted = threading.Event()


def emit(kind, **fields):
    if detached.is_set():
        return
    line = json.dumps({'type': kind, **fields}, ensure_ascii=False)
    with emit_lock:
        try:
            print(line, flush=True)
        except (BrokenPipeError, OSError):
            if not detachable.is_set():
                raise
            detached.set()


def clean_origin(request):
    origin = request.get('origin')
    return re.sub(r'[^\w .·()/+-]', '', origin)[:60] if isinstance(origin, str) else 'StudioPortal'


def stop_running():
    cancelled.set()
    with active_lock:
        children = list(active)
    for child in children:
        if child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass


def watch_connection():
    """stdin after the request: "abbrechen" = the user cancelled; end of input without it = connection gone
    (a ticketed render then keeps running and is collected later)."""
    seen = b''
    try:
        while True:
            chunk = os.read(0, 256)
            if not chunk:
                break
            seen = (seen + chunk)[-64:]
            if b'abbrechen' in seen:
                aborted.set()
                break
    except OSError:
        pass
    finally:
        if detachable.is_set() and not aborted.is_set():
            detached.set()
        else:
            stop_running()


def remove_outputs(outputs):
    for path in outputs:
        try:
            path.unlink()
        except FileNotFoundError:
            pass


def prune_old_jobs(jobs):
    limit = time.time() - KEEP_JOBS_SECONDS
    for job in jobs.glob('auftrag-*'):
        try:
            if job.is_dir() and not job.is_symlink() and job.stat().st_mtime < limit:
                shutil.rmtree(job)
        except OSError:
            pass


def no_core_dumps():
    try:
        import resource
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    except (ImportError, ValueError, OSError):
        pass


# ---------------------------------------------------------------- card broker
def broker_version():
    return hashlib.sha256(BROKER.read_bytes()).hexdigest()[:16]


def broker_socket(start=True):
    """Connects to the card broker on bigki and starts it when needed."""
    path = BASE / 'broker.sock'
    for attempt in range(60):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(str(path))
            return sock
        except OSError:
            sock.close()
        if not start:
            return None
        if attempt == 0:
            BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
            log = (BASE / 'broker.log').open('ab')
            subprocess.Popen([sys.executable, str(BROKER)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=log, start_new_session=True, close_fds=True)
            log.close()
        time.sleep(0.2)
    raise RuntimeError('Der Kartenverteiler auf bigki konnte nicht gestartet werden.')


class Broker:
    """One connection to the card broker = one place in the queue (kept across the stages of a job)."""

    def __init__(self, ticket, kind, label, origin):
        self.ticket, self.kind, self.label, self.origin = ticket, kind, label, origin
        self.sock = broker_socket()
        self.events = queue.Queue()
        self.reader = self.sock.makefile('rb')
        self.send(op='hello')
        hello = self.next(10)
        if hello and hello.get('version') != broker_version():
            # an older broker: replace it when it has nothing to do, otherwise keep using it
            self.send(op='shutdown')
            if (self.next(10) or {}).get('ev') == 'bye':
                self.close()
                for _ in range(50):
                    if broker_socket(start=False) is None:
                        break
                    time.sleep(0.1)
                self.sock = broker_socket()
                self.events = queue.Queue()
                self.reader = self.sock.makefile('rb')
        threading.Thread(target=self.read, daemon=True).start()

    def next(self, timeout):
        """Synchronous read before the reader thread runs."""
        self.sock.settimeout(timeout)
        try:
            line = self.reader.readline()
        except OSError:
            line = b''
        self.sock.settimeout(None)
        return json.loads(line) if line else None

    def read(self):
        try:
            for line in self.reader:
                try:
                    self.events.put(json.loads(line))
                except ValueError:
                    pass
        except OSError:
            pass
        self.events.put(None)

    def send(self, **message):
        self.sock.sendall((json.dumps(message) + '\n').encode())

    def acquire(self, cards, on_wait):
        self.send(op='acquire', cards=cards, ticket=self.ticket, kind=self.kind, label=self.label, origin=self.origin)
        while True:
            if cancelled.is_set():
                raise RuntimeError('Abgebrochen.')
            try:
                event = self.events.get(timeout=0.5)
            except queue.Empty:
                continue
            if event is None:
                raise RuntimeError('Der Kartenverteiler auf bigki wurde beendet.')
            if event.get('ev') == 'granted':
                return event['cards']
            if event.get('ev') == 'waiting':
                on_wait(event.get('reason') or 'Warte auf freie Grafikkarten.', event.get('position'))
            if event.get('ev') == 'error':
                raise RuntimeError(event.get('message', 'Kartenverteiler-Fehler.'))

    def revoked(self, timeout):
        deadline = time.time() + timeout
        while True:
            try:
                event = self.events.get(timeout=max(0.01, deadline - time.time()))
            except queue.Empty:
                return None
            if event is None:
                return None
            if event.get('ev') == 'revoked':
                return event
            if time.time() >= deadline:
                return None

    def release(self):
        try:
            self.send(op='release')
        except OSError:
            pass

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def stream_output(child, on_line):
    """Lines from a child (progress bars use carriage returns)."""
    pending = ''
    while True:
        chunk = child.stdout.read1(65536)
        if not chunk:
            break
        pending += chunk.decode('utf-8', 'replace')
        parts = pending.replace('\r', '\n').split('\n')
        pending = parts.pop()
        for line in parts:
            if line.strip():
                on_line(line.strip())
    if pending.strip():
        on_line(pending.strip())


def heat_error(event):
    temps = [t for t in (event.get('temps') or []) if t is not None]
    detail = f' ({max(temps)} °C)' if temps else ''
    return RuntimeError(f'Abbruch zum Schutz der Grafikkarten: Hotspot ≥ 92 °C oder Sensorfehler{detail}.')


def run_on_cards(broker, cards, make, on_wait, on_line=lambda line: None, outputs=(), on_restart=None):
    """Runs a GPU step on cards from the broker. Restarts automatically when a foreign job takes the card.
    Returns (exit code, last output lines)."""
    while True:
        remove_outputs(outputs)
        granted = broker.acquire(cards, on_wait)
        command, env, cwd = make(granted)
        tail = deque(maxlen=12)
        child = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, start_new_session=True, preexec_fn=no_core_dumps)
        with active_lock:
            active.add(child)
        try:
            broker.send(op='run', pid=child.pid)
            if cancelled.is_set():
                stop_running()

            def line_seen(line):
                tail.append(line[-500:])
                on_line(line)
            stream_output(child, line_seen)
            code = child.wait()
        finally:
            with active_lock:
                active.discard(child)
        if cancelled.is_set():
            broker.release()
            raise RuntimeError('Abgebrochen.')
        event = None if code == 0 else broker.revoked(1.5)
        if event is None:
            broker.release()
            return code, ' '.join(tail)[-900:]
        if event.get('reason') == 'heat':
            raise heat_error(event)
        if on_restart:
            on_restart()


def rocm_env(cards):
    env = os.environ.copy()
    for key in ('LD_LIBRARY_PATH', 'HSA_OVERRIDE_GFX_VERSION', 'HIP_VISIBLE_DEVICES', 'CUDA_VISIBLE_DEVICES'):
        env.pop(key, None)
    env['ROCR_VISIBLE_DEVICES'] = ','.join(str(c) for c in sorted(cards))
    return env


def host_cpu_info():
    """CPU load, frequency (MHz) and scaling governor on bigki (read-only /sys & /proc)."""
    info = {'cores': os.cpu_count() or 0}
    try:
        info['loadavg'] = [round(x, 2) for x in os.getloadavg()]
    except OSError:
        pass
    cpu_root = Path('/sys/devices/system/cpu')
    try:
        govs = sorted({p.read_text(encoding='utf-8').strip()
                       for p in cpu_root.glob('cpu*/cpufreq/scaling_governor') if p.is_file()})
        if govs:
            info['governor'] = govs[0] if len(govs) == 1 else ','.join(govs)
    except OSError:
        pass
    try:
        epps = sorted({p.read_text(encoding='utf-8').strip()
                       for p in cpu_root.glob('cpu*/cpufreq/energy_performance_preference') if p.is_file()})
        if epps:
            info['epp'] = epps[0] if len(epps) == 1 else ','.join(epps)
    except OSError:
        pass
    try:
        freqs = [int(p.read_text(encoding='utf-8').strip()) // 1000
                 for p in cpu_root.glob('cpu*/cpufreq/scaling_cur_freq') if p.is_file()]
        if freqs:
            info['freq_mhz_min'] = min(freqs)
            info['freq_mhz_max'] = max(freqs)
            info['freq_mhz_avg'] = round(sum(freqs) / len(freqs))
    except (OSError, ValueError):
        pass
    return info


def running_sessions():
    """Blender sessions that are running now (CPU/RAM only): name, memory, current command – for the Rechner page."""
    result = []
    for sock in sorted(BLENDER_ROOT.glob('*/sitzung.sock')):
        folder = sock.parent
        entry = {'name': folder.name}
        try:
            status = json.loads((folder / 'status.json').read_text(encoding='utf-8'))
        except (OSError, ValueError):
            status = {}
        pid = status.get('pid')
        if not (isinstance(pid, int) and Path(f'/proc/{pid}').exists()):
            continue
        try:
            pages = int(Path(f'/proc/{pid}/statm').read_text().split()[1])
            entry['memory_gb'] = round(pages * os.sysconf('SC_PAGE_SIZE') / 1e9, 1)
        except (OSError, ValueError, IndexError):
            pass
        try:
            current = json.loads((folder / 'laeuft.json').read_text(encoding='utf-8'))
            entry['current'] = current.get('command')
        except (OSError, ValueError):
            pass
        history = status.get('history') or []
        if history:
            entry['last'] = history[-1].get('time')
        entry['objects'] = status.get('object_count')
        if status.get('blender'):
            entry['blender'] = status.get('blender')
        if status.get('build_type'):
            entry['build_type'] = status.get('build_type')
        result.append(entry)
    return result


def machine_status():
    cpu = host_cpu_info()
    try:
        sys.path.insert(0, str(BROKER.parent))
        import gpu_broker
    except Exception as error:  # noqa: BLE001
        emit('machine', cards=[], queue=[], lock='unknown', cpu=cpu, error=str(error)[:200])
        return
    sock = broker_socket(start=False)
    if sock is not None:
        try:
            sock.settimeout(10)
            sock.sendall(b'{"op":"status"}\n')
            reply = json.loads(sock.makefile('rb').readline())
            emit('machine', cards=reply.get('cards', []), queue=reply.get('queue', []), lock=reply.get('lock'),
                 sessions=running_sessions(), cpu=cpu)
            return
        except (OSError, ValueError):
            pass
        finally:
            sock.close()
    broker = gpu_broker.Broker()
    broker.sample = broker.hw.sample()
    status = broker.status()
    emit('machine', cards=status['cards'], queue=[], lock=status['lock'], sessions=running_sessions(), cpu=cpu)


H3 = Path.home() / 'h3-image'
H3_FORBIDDEN = ('-o', '--output', '--preview', '--preview-path', '--imat-out', '-r', '--ref-image')
PNG_MAGIC = b'\x89PNG\r\n\x1a\n'
H3_FORBIDDEN = ('-o', '--output', '--preview', '--preview-path', '--imat-out', '-r', '--ref-image')
SD_CLI = Path.home() / 'sdcpp-h3image' / 'src' / 'build-hip' / 'bin' / 'sd-cli'
H3_MODELS = (('--diffusion-model', H3 / 'models' / 'minimax_h3_image_pruned-Q8_0.gguf'),
             ('--vae', H3 / 'models' / 'vae' / 'minimax_h3_image_vae_fp16.safetensors'),
             ('--llm', Path.home() / 'sdcpp-mi50' / 'models' / 'qwen3vl_32b_minimax_h3-from-nvfp4-Q8_0.gguf'))


def h3_forbidden(value):
    if any(value == item or value.startswith(item + '=') for item in H3_FORBIDDEN):
        return True
    return value.startswith('-') and not value.startswith('--') and value[1:2] in ('o', 'r')


def h3_command(prompt, args, references, output, tiling):
    """Same defaults as ~/h3-image/h3-image.sh, but on cards from the broker."""
    sigma = [] if any(a in ('--steps', '--scheduler', '--sigmas') for a in args) else ['--sigmas', 'minimax-h3-image']
    placement = []
    if not any(a in ('--backend', '--clip-on-cpu', '--vae-on-cpu', '--control-net-cpu') for a in args):
        placement += ['--backend', 'te=ROCm0,diffusion=ROCm0&ROCm1&ROCm2,vae=ROCm2']
    if not any(a in ('--params-backend', '--offload-to-cpu', '--auto-fit') for a in args):
        placement += ['--params-backend', 'te=disk']
    if '--split-mode' not in args:
        placement += ['--split-mode', 'layer']
    command = [str(SD_CLI)]
    for flag, path in H3_MODELS:
        command += [flag, str(path)]
    command += ['-p', prompt, '--cfg-scale', '1.0', '--steps', '6', '--sampling-method', 'euler'] + sigma
    command += ['-W', '1024', '-H', '1024', '--rng', 'cpu', '--seed', '771', '--diffusion-fa']
    command += (['--vae-tiling'] if tiling else []) + ['-o', str(output), '-v'] + placement + args
    for path in references:
        command += ['-r', str(path)]
    return command


def send_file(path):
    size = path.stat().st_size
    emit('begin', size=size, name=path.name)
    digest = hashlib.sha256()
    with path.open('rb') as source:
        while True:
            data = source.read(192 * 1024)
            if not data or detached.is_set():
                break
            if cancelled.is_set():
                raise RuntimeError('Abgebrochen.')
            digest.update(data)
            emit('data', data=base64.b64encode(data).decode('ascii'))
    emit('filedone', sha256=digest.hexdigest(), name=path.name)


def serve_h3(request):
    prompt, args, count = request.get('prompt'), request.get('args'), request.get('count')
    references = request.get('references') or []
    tiling = request.get('vaeTiling') is not False
    origin = clean_origin(request)
    if not isinstance(prompt, str) or not prompt.strip() or '\0' in prompt or len(prompt) > 20000:
        raise ValueError('Bitte gib eine gültige Bildbeschreibung ein.')
    if not isinstance(args, list) or len(args) > 200 or not all(isinstance(a, str) and '\0' not in a and len(a) < 4000 for a in args):
        raise ValueError('Ungültige Einstellungen.')
    if any(h3_forbidden(a) for a in args):
        raise ValueError('Ausgabe- und Referenzpfade werden von StudioPortal verwaltet.')
    if not isinstance(count, int) or not 1 <= count <= 4:
        raise ValueError('Es sind ein bis vier Bilder möglich.')
    if not isinstance(references, list) or len(references) > 16:
        raise ValueError('Es sind höchstens 16 Referenzbilder möglich.')
    decoded = []
    for encoded in references:
        if not isinstance(encoded, str) or len(encoded) > ((MAX_IMAGE + 2) // 3) * 4:
            raise ValueError('Ein Referenzbild ist größer als 25 MB.')
        data = base64.b64decode(encoded, validate=True)
        if not data.startswith(PNG_MAGIC):
            raise ValueError('Referenzbilder müssen als PNG übertragen werden.')
        decoded.append(data)
    threading.Thread(target=watch_connection, daemon=True).start()
    if not SD_CLI.is_file():
        raise RuntimeError('Die H3-Installation wurde auf bigki nicht gefunden.')
    uid = uuid.uuid4().hex[:12]
    job = H3 / 'out' / f'studioportal-{uid}'
    job.mkdir(parents=True, mode=0o700)
    try:
        inputs = []
        for index, data in enumerate(decoded, 1):
            path = job / f'picture-{index}.png'
            path.write_bytes(data)
            inputs.append(path)
        del decoded, references, request
        name = f'studioportal-{time.strftime("%Y%m%d-%H%M%S")}-{uid}'
        output = job / (name + '.png')
        emit('run', name=name)
        broker = Broker(time.time_ns(), 'h3', f'Bild ({count}×)', origin)
        try:
            def make(cards):
                env = rocm_env(cards)
                env['LD_LIBRARY_PATH'] = f'{ROCM}/lib:{ROCM}/core-7.14/lib/llvm/lib'
                return h3_command(prompt, args, inputs, output, tiling), env, str(H3)

            def waiting(reason, position):
                emit('waiting', message=reason + ' Startet automatisch.')

            def restart():
                for leftover in job.glob(name + '*.png'):
                    leftover.unlink()
                emit('waiting', message='Ein anderer GPU-Auftrag hat Vorrang. StudioPortal startet danach neu …')

            code, last = run_on_cards(broker, 3, make, waiting, on_line=lambda line: emit('log', line=line[-600:]),
                                      on_restart=restart)
        finally:
            broker.close()
        if code != 0:
            raise RuntimeError(f'bigki konnte das Bild nicht erzeugen (Code {code}). {last}')
        results = sorted(p for p in job.glob(name + '*.png')
                         if p.name == name + '.png' or (p.name[len(name):len(name) + 1] == '_' and p.stem[len(name) + 1:].isdigit()))
        if len(results) != count:
            raise RuntimeError('bigki hat nicht alle angeforderten Bilder gespeichert.')
        emit('status', message='Bilder werden übertragen …')
        for path in results:
            send_file(path)
        emit('end', count=len(results))
    finally:
        shutil.rmtree(job, ignore_errors=True)


MUSIC = Path.home() / 'minimaxmusic.cpp'
MUSIC_JOBS = Path.home() / 'music3' / 'output' / 'studioportal'
MUSIC_ENV = ROCM / 'env.sh'
MUSIC_FIELDS = {'caption': str, 'lyrics': str, 'duration': (int, float), 'steps': int, 'seed': int, 'lm_seed': int,
                'lm_cfg': (int, float), 'lm_top_k': int, 'dit_cfg': (int, float), 'peak_clip': (int, float),
                'output_format': str, 'mp3_bitrate': int, 'audio_codes': str}
MUSIC_FORMATS = ('mp3', 'wav16', 'wav24', 'wav32')


def music_request(raw, replay):
    source = dict(replay) if replay is not None else {}
    for key, value in raw.items():
        if key in MUSIC_FIELDS:
            source[key] = value
    clean = {}
    for key, kind in MUSIC_FIELDS.items():
        if key not in source:
            continue
        value = source[key]
        if isinstance(value, bool) or not isinstance(value, kind):
            raise ValueError(f'Ungültiger Wert für {key}.')
        clean[key] = value
    for key in ('caption', 'lyrics'):
        if not clean.get(key, '').strip() or '\0' in clean[key] or len(clean[key]) > 20000:
            raise ValueError('Beschreibung und Songtext sind Pflicht.')
    if 'audio_codes' in clean and (replay is None or len(clean['audio_codes']) > 2_000_000):
        raise ValueError('audio_codes sind nur über eine Replay-Datei erlaubt.')
    clean['duration'] = float(clean.get('duration', 60.0))
    if not 5 <= clean['duration'] <= 360:
        raise ValueError('Die Länge muss zwischen 5 s und 6 min liegen.')
    if not 2 <= clean.get('steps', 30) <= 100:
        raise ValueError('Die Schritte müssen zwischen 2 und 100 liegen.')
    if clean.get('output_format', 'mp3') not in MUSIC_FORMATS:
        raise ValueError('Unbekanntes Ausgabeformat.')
    for key in ('lm_cfg', 'dit_cfg'):
        if key in clean and not 0 <= clean[key] <= 10:
            raise ValueError(f'{key} muss zwischen 0 und 10 liegen.')
    return clean


def music_examples():
    items = []
    for path in sorted((MUSIC / 'tools' / 'webui' / 'example').glob('*.json'))[:100]:
        try:
            data = json.loads(path.read_text())
            items.append({'name': path.stem, 'caption': str(data.get('caption', ''))[:8000],
                          'lyrics': str(data.get('lyrics', ''))[:8000], 'duration': data.get('duration', 60)})
        except (OSError, ValueError):
            pass
    emit('examples', items=items)


def music_phase(line):
    m = re.search(r'\[AR\] Frame (\d+)/(\d+)', line)
    if m:
        return 'AR', int(m.group(1)), int(m.group(2))
    m = re.search(r'\[DiT\] Window (\d+)/(\d+)', line)
    if m:
        return 'DiT', int(m.group(1)), int(m.group(2))
    if line.startswith('[VAE] Decod'):
        return 'VAE', None, None
    if line.startswith('[Request] Wrote'):
        return 'Fertig', None, None
    return None


def serve_music(raw):
    variants = raw.get('variants', 1)
    replays = raw.get('replays')
    if raw.get('replay') is not None:
        replays = [raw['replay']]
    origin = clean_origin(raw)
    if replays is not None:
        if not isinstance(replays, list) or not 1 <= len(replays) <= 3 or \
                not all(isinstance(r, dict) and 'audio_codes' in r for r in replays):
            raise ValueError('Ungültige Replay-Datei.')
        variants = len(replays)
        requests = [music_request(raw, replay) for replay in replays]
    else:
        if not isinstance(variants, int) or not 1 <= variants <= 3:
            raise ValueError('Es sind ein bis drei Varianten möglich.')
        request = music_request(raw, None)
        base_lm = request.get('lm_seed', -1)
        base_seed = request.get('seed', -1)
        base_lm = random.randrange(2 ** 31) if base_lm < 0 else base_lm
        base_seed = random.randrange(2 ** 31) if base_seed < 0 else base_seed
        requests = []
        for index in range(variants):
            item = dict(request)
            item['lm_seed'] = base_lm + index
            item['seed'] = base_seed + index
            requests.append(item)
    replay = replays
    threading.Thread(target=watch_connection, daemon=True).start()
    synth = MUSIC / 'build-hip906' / 'mm-synth'
    if not synth.is_file() or not MUSIC_ENV.is_file():
        raise RuntimeError('MiniMax Music wurde auf bigki nicht gefunden.')
    MUSIC_JOBS.mkdir(parents=True, exist_ok=True)
    job = MUSIC_JOBS / ('auftrag-' + uuid.uuid4().hex)
    job.mkdir(mode=0o700)
    ext = 'mp3' if requests[0].get('output_format', 'mp3') == 'mp3' else 'wav'
    ticket = time.time_ns()
    errors = [None] * variants
    title = 'Song voll' if replay is not None else 'Song'

    def variant(index):
        item = requests[index]
        req = job / f'request-{index + 1}.json'
        req.write_text(json.dumps(item))
        out = job / f'song-{index + 1}.{ext}'
        label = title if variants == 1 else f'{title} V{index + 1}'
        broker = Broker(ticket + index, 'music', label, origin)
        last = {}

        def make(cards):
            env = rocm_env([0, 1, 2])
            env.pop('ROCR_VISIBLE_DEVICES', None)
            env['HIP_VISIBLE_DEVICES'] = str(cards[0])
            command = ['/bin/bash', '-c', 'source "$1" && cd "$2" && exec build-hip906/mm-synth --models models --request "$3" --out "$4"',
                       '_', str(MUSIC_ENV), str(MUSIC), str(req), str(out)]
            emit('progress', variant=index + 1, phase='Start', current=None, total=None, card=cards[0])
            return command, env, str(MUSIC)

        def waiting(reason, position):
            emit('progress', variant=index + 1, phase='Wartet', current=None, total=None)
            emit('waiting', message=reason + ' Startet automatisch.', variant=index + 1)

        def line_seen(line):
            phase = music_phase(line)
            if phase is None:
                return
            name, current, total = phase
            key = (name, None if total is None else int(20 * current / max(total, 1)))
            if key != last.get('key'):
                last['key'] = key
                emit('progress', variant=index + 1, phase=name, current=current, total=total)

        def restart():
            emit('waiting', message='Ein anderer GPU-Auftrag hat Vorrang. Diese Variante startet danach neu …', variant=index + 1)

        try:
            code, tail = run_on_cards(broker, 1, make, waiting, on_line=line_seen,
                                      outputs=(out, out.with_suffix('.json')), on_restart=restart)
            if code != 0:
                raise RuntimeError(f'mm-synth ist fehlgeschlagen (Code {code}). {tail[-600:]}')
        except Exception as error:  # noqa: BLE001
            errors[index] = error
            if not cancelled.is_set():
                stop_running()  # one failed variant ends the job (like before)
        finally:
            broker.close()

    try:
        emit('status', message='Song wird auf bigki erzeugt …')
        threads = [threading.Thread(target=variant, args=(i,), daemon=True) for i in range(variants)]
        for thread in threads:
            thread.start()
            time.sleep(0.05)  # keeps the queue order of the variants
        for thread in threads:
            thread.join()
        failures = [e for e in errors if e is not None and str(e) != 'Abgebrochen.']
        if failures:
            raise failures[0]
        if cancelled.is_set() or any(errors):
            raise RuntimeError('Abgebrochen.')
        emit('status', message='Songs werden übertragen …')
        for index in range(variants):
            audio = job / f'song-{index + 1}.{ext}'
            replay_file = audio.with_suffix('.json')
            if not audio.is_file() or not replay_file.is_file():
                raise RuntimeError('mm-synth hat keine vollständige Ausgabe geschrieben.')
            try:
                replay_data = json.loads(replay_file.read_text())
                replay_data['steps'] = requests[index].get('steps', 30)
                replay_file.write_text(json.dumps(replay_data))
            except (OSError, ValueError):
                raise RuntimeError('Die Replay-Datei von mm-synth ist unlesbar.')
            send_file(audio)
            send_file(replay_file)
        emit('end', count=variants)
    finally:
        shutil.rmtree(job, ignore_errors=True)


def serve_3d(request, line):
    model = request.get('model')
    resolution = request.get('resolution')
    images = request.get('images')
    color = request.get('color') is True
    person = request.get('person') is True
    origin = clean_origin(request)
    if model not in ('standard', 'turbo') or resolution not in (380, 768, 1024):
        raise ValueError('Ungültiges KI-Modell oder ungültige Auflösung.')
    if not isinstance(images, dict) or not images or any(v not in VIEWS for v in images):
        raise ValueError('Bitte mindestens eine gültige Ansicht auswählen.')
    if color and set(images) != set(VIEWS):
        raise ValueError('Für die Farbübertragung werden alle vier Ansichten benötigt.')
    decoded = {}
    for view, encoded in images.items():
        if not isinstance(encoded, str) or len(encoded) > ((MAX_IMAGE + 2) // 3) * 4:
            raise ValueError('Ein Bild ist größer als 25 MB.')
        data = base64.b64decode(encoded, validate=True)
        if not data or len(data) > MAX_IMAGE:
            raise ValueError('Ein Bild ist leer oder größer als 25 MB.')
        decoded[view] = data

    threading.Thread(target=watch_connection, daemon=True).start()
    python = ROOT / '.venv' / 'bin' / 'python'
    if not (ROOT / 'generate.py').is_file() or not python.exists():
        raise RuntimeError('Die Hunyuan3D-Installation wurde auf bigki nicht gefunden.')
    jobs = ROOT / 'out' / 'app-jobs'
    jobs.mkdir(mode=0o700, parents=True, exist_ok=True)
    prune_old_jobs(jobs)
    job = jobs / ('auftrag-' + uuid.uuid4().hex)
    job.mkdir(mode=0o700)
    inputs = job / 'input'
    inputs.mkdir(mode=0o700)
    for view, data in decoded.items():
        with (inputs / (view + '.image')).open('xb') as output:
            output.write(data)
    del decoded, images, request, line
    env = os.environ.copy()
    env.update({'U2NET_HOME': str(ROOT / 'models' / 'rembg'),
                'OMP_NUM_THREADS': CPU_THREADS, 'OPENBLAS_NUM_THREADS': CPU_THREADS,
                'MKL_NUM_THREADS': CPU_THREADS, 'HF_HUB_OFFLINE': '1',
                'TRANSFORMERS_OFFLINE': '1', 'PYTHONUNBUFFERED': '1'})

    def cpu_stage(message, command, outputs=()):
        if cancelled.is_set():
            raise RuntimeError('Abgebrochen.')
        emit('status', message=message)
        remove_outputs(outputs)
        child = subprocess.Popen(command, cwd=str(ROOT), env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        with active_lock:
            active.add(child)
        tail = deque(maxlen=12)
        try:
            stream_output(child, lambda text: tail.append(text[-500:]))
            code = child.wait()
        finally:
            with active_lock:
                active.discard(child)
        if cancelled.is_set():
            raise RuntimeError('Abgebrochen.')
        if code != 0:
            raise RuntimeError(f'{message.rstrip(" …")} fehlgeschlagen (Code {code}). {" ".join(tail)[-900:]}')

    def gpu_stage(broker, cards, message, command, outputs):
        if cancelled.is_set():
            raise RuntimeError('Abgebrochen.')
        emit('status', message=message)

        def make(granted):
            gpu_env = rocm_env(granted)
            gpu_env.update({k: v for k, v in env.items() if k in ('HF_HUB_OFFLINE', 'TRANSFORMERS_OFFLINE', 'PYTHONUNBUFFERED')})
            gpu_env['ROCBLAS_TENSILE_LIBPATH'] = str(ROCM / 'core-7.14' / 'lib' / 'rocblas' / 'library' / 'gfx906')
            emit('status', message=message)
            return command, gpu_env, str(ROOT)

        def waiting(reason, position):
            emit('status', message=reason + ' Startet automatisch.')

        def line_seen(text):
            if text.startswith('Model loaded in'):
                emit('status', message='KI-Modell geladen – die 3D-Form wird berechnet …')

        def restart():
            emit('status', message='Ein anderer GPU-Auftrag hat Vorrang. StudioPortal startet diesen Schritt danach neu …')

        code, last = run_on_cards(broker, cards, make, waiting, on_line=line_seen, outputs=outputs, on_restart=restart)
        if code != 0:
            raise RuntimeError(f'{message.rstrip(" …")} fehlgeschlagen (Code {code}). {last}')

    broker = Broker(time.time_ns(), '3d', '3D-Modell', origin)
    try:
        cpu_stage('Bilder werden auf bigki vorbereitet …',
                  ['/usr/bin/nice', '-n', '15', str(python), str(Path(__file__).with_name('prepare_views.py')), str(job)])
        latent = job / 'form.safetensors'
        shape = job / 'form.glb'
        command = [str(python), str(ROOT / 'generate.py')]
        for view in VIEWS:
            path = job / 'views' / (view + '.png')
            if path.is_file():
                command.extend(['--' + view, str(path)])
        command.extend(['--model', model, '--seed', '12345', '--latent-only', '--save-latents', str(latent)])
        broker.label = '3D-Form'
        gpu_stage(broker, 1, 'KI berechnet die 3D-Form auf bigki …', command, (latent,))
        broker.label = '3D-Oberfläche'
        gpu_stage(broker, 3, 'Oberfläche wird auf den drei Grafikkarten erstellt …',
                  [str(python), str(ROOT / 'decode_latents.py'), '--gpus', '3', '--latents', str(latent), '--model', model,
                   '--resolution', str(resolution), '--num-chunks', '10000', '--fast-dilation', '--output', str(shape)],
                  (shape,))
    finally:
        broker.close()
    result = shape
    if color:
        result = job / 'form-farbig.glb'
        command = ['/usr/bin/nice', '-n', '15', str(python), str(ROOT / 'project_colors.py'),
                   str(shape), str(job / 'views'), str(result)]
        if person:
            command.append('--head-align')
        cpu_stage('Farben werden näherungsweise übertragen …', command, (result,))
    size = result.stat().st_size
    if size < 1000:
        raise RuntimeError('bigki hat keine vollständige 3D-Datei erstellt.')
    emit('status', message='3D-Modell wird von bigki übertragen …')
    emit('begin', size=size)
    digest = hashlib.sha256()
    with result.open('rb') as source:
        while True:
            data = source.read(192 * 1024)
            if not data or detached.is_set():
                break
            if cancelled.is_set():
                raise RuntimeError('Abgebrochen.')
            digest.update(data)
            emit('data', data=base64.b64encode(data).decode('ascii'))
    emit('end', sha256=digest.hexdigest(), job=str(job))
    shutil.rmtree(job, ignore_errors=True)


# ---------------------------------------------------------------- figures (Hunyuan3D-Omni pose control)
FIGUR = BASE / 'figur'
FIGUR_POSES = ('a', 'hand-hoch', 'arme-hoch')


def serve_figur(request):
    """One image of a person → untextured 3D figure in A-pose (or another skeleton pose) with Hunyuan3D-Omni."""
    origin = clean_origin(request)
    encoded = request.get('image')
    if not isinstance(encoded, str) or len(encoded) > ((MAX_IMAGE + 2) // 3) * 4:
        raise ValueError('Bild fehlt oder ist größer als 25 MB.')
    data = base64.b64decode(encoded, validate=True)
    pose = request.get('pose', 'a')
    bones = None
    if isinstance(pose, list):
        bones = [[float(v) for v in bone] for bone in pose]
        if not 4 <= len(bones) <= 200 or any(len(b) != 6 for b in bones):
            raise ValueError('pose als Liste: je Knochen [x1,y1,z1,x2,y2,z2], 4–200 Knochen.')
    elif pose not in FIGUR_POSES:
        raise ValueError(f'pose: {", ".join(FIGUR_POSES)} oder eine Knochenliste.')
    steps = int(request.get('steps', 50))
    octree = int(request.get('octree', 512))
    seed = int(request.get('seed', 1234))
    guidance = float(request.get('guidance', 4.5))
    if not (10 <= steps <= 100 and octree in (256, 384, 512) and 1 <= guidance <= 10):
        raise ValueError('steps 10–100, octree 256/384/512, guidance 1–10.')
    python = FIGUR / 'omni-venv' / 'bin' / 'python'
    script = Path(__file__).with_name('omni_figur.py')
    if not python.exists() or not script.is_file():
        raise RuntimeError('Hunyuan3D-Omni ist auf bigki nicht eingerichtet.')
    threading.Thread(target=watch_connection, daemon=True).start()
    jobs = FIGUR / 'jobs'
    jobs.mkdir(mode=0o700, parents=True, exist_ok=True)
    prune_old_jobs(jobs)
    job = jobs / ('auftrag-figur-' + uuid.uuid4().hex[:12])
    job.mkdir(mode=0o700)
    image = job / 'bild.image'
    image.write_bytes(data)
    del data, encoded, request
    output = job / 'figur.glb'
    command = [str(python), str(script), '--image', str(image), '--output', str(output),
               '--steps', str(steps), '--octree', str(octree), '--seed', str(seed), '--guidance', str(guidance)]
    if bones is not None:
        pose_file = job / 'pose.txt'
        pose_file.write_text('\n'.join(' '.join(f'{v:.6f}' for v in b) for b in bones) + '\n')
        command += ['--pose', str(pose_file)]
    else:
        command += ['--pose', pose]

    def make(granted):
        env = rocm_env(granted)
        env.update({'U2NET_HOME': str(ROOT / 'models' / 'rembg'), 'HF_HOME': str(FIGUR / 'hf'),
                    'HF_HUB_OFFLINE': '1', 'TRANSFORMERS_OFFLINE': '1',
                    'PYTHONUNBUFFERED': '1', 'OMP_NUM_THREADS': CPU_THREADS,
                    'ROCBLAS_TENSILE_LIBPATH': str(ROCM / 'core-7.14' / 'lib' / 'rocblas' / 'library' / 'gfx906')})
        emit('status', message='Hunyuan3D-Omni lädt auf bigki …')
        return command, env, str(FIGUR / 'omni')

    def waiting(reason, position):
        emit('status', message=reason + ' Startet automatisch.')

    log = (job / 'omni.log').open('a', encoding='utf-8')

    def line_seen(text):
        log.write(text + '\n')
        log.flush()
        if text.startswith('Model loaded in'):
            emit('status', message='Modell geladen – die Figur wird in der Pose berechnet …')
        elif text.startswith('PHASE '):
            emit('status', message=text[6:].strip())

    def restart():
        emit('status', message='Ein anderer GPU-Auftrag hat Vorrang. StudioPortal startet die Figur danach neu …')

    broker = Broker(time.time_ns(), 'figur', 'Figur (Omni)', origin)
    started = time.time()
    try:
        code, last = run_on_cards(broker, 1, make, waiting, on_line=line_seen, outputs=(output,), on_restart=restart)
    finally:
        broker.close()
        log.close()
    if code != 0 or not output.is_file() or output.stat().st_size < 1000:
        raise RuntimeError(f'Hunyuan3D-Omni fehlgeschlagen (Code {code}). {last} – ganzes Protokoll auf bigki: {job / "omni.log"}')
    emit('status', message='Figur wird von bigki übertragen …')
    send_file(output)
    emit('result', result={'ok': True, 'seconds': round(time.time() - started), 'pose': pose if bones is None else 'eigene',
                           'hinweis': 'Form ohne Textur in A-Pose; weiter mit figur.scan_aufraeumen / abgleichen / gewichte_uebertragen.'})
    shutil.rmtree(job, ignore_errors=True)


# ---------------------------------------------------------------- H3 video
VIDEO = Path.home() / 'sdcpp-mi50'
VIDEO_MODELS = (('--diffusion-model', VIDEO / 'models' / 'minimax_h3_fl2va_pruned-turbo4-Q6_K.gguf'),
                ('--vae', VIDEO / 'models' / 'minimax_h3_video_vae_f16_from_int8.safetensors'),
                ('--audio-vae', Path.home() / '.local/share/paiton/minimax-h3/models/vae/minimax_h3_audio_vae_fp32.safetensors'),
                ('--llm', VIDEO / 'models' / 'qwen3vl_32b_minimax_h3-from-nvfp4-Q8_0.gguf'))
HOT_CARD = 0  # PCI 03:00.0 cools badly (mi50-cooling throttles it): it gets the smaller share


def video_placement(cards, split):
    """sd-cli placement for the granted cards (inside the job they are ROCm0.. in ascending order)."""
    env = {}
    if len(cards) == 3:
        env['SD_H3_TOKEN_SPLIT'] = 'ROCm2,ROCm0'
        env['SD_H3_TOKEN_SPLIT_AT'] = split or '0.36,0.72'
        return env, 'diffusion=ROCm1,te=ROCm0,vae=ROCm1&ROCm2&ROCm0', VIDEO / 'src3'
    if HOT_CARD in cards:
        # the hot card is ROCm0 inside: it becomes the second card with 42.5 % of the tokens (as h3-schnell.sh)
        env['SD_H3_TOKEN_SPLIT'] = 'ROCm0'
        env['SD_H3_TOKEN_SPLIT_AT'] = split or '0.575'
        return env, 'diffusion=ROCm1,te=ROCm0,vae=ROCm1&ROCm0', VIDEO / 'src'
    env['SD_H3_TOKEN_SPLIT'] = 'ROCm1'
    env['SD_H3_TOKEN_SPLIT_AT'] = split or '0.5'
    return env, 'diffusion=ROCm0,te=ROCm1,vae=ROCm0&ROCm1', VIDEO / 'src'


def serve_video(request):
    prompt = request.get('prompt')
    width, height = request.get('width', 864), request.get('height', 480)
    frames, seed = request.get('frames', 124), request.get('seed', random.randint(1, 2**31 - 1))
    cards_wanted = request.get('cards', 2)
    steps = request.get('steps', 4)
    if steps not in (4, 5, 6, 8):
        raise ValueError('steps: 4, 5, 6 oder 8 (Turbo4 ist auf 4 destilliert).')
    split = request.get('split')
    origin = clean_origin(request)
    if not isinstance(prompt, str) or not prompt.strip() or '\0' in prompt or len(prompt) > 8000:
        raise ValueError('Bitte gib eine gültige Videobeschreibung ein.')
    for value in (width, height):
        if not isinstance(value, int) or value % 32 or not 256 <= value <= 1280:
            raise ValueError('Breite und Höhe: 256–1280 in 32er-Schritten.')
    if width * height > 1280 * 720:
        raise ValueError('Höchstens 1280×720 Pixel.')
    if not isinstance(frames, int) or not 24 <= frames <= 241:
        raise ValueError('24 bis 241 Bilder (24 fps, ~1–10 s).')
    if not isinstance(seed, int) or not 0 <= seed < 2**63:
        raise ValueError('Ungültiger Seed.')
    if cards_wanted not in (2, 3):
        raise ValueError('cards muss 2 oder 3 sein.')
    if split is not None and not (isinstance(split, str) and re.fullmatch(r'0\.\d{1,3}(,0\.\d{1,3})?', split)):
        raise ValueError('Ungültige Token-Aufteilung.')
    threading.Thread(target=watch_connection, daemon=True).start()
    binary = VIDEO / ('src3' if cards_wanted == 3 else 'src') / 'build-hip' / 'bin' / 'sd-cli'
    if not binary.is_file() or not all(path.is_file() for _, path in VIDEO_MODELS):
        raise RuntimeError('Die H3-Video-Installation wurde auf bigki nicht gefunden.')
    uid = uuid.uuid4().hex[:12]
    job = VIDEO / 'out' / f'studioportal-{uid}'
    job.mkdir(parents=True, mode=0o700)
    try:
        base = job / 'video.mp4'
        raw = job / 'video.mp4.avi'
        emit('run', name=f'video-{uid}', seed=seed)
        state = {'phase': 'Start', 'step': 0, 'steps': steps, 'started': time.time(), 'sampling': None}

        def line_seen(line):
            emit('log', line=line[-400:])
            m = re.search(r'\|\s*(\d+)/(\d+)\s*-\s*([\d.]+)s/it', line)
            phase = None
            if 'get_learned_condition' in line or 'text encoder' in line.lower() or 'computing condition' in line:
                phase = ('Text', None, None)
            elif m and int(m.group(2)) <= 16 and state['phase'] in ('Text', 'Rechnen', 'Start'):
                phase = ('Rechnen', int(m.group(1)), int(m.group(2)))
            elif 'sampling completed' in line:
                found = re.search(r'taking ([\d.]+)s', line)
                state['sampling'] = float(found.group(1)) if found else None
                phase = ('Video', None, None)
            if phase and (phase[0], phase[1]) != (state['phase'], state['step']):
                state['phase'], state['step'] = phase[0], phase[1] or state['step']
                emit('progress', phase=phase[0], step=phase[1], steps=phase[2])

        def make(cards):
            env = rocm_env(cards)
            env['LD_LIBRARY_PATH'] = f'{ROCM}/lib:{ROCM}/core-7.14/lib/llvm/lib'
            extra, backend, source = video_placement(sorted(cards), split)
            env.update(extra)
            command = [str(source / 'build-hip' / 'bin' / 'sd-cli'), '-M', 'vid_gen']
            for flag, path in VIDEO_MODELS:
                command += [flag, str(path)]
            command += ['-p', prompt, '--cfg-scale', '1.0', '--sampling-method', 'euler', '--scheduler', 'simple',
                        '--flow-shift', '6', '--steps', str(steps), '-W', str(width), '-H', str(height),
                        '--video-frames', str(frames), '--fps', '24', '--seed', str(seed), '--rng', 'cpu',
                        '--auto-fit', 'off', '--backend', backend, '--params-backend', 'te=disk', '-o', str(base), '-v']
            emit('status', message=f'Video wird auf {len(cards)} Karten berechnet …', cards=sorted(cards))
            return command, env, str(VIDEO)

        def waiting(reason, position):
            emit('waiting', message=reason + ' Startet automatisch.')

        def restart():
            state['phase'], state['step'] = 'Start', 0
            emit('waiting', message='Ein anderer GPU-Auftrag hat Vorrang. StudioPortal startet das Video danach neu …')

        broker = Broker(time.time_ns(), 'video', f'Video {width}×{height}', origin)
        try:
            code, last = run_on_cards(broker, cards_wanted, make, waiting, on_line=line_seen, outputs=(raw,), on_restart=restart)
        finally:
            broker.close()
        if code != 0 or not raw.is_file():
            raise RuntimeError(f'bigki konnte das Video nicht erzeugen (Code {code}). {last}')
        emit('progress', phase='Umwandeln', step=None, steps=None)
        final = job / f'video-{uid}.mp4'
        child = subprocess.run(['/usr/bin/nice', '-n', '15', 'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(raw),
                                '-c:v', 'libx264', '-crf', '18', '-preset', 'medium', '-pix_fmt', 'yuv420p', '-threads', CPU_THREADS,
                                '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart', str(final)],
                               stdin=subprocess.DEVNULL, capture_output=True, timeout=1800)
        if child.returncode != 0 or not final.is_file():
            raise RuntimeError('Das Video konnte nicht in MP4 umgewandelt werden: ' + child.stderr.decode('utf-8', 'replace')[-400:])
        emit('status', message='Video wird übertragen …')
        send_file(final)
        emit('end', count=1, seed=seed, seconds=round(time.time() - state['started']), sampling=state['sampling'])
    finally:
        shutil.rmtree(job, ignore_errors=True)


# ---------------------------------------------------------------- Blender
BLENDER_MI50 = Path.home() / 'Schreibtisch' / 'blender-mi50'
BLENDER_RUN = BLENDER_MI50 / 'run.sh'
BLENDER_ANIM = BLENDER_MI50 / 'anim_setup.py'
SESSION_SCRIPT = Path(__file__).with_name('blender_session.py')
BLENDER_ROOT = BASE / 'blender'
SESSION_NAME = re.compile(r'[a-z0-9][a-z0-9-]{0,23}')
# Blender 5.3 draws (Workbench/EEVEE/viewport) via Vulkan on the first GPU = MI50 card 0 (~1.2 GB VRAM per process),
# which blocks the card queue. Sessions and non-Cycles renders use the Intel iGPU instead (OpenGL, Intel driver only).
IGPU_ARGS = ['--gpu-backend', 'opengl']
IGPU_ENV = {'VK_DRIVER_FILES': '/usr/share/vulkan/icd.d/intel_icd.json', 'DRI_PRIME': 'pci-0000_00_02_0'}
MAX_UPLOAD = 100 * 1024 * 1024  # base64 must stay below MAX_REQUEST


def blender_binary():
    """The Blender that run.sh uses (5.3 with the MI50 setup)."""
    try:
        text = BLENDER_RUN.read_text()
        found = re.search(r'B="\$\{BLENDER:-([^}"]+)\}"', text)
        if found and Path(found.group(1)).is_file():
            return Path(found.group(1))
    except OSError:
        pass
    candidates = sorted((Path.home() / 'blender-r9700').glob('*/blender-*/blender'))
    if candidates:
        return candidates[-1]
    raise RuntimeError('Blender wurde auf bigki nicht gefunden.')


def session_paths(name):
    folder = BLENDER_ROOT / name
    return folder, folder / 'sitzung.sock', folder / 'sitzung.blend'


def session_connect(name, start=True):
    folder, sock_path, state = session_paths(name)
    for attempt in range(300):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(str(sock_path))
            return sock
        except OSError:
            sock.close()
        if not start:
            return None
        if attempt == 0:
            folder.mkdir(parents=True, exist_ok=True, mode=0o700)
            # own process name: scripts that wait for "blender" (GPU users) are not blocked by this CPU-only session
            link = BASE / 'bin' / 'studioportal-blender'
            link.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            binary = blender_binary()
            if not link.is_symlink() or os.readlink(link) != str(binary):
                temp = link.with_name('.studioportal-blender.tmp')
                try:
                    temp.unlink()
                except FileNotFoundError:
                    pass
                temp.symlink_to(binary)
                temp.replace(link)
            env = {k: v for k, v in os.environ.items() if k in ('HOME', 'USER', 'LOGNAME', 'LANG', 'PATH')}
            env.update({'TMPDIR': str(folder), 'PYTHONDONTWRITEBYTECODE': '1', 'OMP_NUM_THREADS': CPU_THREADS, **IGPU_ENV})
            command = ['/usr/bin/nice', '-n', '5', str(link), '-b', '--factory-startup', '-t', CPU_THREADS, *IGPU_ARGS]
            if state.is_file():
                command.append(str(state))
            command += ['--python', str(SESSION_SCRIPT), '--', str(sock_path), str(state)]
            log = (folder / 'sitzung.log').open('ab')
            subprocess.Popen(command, cwd=str(folder), env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                             start_new_session=True, close_fds=True)
            log.close()
            emit('status', message='Blender-Sitzung auf bigki wird gestartet …')
        time.sleep(0.2)
    raise RuntimeError('Die Blender-Sitzung auf bigki startet nicht (siehe sitzung.log).')


LOOK_LIMIT = 240   # a preview normally takes seconds; longer means the EGL/EEVEE render on the Intel GPU hangs


def stop_hung_session(name, what):
    """Kill a session whose current command hangs (Blender's main thread can't be interrupted from inside).
    The next call starts it again from the autosave; returns True when it was killed."""
    folder = session_paths(name)[0]
    try:
        current = json.loads((folder / 'laeuft.json').read_text(encoding='utf-8'))
        pid = json.loads((folder / 'status.json').read_text(encoding='utf-8')).get('pid')
    except (OSError, ValueError):
        return False
    if current.get('command') != what or not isinstance(pid, int):
        return False
    try:
        cmdline = Path(f'/proc/{pid}/cmdline').read_bytes()
    except OSError:
        return False
    if b'blender_session.py' not in cmdline:   # never anything that is not our session
        return False
    (folder / 'absturz.json').write_text(json.dumps(dict(current, reason=f'{what} hing länger als {LOOK_LIMIT} s und wurde beendet',
                                                         hint='Meist hängt das EEVEE-Bild auf der Intel-Grafik bei sehr vielen Punkten: '
                                                              'mode=solid nehmen, only=[…] oder size kleiner.',
                                                         time=time.strftime('%H:%M:%S')), ensure_ascii=False))
    os.kill(pid, signal.SIGKILL)
    return True


def session_call(name, payload, timeout=900):
    sock = session_connect(name)
    command = payload.get('command')
    waited = 0.0
    try:
        sock.sendall((json.dumps(payload) + '\n').encode())
        data = b''
        sock.settimeout(5)
        while not data.endswith(b'\n'):
            try:
                chunk = sock.recv(1 << 20)
            except socket.timeout:
                waited += 5
                if command == 'look':
                    folder = session_paths(name)[0]
                    try:
                        running_look = json.loads((folder / 'laeuft.json').read_text(encoding='utf-8')).get('command') == 'look'
                        started = (folder / 'laeuft.json').stat().st_mtime
                    except (OSError, ValueError):
                        running_look, started = False, time.time()
                    if running_look and time.time() - started > LOOK_LIMIT and stop_hung_session(name, 'look'):
                        raise RuntimeError(f'Die Vorschau hing länger als {LOOK_LIMIT} s – die Sitzung wurde beendet und startet '
                                           'beim nächsten Aufruf automatisch mit dem zuletzt gespeicherten Stand (Änderungen bis vor '
                                           'der Vorschau sind gesichert). Tipp: mode=solid, only=[…] oder kleinere size; eigene '
                                           'render_pre/frame_change-Handler prüfen.')
                if waited >= timeout:
                    raise RuntimeError(f'Die Blender-Sitzung hat nach {timeout} s nicht geantwortet (läuft noch weiter; '
                                       'blender_session action=status zeigt, woran sie arbeitet).')
                if waited % 60 == 0:
                    emit('status', message=f'Blender arbeitet noch ({int(waited)} s) …')
                continue
            if not chunk:
                break
            data += chunk
    finally:
        sock.close()
    if not data:
        crash = session_paths(name)[0] / 'absturz.json'
        reason = ''
        for _ in range(10):   # the memory guard writes the reason right before the session stops
            if crash.is_file():
                try:
                    info = json.loads(crash.read_text(encoding='utf-8'))
                    reason = f' Grund: {info.get("reason")}. {info.get("hint", "")}'
                except (OSError, ValueError):
                    pass
                break
            time.sleep(0.2)
        raise RuntimeError('Die Blender-Sitzung ist abgestürzt.' + (reason or ' (z. B. durch den Code oder einen Blender-Fehler)')
                           + ' Beim nächsten Aufruf wird der automatisch gespeicherte Stand nach dem letzten erfolgreichen Aufruf geladen.')
    return json.loads(data)


def clean_name(value, default):
    name = re.sub(r'[^A-Za-z0-9._-]', '_', value or '')[:80].strip('._') or default
    return name


def run_many_on_cards(broker, cards, make_all, on_wait, on_line, on_restart=None):
    """Like run_on_cards, but several processes on the granted cards (e.g. two Blender instances per card)."""
    while True:
        granted = broker.acquire(cards, on_wait)
        children = []
        tails = deque(maxlen=12)
        try:
            for command, env, cwd in make_all(granted):
                child = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                         stderr=subprocess.STDOUT, start_new_session=True, preexec_fn=no_core_dumps)
                with active_lock:
                    active.add(child)
                children.append(child)
                broker.send(op='run', pid=child.pid)
                time.sleep(2)  # staggered starts: the frames are claimed one after another
            if cancelled.is_set():
                stop_running()
            readers = []
            for child in children:
                def read(child=child):
                    stream_output(child, lambda line: (tails.append(line[-400:]), on_line(line)))
                thread = threading.Thread(target=read, daemon=True)
                thread.start()
                readers.append(thread)
            codes = [child.wait() for child in children]
            for thread in readers:
                thread.join(5)
        finally:
            with active_lock:
                for child in children:
                    active.discard(child)
        if cancelled.is_set():
            broker.release()
            raise RuntimeError('Abgebrochen.')
        bad = [code for code in codes if code != 0]
        event = broker.revoked(1.5) if bad else None
        if event is None:
            broker.release()
            return (bad[0] if bad else 0), ' '.join(tails)[-900:]
        if event.get('reason') == 'heat':
            raise heat_error(event)
        if on_restart:
            on_restart()


def blender_render(name, request, origin):
    folder, _, _ = session_paths(name)
    job = folder / ('render-' + uuid.uuid4().hex[:10])
    job.mkdir(parents=True, mode=0o700)
    prune_pickups(name)
    pickup = pickup_folder(name, request.get('ticket'))
    if pickup is not None:
        pickup.mkdir(parents=True, mode=0o700, exist_ok=True)
        (pickup / 'worker.pid').write_text(str(os.getpid()))
    try:
        cameras = request.get('cameras') or ([request['camera']] if request.get('camera') else None)
        if cameras is not None:
            if not isinstance(cameras, list) or not cameras or len(cameras) > 32 or not all(isinstance(c, str) for c in cameras):
                raise ValueError('cameras: Liste von 1–32 Kameranamen.')
        scene_file = job / 'szene.blend'
        snapshot = session_call(name, {'command': 'save', 'path': str(scene_file), 'pack': False, 'compress': False,
                                       **({'camera': cameras[0]} if cameras else {})})
        if not snapshot.get('ok'):
            raise RuntimeError(snapshot.get('error', 'Szene konnte nicht gespeichert werden.'))
        scene_files = [scene_file]
        for index, camera in enumerate(cameras[1:] if cameras else [], start=1):
            extra = job / f'szene-{index}.blend'
            answer = session_call(name, {'command': 'save', 'path': str(extra), 'pack': False, 'compress': False, 'camera': camera})
            if not answer.get('ok'):
                raise RuntimeError(answer.get('error', f'Szene für Kamera {camera} konnte nicht gespeichert werden.'))
            scene_files.append(extra)
        start, end = snapshot['frames']
        frames = request.get('frames')
        if isinstance(frames, int):
            start = end = frames
        elif isinstance(frames, list) and len(frames) == 2 and all(isinstance(f, int) for f in frames):
            start, end = frames
        elif frames is None:
            start = end = snapshot.get('current', start)
        elif frames != 'all':
            raise ValueError('frames: eine Bildnummer, [Start, Ende] oder "all".')
        if end < start or end - start > 5000:
            raise ValueError('Ungültiger Bildbereich (höchstens 5000 Bilder).')
        if len(scene_files) > 1 and end != start:
            raise ValueError('Mehrere Kameras gehen nur für ein einzelnes Bild (frames weglassen oder eine Zahl).')
        noise = request.get('noise', 0.01)
        samples = request.get('samples')
        percentage = request.get('percentage')
        settings = ['cycles.device="GPU"']
        if noise != 'off':
            if not isinstance(noise, (int, float)) or not 0.001 <= noise <= 0.5:
                raise ValueError('noise: 0.001–0.5 oder "off".')
            settings += ['cycles.use_adaptive_sampling=True', f'cycles.adaptive_threshold={float(noise)}']
        if samples is not None:
            if not isinstance(samples, int) or not 1 <= samples <= 65536:
                raise ValueError('samples: 1–65536.')
            settings.append(f'cycles.samples={samples}')
        if percentage is not None:
            if not isinstance(percentage, int) or not 1 <= percentage <= 400:
                raise ValueError('percentage: 1–400.')
            settings.append(f'render.resolution_percentage={percentage}')
        count = (end - start + 1) * len(scene_files)
        out = job / 'bilder'
        out.mkdir()
        pattern = str(out / 'bild_####')
        multi = len(scene_files) > 1

        def camera_args(files, with_anim):
            # several .blend files in ONE Blender process, each rendered as one still with its own output pattern
            args = []
            for index, path in files:
                args += [str(path)] + (['--python', str(BLENDER_ANIM)] if with_anim else []) + \
                        ['-F', 'PNG', '-o', str(out / f'kamera{index:02d}_####'), '-f', str(start)]
            return args
        engine = snapshot.get('engine')
        res = snapshot.get('resolution')
        if percentage is not None and snapshot.get('base_resolution'):
            res = [v * percentage // 100 for v in snapshot['base_resolution']]
        facts = {'samples': samples if samples is not None else snapshot.get('samples'), 'resolution': res,
                 'source': snapshot.get('source'), 'camera': snapshot.get('camera'),
                 'denoiser': (snapshot.get('denoiser') or ('OPENIMAGEDENOISE' if snapshot.get('denoising') else 'off')) if engine == 'CYCLES' else 'off',
                 'adaptive_threshold': (None if noise == 'off' else float(noise)) if engine == 'CYCLES' else None}
        started = time.time()
        done = set()
        telemetry = {
            'process_started': None,
            'first_sample_at': None,
            'last_saved_at': None,
            'kernel_compiled': False,
            'samples_reached': None,
            'blender_time_s': None,
            'granted_cards': [],
        }

        def line_seen(line):
            now = time.time()
            if 'Saved:' in line:
                telemetry['last_saved_at'] = now
                found = re.search(r"(bild|kamera\d+)_\d+", line)
                if found:
                    done.add(found.group(0))
                emit('progress', phase='Rendern', step=len(done), steps=count)
            elif 'Compiling' in line or ('compil' in line.lower() and 'kernel' in line.lower()):
                telemetry['kernel_compiled'] = True
                emit('status', message='Blender übersetzt einmalig die GPU-Kernel für diese Effekte (1–2 min) …')
            sample_match = re.search(r'\bSample\s+(\d+)/(\d+)\b', line)
            if sample_match:
                if telemetry['first_sample_at'] is None:
                    telemetry['first_sample_at'] = now
                reached = int(sample_match.group(1))
                if telemetry['samples_reached'] is None or reached > telemetry['samples_reached']:
                    telemetry['samples_reached'] = reached
            time_match = re.search(r'\bTime:\s*(\d+):(\d+(?:\.\d+)?)', line)
            if time_match:
                telemetry['blender_time_s'] = round(int(time_match.group(1)) * 60 + float(time_match.group(2)), 2)
            emit('log', line=line[-300:])

        if engine != 'CYCLES':
            # EEVEE/Workbench need no MI50: one background process on the Intel iGPU, outside the card queue
            emit('status', message=f'{engine} rendert ohne die MI50 (Intel-Grafik) …')
            telemetry['process_started'] = time.time()
            command = [str(BASE / 'bin' / 'studioportal-blender'), '-b', '--factory-startup', *IGPU_ARGS]
            command += (camera_args(list(enumerate(scene_files)), False) if multi else
                        [str(scene_file), '-F', 'PNG', '-o', pattern, '-s', str(start), '-e', str(end), '-a'])
            child = subprocess.Popen(command, cwd=str(job), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, start_new_session=True, env={**os.environ, **IGPU_ENV})
            with active_lock:
                active.add(child)
            stream_output(child, line_seen)
            code = child.wait()
            with active_lock:
                active.discard(child)
            if code != 0:
                raise RuntimeError(f'Blender-Rendern fehlgeschlagen (Code {code}).')
        else:
            if not BLENDER_RUN.is_file() or not BLENDER_ANIM.is_file():
                raise RuntimeError('Das MI50-Blender-Setup (~/blender-mi50) fehlt auf bigki.')
            per_card = 2 if count > 1 else 1
            cards = max(1, min(int(request.get('cards', 3)), 3))
            broker = Broker(time.time_ns(), 'blender', f'Blender {"Bild" if count == 1 else f"{count} Bilder"}', origin)

            def make_all(granted):
                telemetry['granted_cards'] = sorted(granted)
                if telemetry['process_started'] is None:
                    telemetry['process_started'] = time.time()
                emit('status', message=f'Cycles rendert auf {len(granted)} MI50 …', cards=sorted(granted))
                commands = []
                for leftover in out.glob('bild_*'):
                    if leftover.stat().st_size == 0:
                        leftover.unlink()  # placeholder of an interrupted instance
                if multi:
                    slots = [card for _ in range(2) for card in sorted(granted)][:len(scene_files)]
                    for slot, card in enumerate(slots):
                        mine = [(i, f) for i, f in enumerate(scene_files) if i % len(slots) == slot]
                        env = rocm_env([card])
                        env.update({'BENCH_DEV': 'HIP', 'BENCH_SET': ';'.join(settings)})
                        commands.append(([str(BLENDER_RUN), '-b'] + camera_args(mine, True), env, str(job)))
                    return commands
                if count == 1:
                    env = rocm_env(granted)
                    env.update({'BENCH_DEV': 'HIP', 'BENCH_SET': ';'.join(settings)})
                    commands.append(([str(BLENDER_RUN), '-b', str(scene_file), '-F', 'PNG', '-o', pattern,
                                      '--python', str(BLENDER_ANIM), '-f', str(start)], env, str(job)))
                    return commands
                for _ in range(per_card):
                    for card in sorted(granted):
                        env = rocm_env([card])
                        env.update({'BENCH_DEV': 'HIP', 'BENCH_SET': ';'.join(
                            settings + ['render.use_placeholder=True', 'render.use_overwrite=False'])})
                        commands.append(([str(BLENDER_RUN), '-b', str(scene_file), '-F', 'PNG', '-o', pattern,
                                          '-s', str(start), '-e', str(end), '--python', str(BLENDER_ANIM), '-a'],
                                         env, str(job)))
                return commands

            def waiting(reason, position):
                emit('waiting', message=reason + ' Startet automatisch.')

            def restart():
                emit('waiting', message='Ein fremder GPU-Auftrag hat Vorrang. Das Rendern setzt danach fort …')

            try:
                code, last = run_many_on_cards(broker, cards, make_all, waiting, line_seen, restart)
            finally:
                broker.close()
            if code != 0:
                raise RuntimeError(f'Blender-Rendern fehlgeschlagen (Code {code}). {last}')
        images = sorted(p for p in out.glob('kamera*_*.png' if multi else 'bild_*.png') if p.stat().st_size > 0)
        if len(images) != count:
            raise RuntimeError(f'Es wurden nur {len(images)} von {count} Bildern gerendert.')
        finished = time.time()
        seconds = round(finished - started, 1)
        proc_start = telemetry['process_started'] or started
        wait_s = round(max(0.0, proc_start - started), 1)
        render_meta = {
            'device': 'HIP (AMD MI50)' if engine == 'CYCLES' else 'Intel iGPU',
            'cards': telemetry['granted_cards'],
            'card_count': len(telemetry['granted_cards']),
            'kernel_compiled': telemetry['kernel_compiled'],
            'wait_s': wait_s,
        }
        if telemetry['first_sample_at'] is not None:
            render_meta['setup_s'] = round(max(0.0, telemetry['first_sample_at'] - proc_start), 1)
            render_end = telemetry['last_saved_at'] or finished
            render_meta['render_s'] = round(max(0.0, render_end - telemetry['first_sample_at']), 1)
        if telemetry['samples_reached'] is not None:
            render_meta['samples_reached'] = telemetry['samples_reached']
        if telemetry['blender_time_s'] is not None:
            render_meta['blender_time_s'] = telemetry['blender_time_s']
        if multi:
            deliver(pickup, images, {'count': count, 'seconds': seconds, 'frames': [start, end], 'engine': engine,
                                     'cameras': cameras, **facts, **render_meta})
            return
        if count == 1:
            deliver(pickup, images[:1], {'count': count, 'seconds': seconds, 'frames': [start, end], 'engine': engine,
                                         **facts, **render_meta})
            return
        else:
            emit('progress', phase='Video', step=None, steps=None)
            video = job / 'animation.mp4'
            fps = snapshot.get('fps') or 24
            child = subprocess.run(['/usr/bin/nice', '-n', '15', 'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                                    '-framerate', str(fps), '-start_number', str(start), '-i', str(out / 'bild_%04d.png'),
                                    '-c:v', 'libx264', '-crf', '16', '-pix_fmt', 'yuv420p', '-threads', CPU_THREADS,
                                    '-movflags', '+faststart', str(video)],
                                   stdin=subprocess.DEVNULL, capture_output=True, timeout=3600)
            if child.returncode != 0:
                raise RuntimeError('Die Bilder konnten nicht zu einem Video zusammengesetzt werden.')
            deliver(pickup, [video] + (images if request.get('send_frames') else []),
                    {'count': count, 'seconds': seconds, 'frames': [start, end], 'engine': engine, **facts, **render_meta})
    except Exception as error:
        if pickup is not None:
            (pickup / 'fehler.json').write_text(json.dumps({'message': str(error)}, ensure_ascii=False))
        raise
    finally:
        shutil.rmtree(job, ignore_errors=True)


def pickup_folder(name, ticket):
    if not isinstance(ticket, str) or not re.fullmatch(r'[a-f0-9]{8,32}', ticket):
        return None
    folder, _, _ = session_paths(name)
    return folder / 'abholung' / ticket


def prune_pickups(name, hours=12):
    folder, _, _ = session_paths(name)
    limit = time.time() - hours * 3600
    for item in (folder / 'abholung').glob('*'):
        try:
            if item.is_dir() and item.stat().st_mtime < limit:
                shutil.rmtree(item, ignore_errors=True)
        except OSError:
            pass


current_pickup = [None]   # set for ticketed session calls: the answer is parked here before it is sent


def give_result(result, files=()):
    """Send a session answer (plus files such as the look image); with a ticket it is first parked for pickup."""
    pickup = current_pickup[0]
    files = list(files)
    if pickup is not None:
        parked = []
        for path in files:
            target = pickup / path.name
            shutil.copy2(path, target)
            parked.append(target)
        files = parked
        temp = pickup / 'ende.json.tmp'
        temp.write_text(json.dumps({'files': [p.name for p in files], 'result': result}, ensure_ascii=False))
        temp.replace(pickup / 'ende.json')
    for path in files:
        send_file(path)
    emit('result', result=result)


def deliver(pickup, files, end_fields):
    """Send the render result; with a ticket it is first parked for pickup (kept until the Mac confirms)."""
    if pickup is not None:
        parked = []
        for path in files:
            target = pickup / path.name
            shutil.move(str(path), target)
            parked.append(target)
        files = parked
        (pickup / 'ende.json').write_text(json.dumps({'files': [p.name for p in files], 'end': end_fields}, ensure_ascii=False))
    for path in files:
        send_file(path)
    emit('end', **end_fields)


def serve_pickup(name, ticket):
    """action abholen: wait for a render that lost its connection and send its result."""
    pickup = pickup_folder(name, ticket)
    if pickup is None or not pickup.is_dir():
        raise RuntimeError('Zu diesem Ticket gibt es auf bigki nichts abzuholen (schon abgeholt, älter als 12 h oder nie gestartet).')
    last = 0.0
    while True:
        if cancelled.is_set():
            if aborted.is_set():   # the user cancelled while waiting: stop the render itself as well
                try:
                    os.kill(int((pickup / 'worker.pid').read_text()), signal.SIGTERM)
                except (OSError, ValueError):
                    pass
            return
        if (pickup / 'ende.json').is_file():
            info = json.loads((pickup / 'ende.json').read_text())
            emit('status', message='Ergebnis ist fertig – wird von bigki abgeholt …')
            for file_name in info['files']:
                send_file(pickup / file_name)
            if 'result' in info:
                emit('result', result=info['result'])
            else:
                emit('end', **info['end'])
            return
        if (pickup / 'fehler.json').is_file():
            raise RuntimeError(json.loads((pickup / 'fehler.json').read_text()).get('message', 'Render fehlgeschlagen.'))
        try:
            owner = int((pickup / 'worker.pid').read_text())
            os.kill(owner, 0)
        except (OSError, ValueError):
            raise RuntimeError('Der Auftrag auf bigki wurde beendet, ohne ein Ergebnis abzulegen.')
        if time.time() - last > 20:
            emit('waiting', message='Verbindung war unterbrochen – der Auftrag läuft auf bigki weiter, StudioPortal wartet darauf …')
            last = time.time()
        time.sleep(2)


def find_by_name(home, filename, limit=8, budget=200000):
    """Files called `filename` in bigki's home (skips hidden folders and big caches; stops after `budget` entries)."""
    found, seen = [], 0
    skip = {'.cache', '.local', '.git', 'node_modules', '__pycache__', '.venv', 'venv', 'site-packages'}
    for root, dirs, files in os.walk(home):
        dirs[:] = [d for d in dirs if not d.startswith('.') and d not in skip]
        seen += len(files) + len(dirs)
        if filename in files:
            found.append(Path(root) / filename)
            if len(found) >= limit:
                break
        if seen > budget:
            break
    return found


def bigki_file(path):
    """A readable file in bigki's home (absolute, ~/…, or relative to the home folder)."""
    home = Path.home().resolve()
    candidate = Path(os.path.expanduser(path))
    if not candidate.is_absolute():
        candidate = home / candidate
    candidate = candidate.resolve()
    if home not in candidate.parents:
        raise ValueError(f'Nur Dateien im Home-Ordner von bigki ({home}) – nicht {candidate}.')
    if not candidate.is_file():
        near = sorted(p.name for p in candidate.parent.glob('*'))[:40] if candidate.parent.is_dir() else []
        message = f'{candidate} gibt es auf bigki nicht.' + (f' Im Ordner liegen: {", ".join(near)}' if near else ' Den Ordner gibt es auch nicht.')
        same = find_by_name(home, candidate.name)
        if same:
            message += ' Gleichnamige Dateien auf bigki: ' + ', '.join('~/' + str(p.relative_to(home)) for p in same)
        raise ValueError(message)
    return candidate


def serve_blender(request):
    action = request.get('action')
    name = request.get('session') or 'standard'
    if not isinstance(name, str) or not SESSION_NAME.fullmatch(name):
        raise ValueError('Ungültiger Sitzungsname (a–z, 0–9, -).')
    origin = clean_origin(request)
    folder, sock_path, state = session_paths(name)
    if action == 'sessions':
        sessions = []
        for item in sorted(BLENDER_ROOT.glob('*/sitzung.blend')) + sorted(BLENDER_ROOT.glob('*/sitzung.sock')):
            if item.parent.name not in [s['name'] for s in sessions]:
                sessions.append({'name': item.parent.name, 'running': (item.parent / 'sitzung.sock').exists()})
        emit('result', result={'ok': True, 'sessions': sessions})
        return
    if action == 'status':
        # never waits for (or starts) the session: reads the files it keeps up to date
        info = {'ok': True, 'session': name, 'running': sock_path.exists(), 'saved': None}
        for key, file in (('status', 'status.json'), ('current', 'laeuft.json'), ('last_crash', 'absturz.json.alt')):
            path = folder / file
            if path.is_file():
                try:
                    info[key] = json.loads(path.read_text(encoding='utf-8'))
                except (OSError, ValueError):
                    pass
        if state.is_file():
            info['saved'] = time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(state.stat().st_mtime))
            info['saved_mb'] = round(state.stat().st_size / 1e6, 1)
        pid = (info.get('status') or {}).get('pid')
        if isinstance(pid, int) and Path(f'/proc/{pid}').exists():
            try:
                pages = int(Path(f'/proc/{pid}/statm').read_text().split()[1])
                info['memory_gb'] = round(pages * os.sysconf('SC_PAGE_SIZE') / 1e9, 1)
            except (OSError, ValueError, IndexError):
                pass
        else:
            info['running'] = False
        if info.get('current') and info['running']:
            try:
                started = time.mktime(time.strptime(time.strftime('%Y-%m-%d ') + info['current']['time'], '%Y-%m-%d %H:%M:%S'))
                info['current']['seconds'] = max(0, round(time.time() - started))
            except (KeyError, ValueError, TypeError):
                pass
        else:
            info.pop('current', None)
        info['cpu'] = host_cpu_info()
        emit('result', result=info)
        return
    if action == 'quit':
        sock = session_connect(name, start=False)
        if sock is None:
            emit('result', result={'ok': True, 'message': 'Sitzung lief nicht.'})
            return
        sock.close()
        emit('result', result=session_call(name, {'command': 'quit'}, timeout=120))
        return
    if action == 'reset':
        sock = session_connect(name, start=False)
        if sock is not None:
            sock.close()
            session_call(name, {'command': 'quit'}, timeout=120)
            for _ in range(100):
                if not sock_path.exists():
                    break
                time.sleep(0.1)
        for item in (state, folder / 'uploads', folder / 'sitzung_defs.json', folder / 'sitzung_variablen.json', folder / 'ende.json'):
            if item.is_dir():
                shutil.rmtree(item, ignore_errors=True)
            elif item.exists():
                item.unlink()
        emit('result', result={'ok': True, 'message': 'Sitzung geleert.'})
        return
    if action == 'abgeholt':
        pickup = pickup_folder(name, request.get('ticket'))
        if pickup is not None:
            shutil.rmtree(pickup, ignore_errors=True)
        emit('result', result={'ok': True})
        return
    ticketed = action in TICKETED or (action == 'open' and not request.get('data'))
    if (action == 'render' or ticketed) and pickup_folder(name, request.get('ticket')) is not None:
        detachable.set()
    threading.Thread(target=watch_connection, daemon=True).start()
    if action == 'abholen':
        serve_pickup(name, request.get('ticket'))
        return
    if ticketed and pickup_folder(name, request.get('ticket')) is not None:
        prune_pickups(name)
        pickup = pickup_folder(name, request['ticket'])
        pickup.mkdir(parents=True, mode=0o700, exist_ok=True)
        (pickup / 'worker.pid').write_text(str(os.getpid()))
        current_pickup[0] = pickup
        try:
            session_action(name, folder, action, request)
        except Exception as error:
            (pickup / 'fehler.json').write_text(json.dumps({'message': str(error)}, ensure_ascii=False))
            raise
        return
    session_action(name, folder, action, request)


TICKETED = ('python', 'scene', 'api', 'info', 'new', 'check', 'snapshot', 'snapshots', 'restore', 'tools', 'look')


def session_action(name, folder, action, request):
    origin = clean_origin(request)
    if action in ('python', 'scene', 'api', 'info', 'new', 'check', 'snapshot', 'snapshots', 'restore', 'tools'):
        keys = {'python': ('code', 'persist', 'script_path'), 'scene': ('object',), 'api': ('identifier',), 'new': ('empty',),
                'check': ('objects', 'pairs', 'contact', 'tolerance', 'floor', 'floor_z', 'holes', 'layers', 'layer_gap', 'rays',
                          'small_part', 'sliver', 'stretch', 'layer_samples', 'max_objects', 'thickness', 'thickness_samples',
                          'min_thickness', 'remove_small'),
                'snapshot': ('name', 'note', 'keep'), 'restore': ('name',), 'tools': ('mode', 'code', 'name')}.get(action, ())
        payload = {k: v for k, v in request.items() if k in keys}
        payload['command'] = action
        if action in ('python', 'tools') and isinstance(request.get('script_path'), str) and not payload.get('code'):
            # a script that already lives on bigki (e.g. ~/skripte/kleid.py): read here instead of pasting the code
            script = bigki_file(request['script_path'])
            if script.stat().st_size > 4 * 1024 * 1024:
                raise ValueError('Skript größer als 4 MB.')
            payload['code'] = script.read_text(encoding='utf-8')
            if action == 'python':
                payload['script_path'] = str(script)
            if action == 'tools' and payload.get('mode') not in ('add', 'set', 'file'):
                payload['mode'] = 'file'
            if action == 'tools' and not payload.get('name'):
                payload['name'] = script.stem
        timeout = request.get('timeout', 900)
        give_result(session_call(name, payload, timeout=max(5, min(int(timeout), 3600))))
    elif action == 'look':
        output = folder / f'blick-{uuid.uuid4().hex[:8]}.png'
        payload = {k: v for k, v in request.items() if k in ('mode', 'size', 'camera', 'frame', 'overview', 'samples', 'views',
                                                              'azimuth', 'elevation', 'distance', 'target', 'focus', 'lens',
                                                              'color_by', 'only', 'columns', 'region', 'zoom', 'center')}
        payload.update({'command': 'look', 'output': str(output)})
        reference = None
        if isinstance(request.get('reference_data'), str):
            if len(request['reference_data']) > 30 * 1024 * 1024:
                raise ValueError('Vorlagebild größer als 20 MB.')
            suffix = Path(clean_name(request.get('reference_name'), 'vorlage.png')).suffix.lower()
            if suffix not in ('.png', '.jpg', '.jpeg', '.webp', '.tif', '.tiff', '.exr', '.bmp'):
                suffix = '.png'
            reference = folder / f'vorlage-{uuid.uuid4().hex[:6]}{suffix}'
            reference.write_bytes(base64.b64decode(request['reference_data'], validate=True))
            payload['reference'] = str(reference)
        elif isinstance(request.get('reference_path'), str):
            payload['reference'] = str(bigki_file(request['reference_path']))
        try:
            result = session_call(name, payload, timeout=900)
            give_result(result, [output] if result.get('ok') and output.is_file() else [])
        finally:
            for item in (output, reference):
                if item is not None:
                    try:
                        item.unlink()
                    except FileNotFoundError:
                        pass
    elif action == 'open' and isinstance(request.get('path'), str) and not request.get('data'):
        # a file that already lives on bigki (absolute or ~/…): opened in place, nothing is uploaded
        target = bigki_file(request['path'])
        mode = 'append' if request.get('append') else 'open'
        give_result(session_call(name, {'command': 'open', 'path': str(target), 'mode': mode}, timeout=900))
    elif action == 'open':
        data = request.get('data')
        filename = clean_name(request.get('filename'), 'datei.blend')
        if not isinstance(data, str) or len(data) > ((MAX_UPLOAD + 2) // 3) * 4:
            raise ValueError('Datei fehlt oder ist größer als 100 MB.')
        uploads = folder / 'uploads'
        uploads.mkdir(parents=True, exist_ok=True, mode=0o700)
        target = uploads / f'{uuid.uuid4().hex[:6]}-{filename}'
        target.write_bytes(base64.b64decode(data, validate=True))
        del data, request['data']
        mode = 'append' if request.get('append') else 'open'
        give_result(session_call(name, {'command': 'open', 'path': str(target), 'mode': mode}, timeout=900))
    elif action == 'save' and isinstance(request.get('bigki_path'), str):
        # big scenes stay on bigki: save directly into a folder in bigki's home, nothing is transferred
        home = Path.home().resolve()
        raw = request['bigki_path']
        target = Path(os.path.expanduser(raw))
        target = (target if target.is_absolute() else home / target).resolve()
        if home not in target.parents:
            raise ValueError(f'bigki_path muss im Home-Ordner von bigki liegen ({home}).')
        if target.suffix != '.blend':
            if target.is_dir() or raw.endswith('/'):
                filename = clean_name(request.get('filename'), 'szene.blend')
                target = target / (filename if filename.endswith('.blend') else filename + '.blend')
            else:
                target = target.with_suffix('.blend')
        if target.exists() and not request.get('overwrite'):
            raise ValueError(f'{target} gibt es schon – nichts überschrieben. Anderen Namen wählen oder overwrite=true, '
                             'wenn diese Datei wirklich ersetzt werden soll.')
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        result = session_call(name, {'command': 'save', 'path': str(target), 'pack': True}, timeout=900)
        if result.get('ok'):
            result['mb'] = round(target.stat().st_size / 1e6, 1)
            result['bigki_path'] = str(target)
        give_result(result)
    elif action == 'save':
        filename = clean_name(request.get('filename'), 'szene.blend')
        if not filename.endswith('.blend'):
            filename += '.blend'
        target = folder / f'export-{uuid.uuid4().hex[:6]}' / filename
        target.parent.mkdir(mode=0o700)
        try:
            result = session_call(name, {'command': 'save', 'path': str(target), 'pack': True}, timeout=900)
            if result.get('ok') and target.is_file():
                send_file(target)
            emit('result', result=result)
        finally:
            shutil.rmtree(target.parent, ignore_errors=True)
    elif action == 'render':
        blender_render(name, request, origin)
    else:
        raise ValueError('Unbekannte Blender-Aktion.')


# ---- LLM: Strata (Qwen3.8 Flash Next) on all three MI50 -------------------------------------------------------------
# Strata is the user's own installation (~/llm, ~/mi50-phase0); StudioPortal only starts/stops it with the user's
# start script and talks to its OpenAI-compatible server on localhost. The API key never leaves bigki.
STRATA_PROFILE = Path.home() / 'llm' / 'strata-v0.2.7-mi50' / 'strata-orca-iq3_m-mi50.json'
STRATA_START = Path.home() / 'Downloads' / 'strata' / 'START-MI50.sh'
STRATA_UNIT = 'mi50-strata.service'
LLM_DIR = BASE / 'llm'
LLM_IDLE_MINUTES = 20
LLM_MAX_TOKENS = 32768


def strata_profile():
    profile = json.loads(STRATA_PROFILE.read_text())
    return profile.get('port', 8080), profile.get('api_key'), profile.get('model_name', 'strata')


def strata_context():
    args = json.loads(STRATA_PROFILE.read_text()).get('args') or []
    try:
        return int(args[args.index('--max-context') + 1])
    except (ValueError, IndexError):
        return None


def strata_unit_active():
    return subprocess.run(['systemctl', '--user', 'is-active', '--quiet', STRATA_UNIT]).returncode == 0


def strata_healthy(port):
    import urllib.request
    try:
        with urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=3) as reply:
            return reply.status == 200
    except OSError:
        return False


def llm_state():
    port, _, model = strata_profile()
    active = strata_unit_active()
    ready = active and strata_healthy(port)
    ours = (LLM_DIR / 'started-by-studioportal').is_file()
    last = LLM_DIR / 'last_use'
    idle = int(time.time() - last.stat().st_mtime) if last.is_file() else None
    return {'running': ready, 'starting': active and not ready, 'model': model, 'engine': 'Strata',
            'started_by_studioportal': active and ours, 'idle_seconds': idle,
            'auto_stop_minutes': LLM_IDLE_MINUTES if active and ours else None, 'context': strata_context()}


def llm_touch():
    LLM_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    (LLM_DIR / 'last_use').touch()


def llm_stop():
    subprocess.run(['systemctl', '--user', 'stop', STRATA_UNIT], timeout=120)
    (LLM_DIR / 'started-by-studioportal').unlink(missing_ok=True)


def strata_activity():
    import urllib.request
    port, key, _ = strata_profile()
    request = urllib.request.Request(f'http://127.0.0.1:{port}/metrics/prometheus',
                                     headers={'Authorization': 'Bearer ' + key} if key else {})
    names = {'llamacpp:requests_processing', 'llamacpp:requests_deferred', 'strata:requests_total'}
    values = {}
    try:
        with urllib.request.urlopen(request, timeout=3) as reply:
            for line in reply.read(131_072).decode().splitlines():
                name, _, value = line.partition(' ')
                if name in names:
                    values[name] = int(value)
        busy = values['llamacpp:requests_processing'] + values['llamacpp:requests_deferred'] > 0
        return busy, values['strata:requests_total']
    except (OSError, KeyError, ValueError):
        return None


def llm_idle_watch():
    """Stop a StudioPortal-owned Strata after all of its clients have been idle."""
    marker, last = LLM_DIR / 'started-by-studioportal', LLM_DIR / 'last_use'
    previous = None
    while True:
        time.sleep(60)
        if not marker.is_file() or not strata_unit_active():
            return
        activity = strata_activity()
        if activity is None:
            continue
        busy, completed = activity
        if busy or completed != previous:
            llm_touch()
        previous = completed
        if time.time() - last.stat().st_mtime > LLM_IDLE_MINUTES * 60:
            if strata_activity() == (False, completed):
                llm_stop()
                return


def llm_start(origin):
    port, _, _ = strata_profile()
    broker = None
    if not strata_unit_active():
        # Stop StudioPortal-owned Speech/Phone services if running so 3-card Strata gets all three MI50s cleanly.
        if phone_any_active():
            emit('status', message='Beende Telefon-Modus für 3-Karten-Strata …')
            phone_stop()
        elif speech_running():
            emit('status', message='Beende Sprach-Server für 3-Karten-Strata …')
            speech_stop()
        # wait our turn for all three cards like any other job and keep them until Strata is up, so no job slips in
        # during its start; once Strata runs, the broker sees it on all cards (foreign + mi50 lock) and hands out none
        broker = Broker(time.time_ns(), 'llm', 'Strata starten', origin)
        try:
            broker.acquire(3, lambda message, position: emit('waiting', message=message, position=position))
        except BaseException:
            broker.close()
            raise
        emit('status', message='Strata startet (~75 s) …')
        LLM_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        log = (LLM_DIR / 'start.log').open('wb')
        subprocess.Popen([str(STRATA_START), '--start'], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                         start_new_session=True, close_fds=True)
        log.close()
        (LLM_DIR / 'started-by-studioportal').touch()
        llm_touch()
        subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--llm-idle-watch'], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
    try:
        deadline = time.time() + 300
        while not strata_healthy(port):
            if cancelled.is_set():
                raise RuntimeError('Abgebrochen.')
            if time.time() > deadline or (time.time() > deadline - 290 and not strata_unit_active()):
                tail = (LLM_DIR / 'start.log').read_text(errors='replace')[-600:] if (LLM_DIR / 'start.log').is_file() else ''
                raise RuntimeError('Strata ist nicht gestartet. ' + tail.strip())
            time.sleep(2)
    finally:
        if broker:
            broker.release()
            broker.close()


def llm_messages(raw):
    if not isinstance(raw, list) or not 1 <= len(raw) <= 400:
        raise ValueError('messages fehlt oder ist zu lang.')
    clean, size = [], 0
    for item in raw:
        role, content = (item or {}).get('role'), (item or {}).get('content')
        if role not in ('system', 'user', 'assistant') or not isinstance(content, (str, list)):
            raise ValueError('Ungültige Nachricht (role system/user/assistant, content Text oder Bildteile).')
        size += len(json.dumps(content))
        clean.append({'role': role, 'content': content})
    if size > 40 * 1024 * 1024:
        raise ValueError('Die Unterhaltung ist größer als 40 MB.')
    return clean


LLM_EFFORTS = {
    'none': 'none', 'off': 'none', 'aus': 'none', 'false': 'none',
    'low': 'low', 'niedrig': 'low', 'kurz': 'low',
    'medium': 'medium', 'mittel': 'medium',
    'high': 'high', 'xhigh': 'high', 'hoch': 'high', 'tief': 'high', 'max': 'high',
}


def llm_effort(request):
    raw = request.get('reasoning_effort')
    if raw is None or raw == '':
        raw = request.get('thinking')
    if raw is None or raw is False or raw == '':
        return 'none'
    if raw is True:
        return 'medium'
    key = str(raw).strip().lower()
    if key == 'true':
        return 'medium'
    if key not in LLM_EFFORTS:
        raise ValueError('Ungültige Denkstufe (none, low, medium, high).')
    return LLM_EFFORTS[key]


def llm_chat(request, origin):
    import urllib.request
    messages = llm_messages(request.get('messages'))
    effort = llm_effort(request)
    max_tokens = int(request.get('max_tokens') or 4096)
    if not 1 <= max_tokens <= LLM_MAX_TOKENS:
        raise ValueError(f'max_tokens muss zwischen 1 und {LLM_MAX_TOKENS} liegen.')
    if not strata_unit_active() or not strata_healthy(strata_profile()[0]):
        if request.get('start', True) is False:
            raise RuntimeError('Strata läuft nicht (start=true startet es).')
        llm_start(origin)
    llm_touch()
    port, key, model = strata_profile()
    kwargs = {'enable_thinking': effort != 'none', **({'reasoning_effort': effort} if effort != 'none' else {})}
    body = {'model': model, 'messages': messages, 'max_tokens': max_tokens, 'stream': True,
            'stream_options': {'include_usage': True}, 'reasoning_effort': effort,
            'chat_template_kwargs': kwargs}
    if isinstance(request.get('temperature'), (int, float)):
        body['temperature'] = max(0.0, min(2.0, float(request['temperature'])))
    req = urllib.request.Request(f'http://127.0.0.1:{port}/v1/chat/completions', json.dumps(body).encode(),
                                 {'Content-Type': 'application/json', **({'Authorization': 'Bearer ' + key} if key else {})})
    emit('status', message='Strata denkt nach …' if effort != 'none' else 'Strata antwortet …')
    start, first, text, reasoning, usage, timings, finish = time.time(), None, [], [], None, None, None
    pending, pending_reasoning, last_flush = '', '', time.time()
    with urllib.request.urlopen(req, timeout=1800) as reply:
        for raw in reply:
            if cancelled.is_set():
                raise RuntimeError('Abgebrochen.')
            line = raw.decode('utf-8', 'replace').strip()
            if not line.startswith('data:') or line.endswith('[DONE]'):
                continue
            chunk = json.loads(line[5:])
            usage, timings = chunk.get('usage') or usage, chunk.get('timings') or timings
            for choice in chunk.get('choices', []):
                delta = choice.get('delta') or {}
                finish = choice.get('finish_reason') or finish
                if delta.get('reasoning_content'):
                    first = first or time.time()
                    reasoning.append(delta['reasoning_content'])
                    pending_reasoning += delta['reasoning_content']
                if delta.get('content'):
                    first = first or time.time()
                    text.append(delta['content'])
                    pending += delta['content']
            if (pending or pending_reasoning) and time.time() - last_flush > 0.08:
                if pending_reasoning:
                    emit('reasoning', text=pending_reasoning)
                    pending_reasoning = ''
                if pending:
                    emit('token', text=pending)
                    pending = ''
                last_flush = time.time()
    if pending_reasoning:
        emit('reasoning', text=pending_reasoning)
    if pending:
        emit('token', text=pending)
    llm_touch()
    tokens = (usage or {}).get('completion_tokens') or 0
    tps = (timings or {}).get('predicted_per_second')
    give_result({'text': ''.join(text), 'reasoning': ''.join(reasoning) or None,
                 'reasoning_effort': effort, 'finish_reason': finish, 'model': model,
                 'prompt_tokens': (usage or {}).get('prompt_tokens'), 'completion_tokens': tokens,
                 'tokens_per_second': round(tps, 1) if tps else None,
                 'prompt_tokens_per_second': (timings or {}).get('prompt_per_second'),
                 'first_token_s': round(first - start, 2) if first else None, 'seconds': round(time.time() - start, 2)})


def serve_llm(request):
    action, origin = request.get('action', 'status'), clean_origin(request)
    if action == 'status':
        give_result(llm_state())
    elif action == 'start':
        llm_start(origin)
        give_result(llm_state())
    elif action == 'stop':
        if strata_unit_active() and not request.get('force') and not (LLM_DIR / 'started-by-studioportal').is_file():
            raise ValueError('Strata wurde nicht von StudioPortal gestartet (z. B. Desktop/Hermes) – force=true stoppt es trotzdem.')
        llm_stop()
        give_result(llm_state())
    elif action == 'chat':
        llm_chat(request, origin)
    else:
        raise ValueError('Unbekannte LLM-Aktion (status, start, stop, chat).')


# ---- Speech (Fish Audio Drama 3 / Qwen3-TTS) & Live Phone Simulator (2+1 GPU Split) ---------------------------------
# Runs 0xShug0/audio.cpp on 1x MI50 (OCuLink card 1 preferred in 2+1 mode) + AVX-512 CPU (Nemotron 3.5 ASR + Smart Turn)
# + optional 2-card Strata (GPU 0 + GPU 2, 32k context) for simultaneous low-latency voice conversations.
AUDIO_ROOT = Path.home() / 'drama3'
AUDIO_CPP_BIN = AUDIO_ROOT / 'audio.cpp' / 'build-hip-gfx906' / 'bin'
AUDIO_SERVER = AUDIO_CPP_BIN / 'audiocpp_server'
AUDIO_MODELS = AUDIO_ROOT / 'models'
DRAMA3_GGUF = AUDIO_MODELS / 'Drama-3-GGUF-V2' / 'drama-3-backbone-8bit-F32-routers-experts-Q4_K_S.gguf'
VOICE_DIR = AUDIO_ROOT / 'voices'
DEFAULT_DRAMA3_VOICE = VOICE_DIR / 'lukas-de.wav'
DEFAULT_DRAMA3_VOICE_TEXT = VOICE_DIR / 'lukas-de.txt'
DEFAULT_DRAMA3_FALLBACK_TEXT = 'Grüß Sie, hier ist Lukas von Studio Nordweb.'
VOICE_PRESETS = {
    'laura': ('laura-de.wav', 'laura-de.txt', 'Grüß Sie, hier ist Laura von Studio Nordweb.'),
    'lukas': ('lukas-de.wav', 'lukas-de.txt', 'Grüß Sie, hier ist Lukas von Studio Nordweb.'),
    'jonas': ('jonas-de.wav', 'jonas-de.txt', 'Grüß Sie, hier ist Lukas von Studio Nordweb.'),
}
NEMOTRON_GGUF = AUDIO_MODELS / 'Nemotron-3.5-ASR-Streaming-0.6B-GGUF' / 'nemotron-3.5-asr-streaming-0.6b-q8_0.gguf'
SMART_TURN_GGUF = AUDIO_MODELS / 'Smart-Turn-v3-GGUF' / 'smart-turn-v3.2-f32.gguf'
STRATA_PHONE_CFG = AUDIO_ROOT / 'strata-phone-2gpu.json'
STRATA_PHONE_CWD = Path.home() / 'llm' / 'strata-v0216-mi50' / 'terminal'
STRATA_COOLED_RUN = Path.home() / '.local' / 'bin' / 'mi50-cooled-run'
STRATA_ROCM_WRAP = Path.home() / '.local' / 'bin' / 'mi50-rocm'
STRATA_PYTHON = Path.home() / 'llm' / 'strata-orca-iq3m-v01402-vision' / 'Strata' / '.venv' / 'bin' / 'python'
OCULINK_UID = 'GPU-215c20a173497dd3'
SPEECH_DIR = BASE / 'speech'
PHONE_DIR = BASE / 'phone'
SPEECH_PORT = int(os.environ.get('MODELLE_SPEECH_PORT', '8035'))
CPU_AUDIO_PORT = int(os.environ.get('MODELLE_CPU_AUDIO_PORT', '8036'))
PHONE_LLM_PORT = int(os.environ.get('MODELLE_PHONE_LLM_PORT', '8081'))
SPEECH_IDLE_MINUTES = 15
SPEECH_SAMPLE_RATES = {'drama-3': 44100, 'qwen3-tts': 24000}
GERMAN_ABBREV = re.compile(r'(?:\b(?:z\.\s*B|d\.\s*h|u\.\s*a|Dr|Prof|Hr|Fr|Nr|ca|bzw|usw|inkl|zzgl|Tel|Str|Mio|Mrd|Std|Min|Sek|evtl|ggf|etc|[a-zäöü])\.|(?:\b\d+\.))$', re.IGNORECASE)


def find_qwen3_tts_model():
    for pattern in ('Qwen3-TTS-*CustomVoice*/*.gguf', 'Qwen3-TTS-*Base*/*.gguf', 'Qwen3-TTS*/*.gguf'):
        found = sorted(AUDIO_MODELS.glob(pattern))
        if found:
            return found[0]
    return None


def _http_ok(url, timeout=2):
    import urllib.request
    try:
        with urllib.request.urlopen(url, timeout=timeout) as reply:
            return reply.status == 200
    except OSError:
        return False


def _read_pid(path):
    try:
        pid = int(path.read_text().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


def _stop_pidfile(path, timeout=8):
    pid = _read_pid(path)
    path.unlink(missing_ok=True)
    if pid is None:
        return
    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.15)
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def _hot_card_temp():
    if os.environ.get('MODELLE_FAKE_GPU') == '1':
        return 40
    peak = 0
    for label in Path('/sys/class/drm').glob('card[0-9]*/device/hwmon/hwmon*/temp*_label'):
        try:
            if label.read_text().strip() == 'junction':
                val = int(label.with_name(label.name.replace('_label', '_input')).read_text().strip()) // 1000
                peak = max(peak, val)
        except (OSError, ValueError):
            pass
    return peak


def _audio_env(cards=None, rocr_override=None):
    env = os.environ.copy()
    for key in ('HSA_OVERRIDE_GFX_VERSION', 'CUDA_VISIBLE_DEVICES'):
        env.pop(key, None)
    lib_parts = [str(ROCM / 'lib'), str(ROCM / 'lib64')]
    if env.get('LD_LIBRARY_PATH'):
        lib_parts.append(env['LD_LIBRARY_PATH'])
    env['ROCM_PATH'] = str(ROCM)
    env['HIP_PATH'] = str(ROCM)
    env['LD_LIBRARY_PATH'] = ':'.join(lib_parts)
    if rocr_override is not None:
        env['ROCR_VISIBLE_DEVICES'] = rocr_override
        env['HIP_VISIBLE_DEVICES'] = '0'
    elif cards is not None:
        env['ROCR_VISIBLE_DEVICES'] = ','.join(str(c) for c in sorted(cards))
        env['HIP_VISIBLE_DEVICES'] = ','.join(str(i) for i in range(len(cards)))
    else:
        env.pop('ROCR_VISIBLE_DEVICES', None)
        env.pop('HIP_VISIBLE_DEVICES', None)
    return env


def speech_touch():
    SPEECH_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    (SPEECH_DIR / 'last_use').touch()


def phone_touch():
    PHONE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    (PHONE_DIR / 'last_use').touch()
    speech_touch()


def speech_running():
    return _read_pid(SPEECH_DIR / 'pid') is not None and _http_ok(f'http://127.0.0.1:{SPEECH_PORT}/health')


def cpu_audio_running():
    return _read_pid(PHONE_DIR / 'cpu_pid') is not None and _http_ok(f'http://127.0.0.1:{CPU_AUDIO_PORT}/health')


def phone_llm_running():
    import urllib.request
    if _read_pid(PHONE_DIR / 'llm_pid') is None:
        return False
    try:
        with urllib.request.urlopen(f'http://127.0.0.1:{PHONE_LLM_PORT}/health', timeout=2) as reply:
            data = json.loads(reply.read().decode())
            return reply.status == 200 and bool(data.get('loaded', True))
    except (OSError, ValueError):
        return False


def phone_any_active():
    return any(_read_pid(p) is not None for p in (PHONE_DIR / 'llm_pid', PHONE_DIR / 'cpu_pid'))


def speech_models_list():
    models = []
    if DRAMA3_GGUF.is_file():
        models.append({
            'id': 'drama-3',
            'family': 'fish_drama3',
            'path': str(DRAMA3_GGUF),
            'task': 'tts',
            'mode': 'streaming',
            'lazy': False,
            'session_options': {
                'moe_cpu_expert_layers': 0,
                'fish_drama3.perf_mode': 'cuda_perf',
                'fish_drama3.codec_batch_frames': 2,
                'fish_drama3.codec_async_decode': True,
                'fish_drama3.reference_cache_slots': 8,
                'fish_drama3.context_length': 2048,
            },
            'default_request_options': {
                'max_tokens': 1024,
                'temperature': 1.0,
                'top_p': 0.9,
                'top_k': 4097,
                'text_chunk_size': 128,
            },
        })
    qwen_tts = find_qwen3_tts_model()
    if qwen_tts is not None:
        models.append({
            'id': 'qwen3-tts',
            'family': 'qwen3_tts',
            'path': str(qwen_tts),
            'task': 'tts',
            'mode': 'streaming',
            'lazy': DRAMA3_GGUF.is_file(),
            'session_options': {
                'qwen3_tts.perf_mode': 'cuda_perf',
            },
            'default_request_options': {
                'language': 'German',
                'voice_id': 'Ryan',
                'max_tokens': 1024,
            },
        })
    return models


def speech_state():
    pid = _read_pid(SPEECH_DIR / 'pid')
    ready = pid is not None and _http_ok(f'http://127.0.0.1:{SPEECH_PORT}/health')
    card = None
    try:
        card = int((SPEECH_DIR / 'card').read_text().strip())
    except (OSError, ValueError):
        pass
    last = SPEECH_DIR / 'last_use'
    idle = int(time.time() - last.stat().st_mtime) if last.is_file() else None
    qwen_tts = find_qwen3_tts_model()
    engines = []
    if DRAMA3_GGUF.is_file():
        engines.append('drama-3')
    if qwen_tts is not None:
        engines.append('qwen3-tts')
    return {
        'running': ready,
        'starting': pid is not None and not ready,
        'card': card if pid is not None else None,
        'engines': engines,
        'drama3_available': DRAMA3_GGUF.is_file(),
        'qwen3_tts_available': qwen_tts is not None,
        'model': DRAMA3_GGUF.name if DRAMA3_GGUF.is_file() else (qwen_tts.name if qwen_tts else None),
        'idle_seconds': idle,
        'auto_stop_minutes': SPEECH_IDLE_MINUTES if pid is not None else None,
    }


def speech_stop():
    _stop_pidfile(SPEECH_DIR / 'pid')
    (SPEECH_DIR / 'card').unlink(missing_ok=True)


def speech_idle_watch():
    pid_file, last = SPEECH_DIR / 'pid', SPEECH_DIR / 'last_use'
    while True:
        time.sleep(5)
        if _read_pid(pid_file) is None:
            return
        if _hot_card_temp() >= 91:
            speech_stop()
            return
        if last.is_file() and time.time() - last.stat().st_mtime > SPEECH_IDLE_MINUTES * 60:
            speech_stop()
            return


def speech_start(origin, prefer_oculink=False, skip_broker=False):
    if speech_running():
        if prefer_oculink:
            try:
                if int((SPEECH_DIR / 'card').read_text().strip()) == 1:
                    speech_touch()
                    return
            except (OSError, ValueError):
                pass
            speech_stop()
        else:
            speech_touch()
            return
    if not AUDIO_SERVER.is_file():
        raise RuntimeError('audio.cpp (audiocpp_server) wurde auf bigki nicht gefunden.')
    models = speech_models_list()
    if not models:
        raise RuntimeError('Kein TTS-Modell (Drama 3 oder Qwen3-TTS) auf bigki gefunden.')
    SPEECH_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    broker = None
    card = 1 if prefer_oculink else 0
    if not skip_broker:
        broker = Broker(time.time_ns(), 'speech', 'Sprache (Drama 3)', origin)
        try:
            cards = broker.acquire(1, lambda message, position: emit('waiting', message=message, position=position))
            card = cards[0]
        except BaseException:
            broker.close()
            raise
    try:
        cfg = {
            'host': '127.0.0.1',
            'port': SPEECH_PORT,
            'backend': 'hip',
            'threads': 6,
            'lazy_load': True,
            'max_loaded_models': 2,
            'idle_unload_ms': 0,
            'ui': False,
            'models': models,
        }
        cfg_path = SPEECH_DIR / 'server-gpu.json'
        cfg_path.write_text(json.dumps(cfg, indent=2) + '\n')
        emit('status', message='Fish Audio Drama 3 lädt auf MI50 …')
        log = (SPEECH_DIR / 'server.log').open('wb')
        if prefer_oculink and os.environ.get('MODELLE_FAKE_GPU') != '1':
            env = _audio_env(rocr_override=OCULINK_UID)
        else:
            env = _audio_env(cards=[card])
        proc = subprocess.Popen(
            [str(AUDIO_SERVER), '--config', str(cfg_path), '--no-ui', '--log'],
            cwd=str(AUDIO_ROOT), env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True, close_fds=True,
        )
        log.close()
        (SPEECH_DIR / 'pid').write_text(str(proc.pid))
        (SPEECH_DIR / 'card').write_text(str(card))
        speech_touch()
        subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--speech-idle-watch'],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, close_fds=True)
        deadline = time.time() + 180
        while not _http_ok(f'http://127.0.0.1:{SPEECH_PORT}/health'):
            if cancelled.is_set():
                speech_stop()
                raise RuntimeError('Abgebrochen.')
            if proc.poll() is not None or time.time() > deadline:
                tail = (SPEECH_DIR / 'server.log').read_text(errors='replace')[-700:] if (SPEECH_DIR / 'server.log').is_file() else ''
                speech_stop()
                raise RuntimeError('Sprach-Server konnte nicht gestartet werden. ' + tail.strip())
            time.sleep(0.5)
    finally:
        if broker:
            broker.release()
            broker.close()


def default_drama3_voice_ref(voice_preset=None):
    key = (voice_preset or '').strip().lower()
    if key in VOICE_PRESETS:
        wname, tname, fallback = VOICE_PRESETS[key]
        wpath, tpath = VOICE_DIR / wname, VOICE_DIR / tname
        if wpath.is_file():
            try:
                loaded = tpath.read_text(encoding='utf-8').strip()
                if loaded:
                    return str(wpath), loaded
            except OSError:
                pass
            return str(wpath), fallback
    if not DEFAULT_DRAMA3_VOICE.is_file():
        return None, None
    ref_text = DEFAULT_DRAMA3_FALLBACK_TEXT
    try:
        loaded = DEFAULT_DRAMA3_VOICE_TEXT.read_text(encoding='utf-8').strip()
        if loaded:
            ref_text = loaded
    except OSError:
        pass
    return str(DEFAULT_DRAMA3_VOICE), ref_text


def _silent_wav_b64(duration_s=0.4, sr=16000):
    import io
    import wave
    buf = io.BytesIO()
    with wave.open(buf, 'wb') as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(sr)
        out.writeframes(b'\x00\x00' * int(sr * duration_s))
    return base64.b64encode(buf.getvalue()).decode('ascii')


def _tts_stream_request(text, engine='drama-3', voice_ref_b64=None, voice_ref_path=None, reference_text=None,
                        voice_preset=None, voice_style=None, speaker=None, instruct=None,
                        temperature=None, top_p=None, top_k=None,
                        seed=None, max_tokens=None, text_chunk_size=None, use_default_voice=True,
                        cancel_event=None, on_chunk=None):
    import urllib.request
    cancel_ev = cancel_event or cancelled
    spoken_input = text
    if engine == 'drama-3' and voice_style:
        tag = str(voice_style).strip()
        if tag.startswith('[') and tag.endswith(']') and not spoken_input.lstrip().startswith('['):
            spoken_input = f'{tag} {spoken_input}'
    payload = {
        'model': engine,
        'input': spoken_input,
        'response_format': 'pcm',
        'stream_format': 'sse',
    }
    opts = {}
    if engine == 'drama-3':
        if temperature is not None:
            opts['temperature'] = max(0.0, min(2.0, float(temperature)))
        if top_p is not None:
            opts['top_p'] = max(0.05, min(1.0, float(top_p)))
        if top_k is not None:
            opts['top_k'] = max(1, min(8192, int(top_k)))
        if max_tokens is not None:
            opts['max_tokens'] = max(32, min(4096, int(max_tokens)))
        if text_chunk_size is not None:
            opts['text_chunk_size'] = max(32, min(1024, int(text_chunk_size)))
        if voice_ref_b64:
            payload['voice_ref'] = {'type': 'base64', 'data': voice_ref_b64}
            if reference_text:
                opts['reference_text'] = str(reference_text)
        elif voice_ref_path:
            payload['voice_ref'] = str(voice_ref_path)
            if reference_text:
                opts['reference_text'] = str(reference_text)
        elif use_default_voice:
            default_path, default_txt = default_drama3_voice_ref(voice_preset)
            if default_path:
                payload['voice_ref'] = default_path
                opts['reference_text'] = default_txt
    elif engine == 'qwen3-tts':
        opts['language'] = 'German'
        if speaker:
            opts['voice_id'] = str(speaker)
        if instruct:
            opts['instruct'] = str(instruct)
        if max_tokens is not None:
            opts['max_tokens'] = max(32, min(2048, int(max_tokens)))
    if seed is not None and int(seed) >= 0:
        payload['seed'] = int(seed)
    if opts:
        payload['options'] = opts
    req = urllib.request.Request(
        f'http://127.0.0.1:{SPEECH_PORT}/v1/audio/speech',
        data=json.dumps(payload).encode('utf-8'),
        headers={'Content-Type': 'application/json', 'Accept': 'text/event-stream'},
    )
    t0 = time.monotonic()
    first_at = None
    server_ttft_ms = None
    total_pcm_bytes = 0
    sr = SPEECH_SAMPLE_RATES.get(engine, 44100)
    with urllib.request.urlopen(req, timeout=300) as reply:
        for raw in reply:
            if cancel_ev.is_set():
                raise RuntimeError('Abgebrochen.')
            line = raw.decode('utf-8', 'replace').strip()
            if not line.startswith('data:'):
                continue
            body = line[5:].strip()
            if body == '[DONE]':
                break
            event = json.loads(body)
            kind = event.get('type')
            if kind == 'speech.audio.delta':
                b64 = event.get('audio') or ''
                if b64:
                    if first_at is None:
                        first_at = time.monotonic()
                    raw_len = len(base64.b64decode(b64))
                    total_pcm_bytes += raw_len
                    if on_chunk:
                        on_chunk(b64, sr)
            elif kind == 'speech.audio.done':
                timing = event.get('timing') or {}
                if timing.get('ttft_ms') is not None:
                    server_ttft_ms = float(timing['ttft_ms'])
            elif kind == 'error':
                raise RuntimeError(event.get('message') or 'TTS-Fehler.')
    total_ms = (time.monotonic() - t0) * 1000.0
    ttfa_ms = server_ttft_ms if server_ttft_ms is not None else ((first_at - t0) * 1000.0 if first_at else total_ms)
    duration_s = (total_pcm_bytes / 2.0) / sr if total_pcm_bytes else 0.0
    rtf = (total_ms / 1000.0) / duration_s if duration_s > 0 else 0.0
    return {
        'sample_rate': sr,
        'duration_s': round(duration_s, 2),
        'ttfa_ms': round(ttfa_ms, 1),
        'total_ms': round(total_ms, 1),
        'rtf': round(rtf, 3),
        'pcm_bytes': total_pcm_bytes,
    }


def speech_speak(request, origin):
    text = (request.get('text') or '').strip()
    if not text:
        raise ValueError('Bitte gib einen Text zum Sprechen ein.')
    if len(text) > 12000:
        raise ValueError('Text darf höchstens 12.000 Zeichen lang sein.')
    engine = request.get('engine') or ('drama-3' if DRAMA3_GGUF.is_file() else 'qwen3-tts')
    if engine not in ('drama-3', 'qwen3-tts'):
        raise ValueError('Unbekannte Sprach-Engine (drama-3, qwen3-tts).')
    voice_ref_b64 = request.get('voice_ref_b64')
    if voice_ref_b64 and len(voice_ref_b64) > 8 * 1024 * 1024:
        raise ValueError('Referenz-Audio darf höchstens 5 MB groß sein.')
    threading.Thread(target=watch_connection, daemon=True).start()
    speech_start(origin)
    speech_touch()
    emit('status', message='Sprache wird erzeugt …')
    chunk_index = 0

    def emit_chunk(b64, sr):
        nonlocal chunk_index
        emit('audio_chunk', index=chunk_index, pcm_b64=b64, sample_rate=sr, channels=1)
        chunk_index += 1

    stats = _tts_stream_request(
        text=text, engine=engine, voice_ref_b64=voice_ref_b64,
        reference_text=request.get('reference_text'),
        speaker=request.get('speaker'), instruct=request.get('instruct'),
        temperature=request.get('temperature'), top_p=request.get('top_p'),
        top_k=request.get('top_k'), seed=request.get('seed'),
        max_tokens=request.get('max_tokens'), text_chunk_size=request.get('text_chunk_size'),
        use_default_voice=request.get('use_default_voice', True) is not False,
        on_chunk=emit_chunk,
    )
    speech_touch()
    give_result({**stats, 'engine': engine, 'chunks': chunk_index})


def serve_speech(request):
    action, origin = request.get('action', 'status'), clean_origin(request)
    if action == 'status':
        give_result(speech_state())
    elif action == 'start':
        threading.Thread(target=watch_connection, daemon=True).start()
        speech_start(origin)
        give_result(speech_state())
    elif action == 'stop':
        speech_stop()
        give_result(speech_state())
    elif action == 'speak':
        speech_speak(request, origin)
    else:
        raise ValueError('Unbekannte Sprach-Aktion (status, start, stop, speak).')


def cpu_audio_start():
    if cpu_audio_running():
        return
    if not AUDIO_SERVER.is_file():
        raise RuntimeError('audio.cpp (audiocpp_server) wurde auf bigki nicht gefunden.')
    models = []
    if NEMOTRON_GGUF.is_file():
        models.append({
            'id': 'nemotron-asr',
            'family': 'nemotron_asr',
            'path': str(NEMOTRON_GGUF),
            'task': 'asr',
            'mode': 'offline',
            'lazy': False,
        })
    if SMART_TURN_GGUF.is_file():
        models.append({
            'id': 'smart-turn',
            'family': 'smart_turn',
            'path': str(SMART_TURN_GGUF),
            'task': 'turn',
            'mode': 'offline',
            'lazy': False,
        })
    if not models:
        raise RuntimeError('Nemotron ASR / Smart Turn Modelle fehlen auf bigki.')
    PHONE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    cfg = {
        'host': '127.0.0.1',
        'port': CPU_AUDIO_PORT,
        'backend': 'cpu',
        'threads': 6,
        'lazy_load': False,
        'max_loaded_models': 2,
        'idle_unload_ms': 0,
        'ui': False,
        'models': models,
    }
    cfg_path = PHONE_DIR / 'server-cpu.json'
    cfg_path.write_text(json.dumps(cfg, indent=2) + '\n')
    log = (PHONE_DIR / 'cpu-audio.log').open('wb')
    proc = subprocess.Popen(
        [str(AUDIO_SERVER), '--config', str(cfg_path), '--no-ui', '--log'],
        cwd=str(AUDIO_ROOT), env=_audio_env(), stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
        start_new_session=True, close_fds=True,
    )
    log.close()
    (PHONE_DIR / 'cpu_pid').write_text(str(proc.pid))
    deadline = time.time() + 60
    while not _http_ok(f'http://127.0.0.1:{CPU_AUDIO_PORT}/health'):
        if proc.poll() is not None or time.time() > deadline:
            tail = (PHONE_DIR / 'cpu-audio.log').read_text(errors='replace')[-500:] if (PHONE_DIR / 'cpu-audio.log').is_file() else ''
            _stop_pidfile(PHONE_DIR / 'cpu_pid')
            raise RuntimeError('CPU-Audio-Server (STT/Smart Turn) konnte nicht gestartet werden. ' + tail.strip())
        time.sleep(0.25)


def phone_state():
    llm_ok = phone_llm_running()
    tts_ok = speech_running()
    cpu_ok = cpu_audio_running()
    starting = (
        (_read_pid(PHONE_DIR / 'llm_pid') is not None and not llm_ok)
        or (_read_pid(SPEECH_DIR / 'pid') is not None and not tts_ok)
        or (_read_pid(PHONE_DIR / 'cpu_pid') is not None and not cpu_ok)
    )
    last = PHONE_DIR / 'last_use'
    idle = int(time.time() - last.stat().st_mtime) if last.is_file() else None
    sp = speech_state()
    return {
        'ready': llm_ok and tts_ok and cpu_ok,
        'starting': starting,
        'llm_running': llm_ok,
        'tts_running': tts_ok,
        'cpu_audio_running': cpu_ok,
        'engines': sp['engines'],
        'drama3_available': sp['drama3_available'],
        'qwen3_tts_available': sp['qwen3_tts_available'],
        'stt_available': NEMOTRON_GGUF.is_file(),
        'smart_turn_available': SMART_TURN_GGUF.is_file(),
        'idle_seconds': idle,
        'auto_stop_minutes': SPEECH_IDLE_MINUTES if (llm_ok or tts_ok or cpu_ok) else None,
    }


def phone_stop():
    _stop_pidfile(PHONE_DIR / 'llm_pid', timeout=10)
    _stop_pidfile(PHONE_DIR / 'cpu_pid', timeout=5)
    speech_stop()


def phone_idle_watch():
    last = PHONE_DIR / 'last_use'
    while True:
        time.sleep(5)
        if not phone_any_active() and not speech_running():
            return
        if _hot_card_temp() >= 91:
            phone_stop()
            return
        if last.is_file() and time.time() - last.stat().st_mtime > SPEECH_IDLE_MINUTES * 60:
            phone_stop()
            return


def phone_start(origin):
    if phone_llm_running() and speech_running() and cpu_audio_running():
        phone_touch()
        return
    if not STRATA_PHONE_CFG.is_file():
        raise RuntimeError('2-Karten-Strata-Telefonprofil fehlt auf bigki.')
    # If 3-card StudioPortal Strata is running, stop it cleanly before entering 2+1 Phone Split.
    if strata_unit_active():
        if not (LLM_DIR / 'started-by-studioportal').is_file():
            raise RuntimeError('3-Karten-Strata läuft extern – bitte zuerst stoppen.')
        emit('status', message='Wechsle von 3-Karten-LLM auf 2+1-Telefon-Split …')
        llm_stop()
    # If speech server is running on a non-OCuLink card, restart it on card 1 (OCuLink) so GPU 0+2 stay free for Strata.
    if speech_running():
        try:
            if int((SPEECH_DIR / 'card').read_text().strip()) != 1:
                speech_stop()
        except (OSError, ValueError):
            speech_stop()
    PHONE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    broker = Broker(time.time_ns(), 'phone', 'Telefon (2+1 Split)', origin)
    try:
        broker.acquire(3, lambda message, position: emit('waiting', message=message, position=position))
    except BaseException:
        broker.close()
        raise
    try:
        emit('status', message='Starte Telefon-Stack (GPU 0+2: Qwen · GPU 1: Audio · CPU: STT) …')
        cpu_audio_start()
        errors = []

        def start_tts():
            try:
                speech_start(origin, prefer_oculink=True, skip_broker=True)
            except Exception as err:  # noqa: BLE001
                errors.append(err)

        def start_llm():
            try:
                if phone_llm_running():
                    return
                log = (PHONE_DIR / 'strata-phone.log').open('wb')
                if os.environ.get('MODELLE_FAKE_GPU') == '1':
                    cmd = [sys.executable, str(STRATA_PHONE_CFG.with_name('fake_strata_phone.py')), str(PHONE_LLM_PORT)]
                    cwd = str(AUDIO_ROOT)
                else:
                    cmd = [
                        str(STRATA_COOLED_RUN), '--both', str(STRATA_ROCM_WRAP), str(STRATA_PYTHON),
                        '-m', 'serve.server', '--engine', 'strata',
                        '--config', str(STRATA_PHONE_CFG),
                        '--host', '127.0.0.1', '--port', str(PHONE_LLM_PORT),
                    ]
                    cwd = str(STRATA_PHONE_CWD)
                proc = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                        start_new_session=True, close_fds=True)
                log.close()
                (PHONE_DIR / 'llm_pid').write_text(str(proc.pid))
                deadline = time.time() + 180
                while not phone_llm_running():
                    if cancelled.is_set():
                        _stop_pidfile(PHONE_DIR / 'llm_pid')
                        raise RuntimeError('Abgebrochen.')
                    if proc.poll() is not None or time.time() > deadline:
                        tail = (PHONE_DIR / 'strata-phone.log').read_text(errors='replace')[-700:] if (PHONE_DIR / 'strata-phone.log').is_file() else ''
                        _stop_pidfile(PHONE_DIR / 'llm_pid')
                        raise RuntimeError('2-Karten-Strata konnte nicht gestartet werden. ' + tail.strip())
                    time.sleep(1.0)
            except Exception as err:  # noqa: BLE001
                errors.append(err)

        t1 = threading.Thread(target=start_tts, daemon=True)
        t2 = threading.Thread(target=start_llm, daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
        if errors:
            phone_stop()
            raise errors[0]
        # Warm up ALL 3 subsystems in parallel (CPU STT/SmartTurn + GPU 1 Drama 3 w/ cached voice + GPU 0+2 Strata clocks)
        # so even Turn 1 starts at warm speed instead of paying cold graph/reference capture penalties.
        if os.environ.get('MODELLE_FAKE_GPU') != '1':
            emit('status', message='Wärme Sprach-, STT- und LLM-Graphen vor …')
            warm_threads = []

            def warm_tts():
                try:
                    warm_eng = 'drama-3' if DRAMA3_GGUF.is_file() else 'qwen3-tts'
                    if warm_eng == 'drama-3':
                        for preset_key in ('laura', 'lukas'):
                            _tts_stream_request(text='Hallo.', engine=warm_eng, voice_preset=preset_key,
                                                voice_style='[calm, warm]', max_tokens=20, seed=42, use_default_voice=True)
                    else:
                        _tts_stream_request(text='Hallo.', engine=warm_eng, max_tokens=24, seed=42, use_default_voice=True)
                except Exception:
                    pass

            def warm_cpu():
                try:
                    wav_b64 = _silent_wav_b64(0.4, 16000)
                    if SMART_TURN_GGUF.is_file():
                        _http_post_json(f'http://127.0.0.1:{CPU_AUDIO_PORT}/v1/tasks/run', {
                            'model': 'smart-turn',
                            'request': {'audio_base64': wav_b64, 'options': {'threshold': '0.5'}},
                        }, timeout=15)
                    if NEMOTRON_GGUF.is_file():
                        _http_post_json(f'http://127.0.0.1:{CPU_AUDIO_PORT}/v1/tasks/run', {
                            'model': 'nemotron-asr',
                            'request': {'audio_base64': wav_b64, 'language': 'de-DE'},
                        }, timeout=30)
                except Exception:
                    pass

            def warm_llm():
                try:
                    _phone_llm_warmup([{'role': 'user', 'content': 'Hallo'}])
                except Exception:
                    pass

            for fn in (warm_tts, warm_cpu, warm_llm):
                wt = threading.Thread(target=fn, daemon=True)
                wt.start()
                warm_threads.append(wt)
            for wt in warm_threads:
                wt.join(timeout=45)
        phone_touch()
        subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--phone-idle-watch'],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, close_fds=True)
    finally:
        broker.release()
        broker.close()


def _http_post_json(url, payload, timeout=30):
    import urllib.request
    req = urllib.request.Request(url, data=json.dumps(payload).encode('utf-8'),
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=timeout) as reply:
        return json.loads(reply.read().decode('utf-8'))


def _phone_model_name():
    model_name = 'orcarouter-qwen3.8-flash-next-uncensored-iq3_m'
    try:
        model_name = json.loads(STRATA_PHONE_CFG.read_text()).get('model_name', model_name)
    except (OSError, ValueError):
        pass
    return model_name


def _phone_llm_warmup(messages):
    """Pre-fills Strata's KV prefix cache with the call's system prompt (reasoning strictly OFF, max_tokens=2)."""
    req_messages = list(messages)
    if not req_messages or req_messages[-1].get('role') != 'user':
        req_messages.append({'role': 'user', 'content': '(Leitung steht, gleich meldet sich das Gegenüber.)'})
    t0 = time.monotonic()
    res = _http_post_json(f'http://127.0.0.1:{PHONE_LLM_PORT}/v1/chat/completions', {
        'model': _phone_model_name(),
        'messages': req_messages,
        'max_tokens': 2,
        'temperature': 0.0,
        'stream': False,
        'reasoning_effort': 'none',
        'chat_template_kwargs': {'enable_thinking': False},
    }, timeout=30)
    reply = ''
    try:
        reply = ((res.get('choices') or [{}])[0].get('message') or {}).get('content') or ''
    except (AttributeError, IndexError, TypeError):
        pass
    return round((time.monotonic() - t0) * 1000.0, 1), reply


def phone_warmup(request):
    """Pre-warms Strata's KV cache with the active call's system prompt + anchor turn so even Turn 1 gets a KV hit (~200 ms)."""
    messages = llm_messages(request.get('messages'))
    if not phone_llm_running():
        give_result({'warmed': False, 'warmup_ms': 0.0, 'warmup_reply': ''})
        return
    phone_touch()
    ms, reply = _phone_llm_warmup(messages)
    give_result({'warmed': True, 'warmup_ms': ms, 'warmup_reply': reply})


def _phone_listen_core(request):
    audio_b64 = request.get('audio_b64')
    if not isinstance(audio_b64, str) or not audio_b64:
        raise ValueError('audio_b64 fehlt (16 kHz Mono WAV).')
    if len(audio_b64) > 12 * 1024 * 1024:
        raise ValueError('Audio-Clip ist zu groß.')
    if not cpu_audio_running():
        cpu_audio_start()
    phone_touch()
    check_turn = request.get('check_turn', True) is not False
    do_stt = request.get('transcribe', True) is not False
    threshold = float(request.get('turn_threshold', 0.42))
    turn_complete, turn_prob, turn_ms = True, 1.0, 0.0
    if check_turn and SMART_TURN_GGUF.is_file():
        t0 = time.monotonic()
        res = _http_post_json(f'http://127.0.0.1:{CPU_AUDIO_PORT}/v1/tasks/run', {
            'model': 'smart-turn',
            'request': {'audio_base64': audio_b64, 'options': {'threshold': str(threshold)}},
        }, timeout=15)
        turn_ms = round((time.monotonic() - t0) * 1000.0, 1)
        data = (res.get('custom_schema_output') or {}).get('data') or {}
        if 'complete' in data:
            turn_complete = bool(data['complete'])
            turn_prob = float(data.get('probability', 1.0 if turn_complete else 0.0))
    text, stt_ms = '', 0.0
    if do_stt and (turn_complete or request.get('force_transcribe', False)):
        t1 = time.monotonic()
        res = _http_post_json(f'http://127.0.0.1:{CPU_AUDIO_PORT}/v1/tasks/run', {
            'model': 'nemotron-asr',
            'request': {'audio_base64': audio_b64, 'language': str(request.get('language') or 'de-DE')},
        }, timeout=30)
        stt_ms = round((time.monotonic() - t1) * 1000.0, 1)
        text = (res.get('text_output') or res.get('text') or '').strip()
    return {
        'text': text,
        'turn_complete': turn_complete,
        'turn_probability': round(turn_prob, 3),
        'turn_ms': turn_ms,
        'stt_ms': stt_ms,
    }


def phone_listen(request):
    give_result(_phone_listen_core(request))


def clean_spoken_text(text):
    text = re.sub(r'[*_`#]+', '', text)
    text = re.sub(r'\s+', ' ', text).strip()
    return text


def pop_ready_sentence(buf, allow_clause=False):
    """Extract the first complete German sentence from a streaming LLM buffer.
    Only falls back to a comma/clause split when allow_clause=True and the first sentence exceeds 95 chars,
    avoiding unnatural mid-sentence intonation breaks in Drama 3."""
    for match in re.finditer(r'([.!?])(?:\s+|$)', buf):
        candidate = buf[:match.end()].strip()
        if not GERMAN_ABBREV.search(candidate) and len(candidate) >= 8:
            return candidate, buf[match.end():].lstrip()
    if allow_clause and len(buf) >= 95:
        clause = re.search(r'([,;:\u2013\u2014])(?:\s+)', buf[50:])
        if clause:
            cut = 50 + clause.end()
            return buf[:cut].strip(), buf[cut:].lstrip()
    return None, buf


def _phone_turn_core(messages, request, origin, emit_fn=emit, cancel_event=None):
    import urllib.request
    cancel_ev = cancel_event or cancelled
    engine = request.get('tts_engine') or ('drama-3' if DRAMA3_GGUF.is_file() else 'qwen3-tts')
    if engine not in ('drama-3', 'qwen3-tts'):
        raise ValueError('Unbekannte TTS-Engine (drama-3, qwen3-tts).')
    if not (phone_llm_running() and speech_running()):
        phone_start(origin)
    phone_touch()
    body = {
        'model': _phone_model_name(),
        'messages': messages,
        'max_tokens': min(int(request.get('max_tokens') or 110), 512),
        'temperature': max(0.0, min(1.5, float(request.get('temperature', 0.65)))),
        'stream': True,
        'stream_options': {'include_usage': True},
        'reasoning_effort': 'none',
        'chat_template_kwargs': {'enable_thinking': False},
    }
    req = urllib.request.Request(
        f'http://127.0.0.1:{PHONE_LLM_PORT}/v1/chat/completions',
        data=json.dumps(body).encode('utf-8'),
        headers={'Content-Type': 'application/json'},
    )
    t_start = time.monotonic()
    llm_first = None
    first_audio = None
    tts_first_ttfa = None
    total_pcm_bytes = 0
    sr = SPEECH_SAMPLE_RATES.get(engine, 44100)
    sent_queue = queue.Queue()
    tts_error = []
    chunk_counter = [0]

    def tts_worker():
        nonlocal first_audio, tts_first_ttfa, total_pcm_bytes
        while True:
            item = sent_queue.get()
            if item is None:
                return
            if cancel_ev.is_set():
                continue
            sent_idx, sent_text = item
            clean = clean_spoken_text(sent_text)
            if not clean:
                continue
            try:
                def on_chunk(b64, sample_rate):
                    nonlocal first_audio
                    if first_audio is None:
                        first_audio = time.monotonic()
                    emit_fn('audio_chunk', index=chunk_counter[0], sentence_index=sent_idx,
                            sentence=clean, pcm_b64=b64, sample_rate=sample_rate, channels=1)
                    chunk_counter[0] += 1

                stats = _tts_stream_request(
                    text=clean, engine=engine,
                    voice_ref_b64=request.get('voice_ref_b64'),
                    reference_text=request.get('reference_text'),
                    voice_preset=request.get('voice_preset'),
                    voice_style=request.get('voice_style', '[calm, warm]' if engine == 'drama-3' else None),
                    speaker=request.get('speaker'), instruct=request.get('instruct'),
                    temperature=request.get('tts_temperature'),
                    top_p=request.get('tts_top_p'), top_k=request.get('tts_top_k'),
                    seed=request.get('seed'), max_tokens=512, text_chunk_size=180,
                    use_default_voice=request.get('use_default_voice', True) is not False,
                    cancel_event=cancel_ev,
                    on_chunk=on_chunk,
                )
                total_pcm_bytes += stats['pcm_bytes']
                if tts_first_ttfa is None:
                    tts_first_ttfa = stats['ttfa_ms']
            except Exception as err:  # noqa: BLE001
                if not cancel_ev.is_set():
                    tts_error.append(err)

    worker = threading.Thread(target=tts_worker, daemon=True)
    worker.start()
    full_text = []
    pending_buf = ''
    sent_idx = 0
    timings = None
    try:
        with urllib.request.urlopen(req, timeout=120) as reply:
            for raw in reply:
                if cancel_ev.is_set():
                    raise RuntimeError('Abgebrochen.')
                line = raw.decode('utf-8', 'replace').strip()
                if not line.startswith('data:') or line.endswith('[DONE]'):
                    continue
                chunk = json.loads(line[5:])
                timings = chunk.get('timings') or timings
                for choice in chunk.get('choices', []):
                    piece = (choice.get('delta') or {}).get('content') or ''
                    if not piece:
                        continue
                    if llm_first is None:
                        llm_first = time.monotonic()
                    full_text.append(piece)
                    emit_fn('token', text=piece)
                    pending_buf += piece
                    sentence, pending_buf = pop_ready_sentence(pending_buf, allow_clause=(sent_idx == 0))
                    if sentence:
                        sent_queue.put((sent_idx, sentence))
                        sent_idx += 1
        tail = pending_buf.strip()
        if tail and not cancel_ev.is_set():
            sent_queue.put((sent_idx, tail))
            sent_idx += 1
    finally:
        sent_queue.put(None)
        worker.join(timeout=180)
    if tts_error and not cancel_ev.is_set():
        raise tts_error[0]
    if cancel_ev.is_set():
        raise RuntimeError('Abgebrochen.')
    phone_touch()
    total_ms = (time.monotonic() - t_start) * 1000.0
    duration_s = (total_pcm_bytes / 2.0) / sr if total_pcm_bytes else 0.0
    tps = (timings or {}).get('predicted_per_second')
    pp = (timings or {}).get('prompt_per_second')
    return {
        'text': ''.join(full_text).strip(),
        'engine': engine,
        'sample_rate': sr,
        'audio_duration_s': round(duration_s, 2),
        'llm_ttft_ms': round((llm_first - t_start) * 1000.0, 1) if llm_first else None,
        'tts_ttfa_ms': round(tts_first_ttfa, 1) if tts_first_ttfa is not None else None,
        'first_audio_ms': round((first_audio - t_start) * 1000.0, 1) if first_audio else None,
        'total_ms': round(total_ms, 1),
        'tokens_per_second': round(tps, 1) if tps else None,
        'prompt_tokens_per_second': round(pp, 1) if pp else None,
        'sentences': sent_idx,
        'chunks': chunk_counter[0],
    }


def phone_turn(request, origin):
    messages = llm_messages(request.get('messages'))
    threading.Thread(target=watch_connection, daemon=True).start()
    give_result(_phone_turn_core(messages, request, origin))


def _phone_converse_core(request, origin, emit_fn=emit, cancel_event=None):
    cancel_ev = cancel_event or cancelled
    t_all = time.monotonic()
    base_messages = llm_messages(request.get('messages'))
    listen = _phone_listen_core(request)
    if cancel_ev.is_set():
        raise RuntimeError('Abgebrochen.')
    if not listen['turn_complete'] and not request.get('force_transcribe', False):
        return {
            'turn_complete': False,
            'turn_probability': listen['turn_probability'],
            'turn_ms': listen['turn_ms'],
            'stt_ms': 0.0,
            'user_text': '',
            'text': '',
        }
    user_text = listen['text']
    if not user_text:
        return {
            'turn_complete': True,
            'turn_probability': listen['turn_probability'],
            'turn_ms': listen['turn_ms'],
            'stt_ms': listen['stt_ms'],
            'user_text': '',
            'text': '',
        }
    emit_fn('transcript', text=user_text, stt_ms=listen['stt_ms'], turn_ms=listen['turn_ms'])
    turn_messages = list(base_messages) + [{'role': 'user', 'content': user_text}]
    turn = _phone_turn_core(turn_messages, request, origin, emit_fn=emit_fn, cancel_event=cancel_ev)
    e2e_first = None
    if turn.get('first_audio_ms') is not None:
        e2e_first = round(listen['turn_ms'] + listen['stt_ms'] + turn['first_audio_ms'], 1)
    return {
        **turn,
        'turn_complete': True,
        'turn_probability': listen['turn_probability'],
        'turn_ms': listen['turn_ms'],
        'stt_ms': listen['stt_ms'],
        'user_text': user_text,
        'e2e_first_audio_ms': e2e_first,
        'e2e_total_ms': round((time.monotonic() - t_all) * 1000.0, 1),
    }


def phone_converse(request, origin):
    """Single-hop voice turn: Smart Turn -> Nemotron ASR -> emit transcript -> Strata LLM (no reasoning) -> Drama 3 TTS."""
    threading.Thread(target=watch_connection, daemon=True).start()
    give_result(_phone_converse_core(request, origin))


def phone_session(origin):
    """Persistent bidirectional JSONL phone session over ONE open SSH pipe (0 ms SSH/Python startup per turn,
    instant <5 ms server-side cancel on barge-in)."""
    emit('session_ready', ready=phone_llm_running() and speech_running() and cpu_audio_running())
    turns_lock = threading.Lock()
    active_turns = {}

    def cancel_turns(target_id=None):
        with turns_lock:
            if target_id is None:
                for ev in active_turns.values():
                    ev.set()
            elif target_id in active_turns:
                active_turns[target_id].set()

    def run_cmd(req):
        req_id = req.get('id')
        cmd = req.get('cmd')
        ev = threading.Event()
        with turns_lock:
            if req_id is not None:
                active_turns[req_id] = ev

        def emit_tagged(kind, **fields):
            emit(kind, id=req_id, **fields)

        try:
            if cmd == 'warmup':
                messages = llm_messages(req.get('messages'))
                if not phone_llm_running():
                    res = {'warmed': False, 'warmup_ms': 0.0, 'warmup_reply': ''}
                else:
                    phone_touch()
                    ms, reply = _phone_llm_warmup(messages)
                    res = {'warmed': True, 'warmup_ms': ms, 'warmup_reply': reply}
                emit('session_result', id=req_id, result=res)
            elif cmd == 'converse':
                res = _phone_converse_core(req, origin, emit_fn=emit_tagged, cancel_event=ev)
                emit('session_result', id=req_id, result=res)
            elif cmd == 'turn':
                messages = llm_messages(req.get('messages'))
                res = _phone_turn_core(messages, req, origin, emit_fn=emit_tagged, cancel_event=ev)
                emit('session_result', id=req_id, result=res)
            elif cmd == 'listen':
                res = _phone_listen_core(req)
                emit('session_result', id=req_id, result=res)
            elif cmd == 'llm_stream':
                import urllib.request
                messages = llm_messages(req.get('messages'))
                if not phone_llm_running():
                    phone_start(origin)
                phone_touch()
                body = {
                    'model': _phone_model_name(),
                    'messages': messages,
                    'max_tokens': min(int(req.get('max_tokens') or 110), 512),
                    'temperature': max(0.0, min(1.5, float(req.get('temperature', 0.65)))),
                    'stream': True,
                    'stream_options': {'include_usage': True},
                    'reasoning_effort': 'none',
                    'chat_template_kwargs': {'enable_thinking': False},
                }
                http_req = urllib.request.Request(
                    f'http://127.0.0.1:{PHONE_LLM_PORT}/v1/chat/completions',
                    data=json.dumps(body).encode('utf-8'),
                    headers={'Content-Type': 'application/json'},
                )
                t0 = time.monotonic()
                first_tok = None
                full_out = []
                timings = None
                with urllib.request.urlopen(http_req, timeout=120) as reply:
                    for raw_line in reply:
                        if ev.is_set() or cancelled.is_set():
                            raise RuntimeError('Abgebrochen.')
                        sline = raw_line.decode('utf-8', 'replace').strip()
                        if not sline.startswith('data:') or sline.endswith('[DONE]'):
                            continue
                        chunk = json.loads(sline[5:])
                        timings = chunk.get('timings') or timings
                        for choice in chunk.get('choices', []):
                            piece = (choice.get('delta') or {}).get('content') or ''
                            if not piece:
                                continue
                            if first_tok is None:
                                first_tok = time.monotonic()
                            full_out.append(piece)
                            emit_tagged('token', text=piece)
                phone_touch()
                res = {
                    'text': ''.join(full_out).strip(),
                    'llm_ttft_ms': round((first_tok - t0) * 1000.0, 1) if first_tok else None,
                    'tokens_per_second': round((timings or {}).get('predicted_per_second') or 0.0, 1) or None,
                    'prompt_tokens_per_second': round((timings or {}).get('prompt_per_second') or 0.0, 1) or None,
                }
                emit('session_result', id=req_id, result=res)
            elif cmd == 'tts_stream':
                text = clean_spoken_text(req.get('text') or '')
                engine = req.get('tts_engine') or ('drama-3' if DRAMA3_GGUF.is_file() else 'qwen3-tts')
                if engine not in ('drama-3', 'qwen3-tts'):
                    raise ValueError('Unbekannte TTS-Engine (drama-3, qwen3-tts).')
                if not speech_running():
                    speech_start(origin, prefer_oculink=True)
                phone_touch()
                chunk_idx = [0]

                def on_tts_chunk(b64, sample_rate):
                    emit_tagged('audio_chunk', index=chunk_idx[0], pcm_b64=b64, sample_rate=sample_rate, channels=1)
                    chunk_idx[0] += 1

                if not text:
                    res = {'sample_rate': SPEECH_SAMPLE_RATES.get(engine, 44100), 'pcm_bytes': 0, 'ttfa_ms': 0.0, 'chunks': 0}
                else:
                    stats = _tts_stream_request(
                        text=text, engine=engine,
                        voice_ref_b64=req.get('voice_ref_b64'),
                        reference_text=req.get('reference_text'),
                        voice_preset=req.get('voice_preset'),
                        voice_style=req.get('voice_style', '[calm, warm]' if engine == 'drama-3' else None),
                        speaker=req.get('speaker'), instruct=req.get('instruct'),
                        temperature=req.get('tts_temperature'),
                        top_p=req.get('tts_top_p'), top_k=req.get('tts_top_k'),
                        seed=req.get('seed'), max_tokens=512, text_chunk_size=180,
                        use_default_voice=req.get('use_default_voice', True) is not False,
                        cancel_event=ev,
                        on_chunk=on_tts_chunk,
                    )
                    res = {**stats, 'engine': engine, 'chunks': chunk_idx[0]}
                phone_touch()
                emit('session_result', id=req_id, result=res)
            else:
                emit('session_error', id=req_id, message=f'Unbekannter Sitzungsbefehl: {cmd}')
        except Exception as err:  # noqa: BLE001
            if ev.is_set() or cancelled.is_set():
                emit('session_cancelled', id=req_id)
            else:
                emit('session_error', id=req_id, message=str(err))
        finally:
            with turns_lock:
                if req_id is not None and active_turns.get(req_id) is ev:
                    active_turns.pop(req_id, None)

    try:
        while not cancelled.is_set():
            raw = sys.stdin.buffer.readline(MAX_REQUEST + 1)
            if not raw:
                break
            if len(raw) > MAX_REQUEST or not raw.endswith(b'\n'):
                emit('session_error', id=None, message='Sitzungsnachricht zu groß oder unvollständig.')
                continue
            line = raw.decode('utf-8', 'replace').strip()
            if not line or line == 'abbrechen':
                break
            try:
                req = json.loads(line)
            except ValueError:
                continue
            cmd = req.get('cmd')
            if cmd == 'quit':
                break
            if cmd == 'cancel':
                cancel_turns(req.get('id'))
                continue
            if cmd in ('converse', 'turn'):
                # Ensure at most one active speaking turn per session (prevents parallel turn pile-ups)
                cancel_turns(None)
            threading.Thread(target=run_cmd, args=(req,), daemon=True).start()
    finally:
        cancel_turns(None)


def serve_phone(request):
    action, origin = request.get('action', 'status'), clean_origin(request)
    if action == 'status':
        give_result(phone_state())
    elif action == 'start':
        threading.Thread(target=watch_connection, daemon=True).start()
        phone_start(origin)
        give_result(phone_state())
    elif action == 'stop':
        phone_stop()
        give_result(phone_state())
    elif action == 'warmup':
        phone_warmup(request)
    elif action == 'listen':
        phone_listen(request)
    elif action == 'turn':
        phone_turn(request, origin)
    elif action == 'converse':
        phone_converse(request, origin)
    elif action == 'session':
        phone_session(origin)
    else:
        raise ValueError('Unbekannte Telefon-Aktion (status, start, stop, warmup, listen, turn, converse, session).')


SYNC_FORBIDDEN_TOP = {'.ssh', '.local', '.config', '.cache', '.gnupg', '.pki', '.netrc', '.bashrc', '.profile',
                      '.bash_profile', '.zshrc', '.zprofile', '.bash_logout', '.env'}
SYNC_SKIP_DIRS = {'.git', '__pycache__', 'node_modules', '.venv', 'venv'}
SYNC_MAX_MANIFEST_FILES = 10000
SYNC_MAX_FILE_BYTES = 100 * 1024 * 1024


def sync_target_dir(raw):
    """A writable project directory inside bigki's home (never home itself, never sensitive dotfiles)."""
    if not isinstance(raw, str) or not raw.strip():
        raise ValueError('Zielordner (dest) auf bigki fehlt.')
    home = Path.home().resolve()
    text = raw.strip()
    if text.startswith('bigki:'):
        text = text[6:]
    candidate = Path(os.path.expanduser(text))
    if not candidate.is_absolute():
        candidate = home / candidate
    target = candidate.resolve()
    if target == home or home not in target.parents:
        raise ValueError(f'Sync-Ziel muss ein Unterordner im Home-Verzeichnis von bigki sein ({home}).')
    rel = target.relative_to(home)
    if not rel.parts or rel.parts[0] in SYNC_FORBIDDEN_TOP or rel.parts[0].startswith('.'):
        raise ValueError(f'Sync-Ziel „{rel.parts[0]}“ ist auf bigki geschützt.')
    return target


def sync_rel_path(target, raw_rel):
    if not isinstance(raw_rel, str) or not raw_rel or raw_rel.startswith('/') or '\\' in raw_rel:
        raise ValueError(f'Ungültiger relativer Dateipfad: {raw_rel!r}')
    parts = Path(raw_rel).parts
    if not parts or any(p in ('', '.', '..', '.git') for p in parts):
        raise ValueError(f'Ungültiger relativer Dateipfad: {raw_rel!r}')
    full = (target / Path(*parts)).resolve()
    if target not in full.parents:
        raise ValueError(f'Pfad liegt außerhalb des Sync-Ziels: {raw_rel!r}')
    return full, '/'.join(parts)


def file_sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as handle:
        while True:
            chunk = handle.read(256 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def serve_sync(request):
    action = request.get('action')
    target = sync_target_dir(request.get('dest'))
    if action == 'manifest':
        files = {}
        truncated = False
        if target.is_dir():
            for root, dirs, names in os.walk(target):
                dirs[:] = sorted(d for d in dirs if d not in SYNC_SKIP_DIRS)
                for name in sorted(names):
                    if len(files) >= SYNC_MAX_MANIFEST_FILES:
                        truncated = True
                        break
                    path = Path(root) / name
                    if path.is_symlink() or not path.is_file():
                        continue
                    rel = path.relative_to(target).as_posix()
                    try:
                        size = path.stat().st_size
                        digest = file_sha256(path) if size <= SYNC_MAX_FILE_BYTES else None
                        files[rel] = {'size': size, 'sha256': digest}
                    except OSError:
                        pass
                if truncated:
                    break
        emit('result', result={'ok': True, 'dest': str(target), 'exists': target.is_dir(),
                               'files': files, 'truncated': truncated})
        return
    if action == 'put':
        items = request.get('files') or []
        delete_list = request.get('delete') or []
        if not isinstance(items, list) or not isinstance(delete_list, list):
            raise ValueError('files/delete müssen Listen sein.')
        target.mkdir(parents=True, exist_ok=True, mode=0o700)
        written = []
        total_bytes = 0
        for item in items:
            if not isinstance(item, dict):
                raise ValueError('Ungültiger Dateieintrag.')
            full, rel = sync_rel_path(target, item.get('path'))
            encoded = item.get('data')
            expected_sha = item.get('sha256')
            if not isinstance(encoded, str):
                raise ValueError(f'Daten fehlen für {rel}.')
            raw = base64.b64decode(encoded, validate=True)
            if len(raw) > SYNC_MAX_FILE_BYTES:
                raise ValueError(f'{rel} ist größer als {SYNC_MAX_FILE_BYTES // (1024 * 1024)} MB.')
            actual_sha = hashlib.sha256(raw).hexdigest()
            if expected_sha and actual_sha != expected_sha:
                raise ValueError(f'Prüfsummenfehler bei {rel}.')
            full.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            temp = full.with_name(f'.{full.name}.{uuid.uuid4().hex[:6]}.tmp')
            try:
                temp.write_bytes(raw)
                if item.get('executable'):
                    temp.chmod(0o700)
                else:
                    temp.chmod(0o600)
                os.replace(temp, full)
            finally:
                if temp.exists():
                    try:
                        temp.unlink()
                    except OSError:
                        pass
            written.append(rel)
            total_bytes += len(raw)
        deleted = []
        for raw_rel in delete_list:
            full, rel = sync_rel_path(target, raw_rel)
            if full.is_file() and not full.is_symlink():
                full.unlink()
                deleted.append(rel)
        emit('result', result={'ok': True, 'dest': str(target), 'written': written, 'deleted': deleted, 'bytes': total_bytes})
        return
    raise ValueError('Unbekannte Sync-Aktion (manifest, put).')


def serve():
    line = sys.stdin.buffer.readline(MAX_REQUEST + 1)
    if len(line) > MAX_REQUEST or not line.endswith(b'\n'):
        raise ValueError('Die übermittelten Bilder sind zu groß oder unvollständig.')
    request = json.loads(line)
    operation = request.get('operation')
    if operation == 'ping':
        available = all((ROOT / item).is_file() for item in ('generate.py', 'decode_latents.py', 'project_colors.py', '.venv/bin/python'))
        emit('ready', available=available, images=SD_CLI.is_file(), music=(MUSIC / 'build-hip906' / 'mm-synth').is_file(),
             broker=BROKER.is_file(), video=(VIDEO / 'src' / 'build-hip' / 'bin' / 'sd-cli').is_file(),
             blender=BLENDER_RUN.is_file() and SESSION_SCRIPT.is_file(),
             llm=STRATA_PROFILE.is_file() and STRATA_START.is_file(),
             speech=AUDIO_SERVER.is_file() and (DRAMA3_GGUF.is_file() or find_qwen3_tts_model() is not None),
             phone=AUDIO_SERVER.is_file() and NEMOTRON_GGUF.is_file() and STRATA_PHONE_CFG.is_file())
    elif operation == 'machine':
        machine_status()
    elif operation == 'h3':
        serve_h3(request)
    elif operation == 'music':
        serve_music(request)
    elif operation == 'music_examples':
        music_examples()
    elif operation == 'generate':
        serve_3d(request, line)
    elif operation == 'video':
        serve_video(request)
    elif operation == 'blender':
        serve_blender(request)
    elif operation == 'sync':
        serve_sync(request)
    elif operation == 'figur':
        serve_figur(request)
    elif operation == 'llm':
        serve_llm(request)
    elif operation == 'speech':
        serve_speech(request)
    elif operation == 'phone':
        serve_phone(request)
    else:
        raise ValueError('Unbekannter Auftrag.')


if __name__ == '__main__':
    if sys.argv[1:] == ['--llm-idle-watch']:
        llm_idle_watch()
        sys.exit(0)
    if sys.argv[1:] == ['--speech-idle-watch']:
        speech_idle_watch()
        sys.exit(0)
    if sys.argv[1:] == ['--phone-idle-watch']:
        phone_idle_watch()
        sys.exit(0)
    signal.signal(signal.SIGTERM, lambda *_: stop_running())
    try:
        serve()
    except BrokenPipeError:
        stop_running()
        sys.exit(1)
    except Exception as error:
        try:
            emit('error', message=str(error))
        except BrokenPipeError:
            pass
        sys.exit(1)
