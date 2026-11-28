#!/usr/bin/env python3
"""StudioPortal card broker on bigki.

Hands out single MI50 cards to StudioPortal jobs strictly in the order the jobs were started.
Rules (same as the existing guard scripts, but per card instead of per machine):
- The shared MI50 lock is held only while one of our jobs computes (music also holds the paiton GPU lock).
- A card is only handed out when no foreign process uses it and its hotspot is below 92 °C
  (music below 65 °C, as in the MiniMax instructions).
- Foreign processes are never touched. If one (e.g. Blender rendering on an MI50) appears on a card,
  only our own process on that card is stopped and restarted later.
- Hotspot >= 92 °C or an unreadable sensor stops our own process on that card.
The broker starts on demand (from the worker) and exits after a few idle minutes.
"""
import errno
import fcntl
import hashlib
import json
import os
import pwd
from pathlib import Path
import select
import signal
import socket
import sys
import time

PROTOCOL = 1
VERSION = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()[:16]
BASE = Path.home() / '.local' / 'share' / '3d-modelle-app'
SOCKET = BASE / 'broker.sock'
FAKE = os.environ.get('MODELLE_FAKE_GPU') == '1'  # unit tests only; never set by the SSH forced command
if FAKE:
    LOCKS = {'mi50': Path.home() / 'mi50.lock', 'paiton': Path.home() / 'paiton.lock'}
else:
    LOCKS = {'mi50': Path('/home/bigki/mi50-phase0/mi50-experiment.lock'),
             'paiton': Path.home() / '.local' / 'share' / 'paiton' / 'gpu-coordination' / 'gpu.lock'}
HOT = 92
MUSIC_START = 65
IDLE_VRAM = 512 * 1024 * 1024
IDLE_EXIT = float(os.environ.get('MODELLE_BROKER_IDLE', '300'))
TICK = 1.0


class Hardware:
    """The three MI50: ROCm index -> KFD gpu_id, DRM card, hotspot sensor."""

    def __init__(self):
        self.cards = []
        if FAKE:
            self.cards = [{'index': i, 'gpu_id': str(i)} for i in range(3)]
            return
        nodes = []
        for node in Path('/sys/class/kfd/kfd/topology/nodes').glob('*'):
            try:
                props = dict(line.split()[:2] for line in (node / 'properties').read_text().splitlines() if line.strip())
                gpu_id = (node / 'gpu_id').read_text().strip()
            except (OSError, ValueError):
                continue
            if props.get('gfx_target_version') == '90006':
                nodes.append((int(node.name), gpu_id, int(props.get('domain', 0)), int(props['location_id'])))
        for index, (_, gpu_id, domain, location) in enumerate(sorted(nodes)):
            pci = '%04x:%02x:%02x.%x' % (domain, location >> 8, (location >> 3) & 0x1f, location & 7)
            card = {'index': index, 'gpu_id': gpu_id, 'pci': pci, 'drm': None, 'sensor': None}
            for drm in Path('/sys/class/drm').glob('card[0-9]*'):
                if '-' in drm.name:
                    continue
                try:
                    if os.path.basename(os.path.realpath(drm / 'device')) != pci:
                        continue
                except OSError:
                    continue
                card['drm'] = drm / 'device'
                for label in (drm / 'device').glob('hwmon/hwmon*/temp*_label'):
                    try:
                        if label.read_text().strip() == 'junction':
                            card['sensor'] = label.with_name(label.name.replace('_label', '_input'))
                    except OSError:
                        pass
            self.cards.append(card)

    @staticmethod
    def _int(path):
        try:
            return int(Path(path).read_text().strip())
        except (OSError, ValueError, TypeError):
            return None

    def sample(self):
        """Returns temps (°C or None), vram (bytes or None), busy (% or None), kfd {pid: set(card) or None}."""
        if FAKE:
            def read(name, default):
                path = Path.home() / name
                return path.read_text().strip() if path.exists() else default
            temps = [int(x) for x in read('fake-temps', '40,40,40').split(',')]
            foreign = {int(x) for x in read('fake-foreign', '').split(',') if x.strip()}
            kfd = {999999: foreign} if foreign else {}
            return temps, [0, 0, 0], [0, 0, 0], kfd
        temps, vram, busy = [], [], []
        for card in self.cards:
            raw = self._int(card['sensor']) if card['sensor'] else None
            temps.append(None if raw is None else raw // 1000)
            vram.append(self._int(card['drm'] / 'mem_info_vram_used') if card['drm'] else None)
            busy.append(self._int(card['drm'] / 'gpu_busy_percent') if card['drm'] else None)
        kfd = {}
        proc = Path('/sys/class/kfd/kfd/proc')
        try:
            entries = list(proc.iterdir())
        except OSError:
            entries = None
        if entries is None:
            return temps, vram, busy, {0: None}  # cannot tell: treat every card as foreign-used
        for entry in entries:
            if not entry.name.isdigit():
                continue
            used = set()
            unknown = False
            for card in self.cards:
                value = self._int(entry / ('vram_' + card['gpu_id']))
                if value is None:
                    unknown = True
                elif value > 0:
                    used.add(card['index'])
            kfd[int(entry.name)] = None if unknown and not used else used
        return temps, vram, busy, kfd


class Lock:
    def __init__(self, path):
        self.path = path
        self.handle = None

    def take(self):
        if self.handle:
            return True
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            handle = self.path.open('a')
        except OSError:
            return False
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            handle.close()
            return False
        self.handle = handle
        return True

    def drop(self):
        if self.handle:
            self.handle.close()
            self.handle = None

    def held_elsewhere(self):
        if self.handle:
            return False
        if self.take():
            self.drop()
            return False
        return True


class Client:
    def __init__(self, conn):
        self.conn = conn
        self.buffer = b''
        self.request = None  # dict while waiting/granted
        self.cards = []
        self.pgids = set()
        self.last_sent = None
        self.since = time.time()


PROGRAMS = (('strata', 'Sprachmodell (Strata)'), ('audiocpp_server', 'Sprache (Drama 3)'), ('audiocpp_cli', 'Sprache (Drama 3)'),
            ('blender', 'Blender'), ('comfyui', 'ComfyUI'), ('comfy', 'ComfyUI'), ('ollama', 'Sprachmodell (ollama)'),
            ('llama-server', 'Sprachmodell (llama.cpp)'), ('llama', 'Sprachmodell (llama.cpp)'), ('vllm', 'Sprachmodell (vLLM)'),
            ('sd-cli', 'stable-diffusion.cpp'), ('mm-synth', 'Musik (mm-synth)'), ('hunyuan', 'Hunyuan3D'), ('jupyter', 'Jupyter'))


def program_label(pid):
    """'Blender · bigki' style label from /proc: known program names, else the script/binary name, plus the user."""
    try:
        parts = [p for p in Path(f'/proc/{pid}/cmdline').read_bytes().decode(errors='replace').split('\0') if p]
        user = pwd.getpwuid(Path(f'/proc/{pid}').stat().st_uid).pw_name
    except (OSError, KeyError):
        return 'unbekanntes Programm'
    text = ' '.join(parts).lower()
    name = next((label for key, label in PROGRAMS if key in text), None)
    if not name:
        args = [p for p in parts if not p.startswith('-')]
        if args and Path(args[0]).name.startswith('python') and len(args) > 1:
            args = args[1:]
        name = Path(args[0]).name[:40] if args else 'Programm'
    return f'{name} · {user}'


def pgid_of(pid):
    try:
        return os.getpgid(pid)
    except OSError:
        return None


class Broker:
    def __init__(self):
        self.hw = Hardware()
        self.locks = {name: Lock(path) for name, path in LOCKS.items()}
        self.clients = {}
        self.dying = {}  # pgid -> SIGKILL deadline
        self.idle_since = time.time()
        self.sample = ([], [], [], {})

    # ---------- messaging
    def send(self, client, **message):
        try:
            client.conn.sendall((json.dumps(message, ensure_ascii=False) + '\n').encode())
        except OSError:
            self.drop(client)

    def drop(self, client):
        if client.conn.fileno() in self.clients:
            del self.clients[client.conn.fileno()]
        self.stop_processes(client)
        client.request = None
        client.cards = []
        try:
            client.conn.close()
        except OSError:
            pass

    def stop_processes(self, client):
        for pgid in client.pgids:
            try:
                os.killpg(pgid, signal.SIGTERM)
                self.dying[pgid] = time.time() + 6
            except ProcessLookupError:
                pass
        client.pgids = set()

    # ---------- state
    def own_pgids(self):
        result = set(self.dying)
        for client in self.clients.values():
            result |= client.pgids
        return result

    def foreign_cards(self, kfd):
        own = self.own_pgids()
        cards = set()
        for pid, used in kfd.items():
            if pgid_of(pid) in own:
                continue
            if used is None:
                return {0, 1, 2}
            cards |= used
        return cards

    def describe_foreign(self, kfd):
        own = self.own_pgids()
        result = []
        for pid, used in kfd.items():
            if pgid_of(pid) in own:
                continue
            try:
                command = Path(f'/proc/{pid}/cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')[:160]
            except OSError:
                command = '?'
            result.append(f'{pid}(pgid {pgid_of(pid)}, cards {sorted(used) if used is not None else "?"}): {command}')
        return result

    def foreign_users(self, kfd):
        """card -> short labels of the foreign programs using it, e.g. 'Blender (bigki)' – shown in the app's Rechner page."""
        own = self.own_pgids()
        result = {}
        for pid, used in kfd.items():
            if pgid_of(pid) in own:
                continue
            label = program_label(pid)
            for card in (sorted(used) if used is not None else [0, 1, 2]):
                result.setdefault(card, [])
                if label not in result[card]:
                    result[card].append(label)
        return result

    @staticmethod
    def log(text):
        print(time.strftime('%Y-%m-%d %H:%M:%S'), text, file=sys.stderr, flush=True)

    def leased(self):
        result = {}
        for client in self.clients.values():
            if client.request and client.cards:
                for card in client.cards:
                    result[card] = client
        return result

    def waiting(self):
        items = [c for c in self.clients.values() if c.request and not c.cards]
        return sorted(items, key=lambda c: (c.request['ticket'], c.since))

    def status(self):
        temps, vram, busy, kfd = self.sample
        leased = self.leased()
        foreign = self.foreign_cards(kfd) if temps else set()
        users = self.foreign_users(kfd) if temps else {}
        cards = []
        for index in range(len(self.hw.cards)):
            owner = leased.get(index)
            cards.append({'index': index, 'temp': temps[index] if index < len(temps) else None,
                          'busy': busy[index] if index < len(busy) else None,
                          'vram': vram[index] if index < len(vram) else None,
                          'job': owner.request.get('label') if owner else None,
                          'origin': owner.request.get('origin') if owner else None,
                          'foreign': index in foreign,
                          'foreign_by': users.get(index, []) if index in foreign else []})
        queue = [{'label': c.request.get('label'), 'origin': c.request.get('origin'),
                  'cards': c.request['cards'], 'reason': c.request.get('reason')} for c in self.waiting()]
        lock = 'ours' if self.locks['mi50'].handle else ('foreign' if self.locks['mi50'].held_elsewhere() else 'free')
        return {'cards': cards, 'queue': queue, 'lock': lock, 'version': VERSION}

    # ---------- the scheduler
    def tick(self):
        now = time.time()
        for pgid, deadline in list(self.dying.items()):
            try:
                os.killpg(pgid, 0)
            except ProcessLookupError:
                del self.dying[pgid]
                continue
            if now >= deadline:
                try:
                    os.killpg(pgid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self.sample = self.hw.sample()
        temps, vram, busy, kfd = self.sample
        foreign = self.foreign_cards(kfd)
        # 1. protect running leases
        for client in list(self.clients.values()):
            if not (client.request and client.cards):
                continue
            hot = [c for c in client.cards if c >= len(temps) or temps[c] is None or temps[c] >= HOT]
            taken = [c for c in client.cards if c in foreign]
            if hot or taken:
                reason = 'heat' if hot else 'foreign'
                self.log(f'stop {client.request.get("label")} on {client.cards}: {reason} temps={temps} '
                         f'foreign={self.describe_foreign(kfd)}')
                self.stop_processes(client)
                client.cards = []
                client.request = None
                self.send(client, ev='revoked', reason=reason,
                          temps=[temps[c] if c < len(temps) else None for c in hot])
        # 2. hand out free cards strictly in order
        leased = self.leased()
        waiting = self.waiting()
        if waiting:
            free = [index for index in range(len(self.hw.cards))
                    if index not in leased and index not in foreign
                    and index < len(temps) and temps[index] is not None and temps[index] < HOT
                    and (vram[index] is None or vram[index] <= IDLE_VRAM)]
            blocked = None
            for position, client in enumerate(waiting, 1):
                req = client.request
                if blocked is None:
                    limit = MUSIC_START if req.get('kind') in ('music', 'video') else HOT
                    usable = sorted((c for c in free if temps[c] < limit), key=lambda c: temps[c])
                    reason = None
                    if len(usable) < req['cards']:
                        if foreign:
                            names = sorted({name.split(' · ')[0] for card in foreign for name in self.foreign_users(kfd).get(card, []) if not name.startswith('unbekannt')})
                            reason = f'{", ".join(names) or "Ein fremder GPU-Auftrag"} nutzt die Karten und hat Vorrang.'
                        elif len(free) >= req['cards']:
                            reason = f'Die Karten kühlen noch ab (Start unter {limit} °C).'
                        else:
                            reason = 'Warte auf freie Grafikkarten.'
                    elif req.get('kind') == 'llm' and self.locks['mi50'].held_elsewhere():
                        reason = 'Ein anderer MI50-Auftrag hält die gemeinsame GPU-Sperre.'
                    elif req.get('kind') != 'llm' and not self.locks['mi50'].take():
                        reason = 'Ein anderer MI50-Auftrag hält die gemeinsame GPU-Sperre.'
                    elif req.get('kind') == 'music' and not self.locks['paiton'].take():
                        reason = 'Ein anderer Musik-/GPU-Dienst hält die GPU-Sperre.'
                    if reason is None:
                        client.cards = usable[:req['cards']]
                        for card in client.cards:
                            free.remove(card)
                        req['reason'] = None
                        self.send(client, ev='granted', cards=client.cards)
                        continue
                    blocked = position
                    req['reason'] = reason
                else:
                    req['reason'] = f'In der Warteschlange (Platz {position}).'
                key = (position, req['reason'])
                if key != client.last_sent:
                    client.last_sent = key
                    self.send(client, ev='waiting', position=position, reason=req['reason'])
        # 3. hold the shared locks only while we compute or are about to
        # an 'llm' lease only reserves the cards: Strata's own launcher takes the mi50 lock and refuses to start without it
        if not any(c.request and c.cards and c.request.get('kind') != 'llm' for c in self.clients.values()):
            self.locks['mi50'].drop()
        if not any(c.request and c.cards and c.request.get('kind') == 'music' for c in self.clients.values()):
            self.locks['paiton'].drop()
        if self.clients or self.dying:
            self.idle_since = now

    # ---------- requests
    def handle(self, client, message):
        op = message.get('op')
        if op == 'hello':
            self.send(client, ev='hello', protocol=PROTOCOL, version=VERSION)
        elif op == 'status':
            self.send(client, ev='status', **self.status())
        elif op == 'acquire':
            cards = message.get('cards')
            ticket = message.get('ticket')
            if client.request or cards not in (1, 2, 3) or not isinstance(ticket, int):
                self.send(client, ev='error', message='Ungültige Kartenanfrage.')
                return
            client.request = {'cards': cards, 'ticket': ticket, 'kind': str(message.get('kind', ''))[:20],
                              'label': str(message.get('label', ''))[:80], 'origin': str(message.get('origin', ''))[:60]}
            client.since = time.time()
            client.last_sent = None
            self.tick()
        elif op == 'run':
            pid = message.get('pid')
            pgid = pgid_of(pid) if isinstance(pid, int) else None
            if client.cards and pgid and pgid != os.getpgid(0):
                client.pgids.add(pgid)
        elif op == 'release':
            client.pgids = set()  # the worker waited for its processes itself
            client.request = None
            client.cards = []
            self.send(client, ev='released')
            self.tick()
        elif op == 'shutdown':
            if not any(c.request for c in self.clients.values() if c is not client):
                self.send(client, ev='bye')
                raise SystemExit(0)
            self.send(client, ev='busy')

    def serve(self, listener):
        listener.setblocking(False)
        last_tick = 0
        while True:
            sockets = [listener] + [c.conn for c in self.clients.values()]
            timeout = max(0.05, TICK - (time.time() - last_tick))
            readable, _, _ = select.select(sockets, [], [], timeout)
            for sock in readable:
                if sock is listener:
                    try:
                        conn, _ = listener.accept()
                    except OSError:
                        continue
                    self.clients[conn.fileno()] = Client(conn)
                    continue
                client = self.clients.get(sock.fileno())
                if client is None:
                    continue
                try:
                    data = sock.recv(65536)
                except OSError:
                    data = b''
                if not data:
                    self.drop(client)
                    continue
                client.buffer += data
                if len(client.buffer) > 1_000_000:
                    self.drop(client)
                    continue
                while b'\n' in client.buffer and client.conn.fileno() in self.clients:
                    line, client.buffer = client.buffer.split(b'\n', 1)
                    try:
                        message = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(message, dict):
                        self.handle(client, message)
            if time.time() - last_tick >= TICK:
                last_tick = time.time()
                self.tick()
                if not self.clients and not self.dying and time.time() - self.idle_since > IDLE_EXIT:
                    return


def main():
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    guard = (BASE / 'broker.lock').open('a')
    try:
        fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return  # another broker is running
    try:
        SOCKET.unlink()
    except FileNotFoundError:
        pass
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old = os.umask(0o077)
    listener.bind(str(SOCKET))
    os.umask(old)
    listener.listen(32)
    broker = Broker()
    try:
        broker.serve(listener)
    except SystemExit:
        pass
    finally:
        for client in list(broker.clients.values()):
            broker.stop_processes(client)
        try:
            if SOCKET.exists():
                SOCKET.unlink()
        except OSError:
            pass
        listener.close()


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    main()
