"""Worker + card broker on a fake bigki (no GPUs): validation, transfers, card scheduling, safety rules."""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SRC = Path(__file__).resolve().parents[1] / 'src'
PNG = b'\x89PNG\r\n\x1a\n' + b'x' * 100
IMAGE = base64.b64encode(b'example-image').decode()

FAKE_SD = r'''
import json, os, sys, time
from pathlib import Path
home = Path.home(); args = sys.argv[1:]
out = Path(args[args.index('-o') + 1])
with (home / 'calls.jsonl').open('a') as f:
    f.write(json.dumps({'tool': 'h3', 'rocr': os.environ.get('ROCR_VISIBLE_DEVICES'), 'args': args,
                        'start': time.time()}) + '\n')
print('generating image: 1/2 - seed 42', flush=True)
sys.stdout.write('  |====| 3/6 - 1.2s/it\r  |====| 6/6 - 1.1s/it\n'); sys.stdout.flush()
if (home / 'slow').exists(): time.sleep(float((home / 'slow').read_text() or 30))
count = int(args[args.index('--batch-count') + 1]) if '--batch-count' in args else 1
for i in range(count):
    p = out if i == 0 else out.with_name(out.stem + f'_{i}.png')
    p.write_bytes(b'\x89PNG\r\n\x1a\n' + bytes([i]) * 5000)
    print(f"save result image {i} to '{p}' (success)", flush=True)
'''

FAKE_SYNTH = r'''#!/bin/bash
req="$4"; out="$6"; home="$HOME"
echo "{\"tool\":\"music\",\"card\":\"$HIP_VISIBLE_DEVICES\",\"start\":$(date +%s.%N 2>/dev/null || date +%s)}" >> "$home/calls.jsonl"
[ -f "$home/slow" ] && sleep "$(cat "$home/slow")"
echo "[Request] Parsed $req"
for i in 1 2 3; do printf '[AR] Frame %s00/300\r' "$i"; done; echo
printf '[DiT] Window 1/2: 8 steps\n[DiT] Window 2/2: 8 steps\n[VAE] Decoded: x\n'
printf 'AUDIO-%s' "$HIP_VISIBLE_DEVICES" > "$out"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["audio_codes"]="abc"; json.dump(d,open(sys.argv[2],"w"))' "$req" "${out%.*}.json"
echo "[Request] Wrote ${out%.*}.json"
'''

FAKE_GENERATE = r'''
import json, os, sys, time
from pathlib import Path
home = Path.home(); args = sys.argv[1:]
with (home / 'calls.jsonl').open('a') as f:
    f.write(json.dumps({'tool': 'shape', 'rocr': os.environ.get('ROCR_VISIBLE_DEVICES'), 'start': time.time()}) + '\n')
print('Model loaded in 1.0s', flush=True)
if (home / 'slow').exists(): time.sleep(float((home / 'slow').read_text() or 30))
out = Path(args[args.index('--save-latents') + 1])
out.write_bytes(b'latents')
(out.parent / 'sampling-args.json').write_text(json.dumps(args))
'''

FAKE_DECODE = r'''
import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
with (Path.home() / 'calls.jsonl').open('a') as f:
    f.write(json.dumps({'tool': 'decode', 'rocr': os.environ.get('ROCR_VISIBLE_DEVICES'), 'start': time.time()}) + '\n')
out = Path(args[args.index('--output') + 1])
out.write_bytes(b'glTF' + b'x' * 2048)
(out.parent / 'decode-args.json').write_text(json.dumps(args))
'''

PREPARE = '''
from pathlib import Path
import sys
job = Path(sys.argv[1]); (job / 'views').mkdir()
for src in (job / 'input').iterdir():
    (job / 'views' / (src.stem + '.png')).write_bytes(src.read_bytes())
'''


class FakeBigki(unittest.TestCase):
    def setUp(self):
        # short path: unix socket paths are limited to ~104 bytes on macOS
        self.tmp = tempfile.TemporaryDirectory(dir='/tmp')
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.addCleanup(self.stop_broker)
        h = self.home
        root = h / 'hunyuan3d-2mv'
        (root / '.venv/bin').mkdir(parents=True)
        (root / '.venv/bin/python').symlink_to(sys.executable)
        (root / 'generate.py').write_text(FAKE_GENERATE)
        (root / 'decode_latents.py').write_text(FAKE_DECODE)
        (root / 'project_colors.py').write_text('import shutil,sys\nshutil.copyfile(sys.argv[1],sys.argv[3])\n')
        sd = h / 'sdcpp-h3image/src/build-hip/bin/sd-cli'
        sd.parent.mkdir(parents=True)
        sd.write_text('#!' + sys.executable + '\n' + FAKE_SD); sd.chmod(0o755)
        (h / 'h3-image').mkdir()
        music = h / 'minimaxmusic.cpp'
        (music / 'build-hip906').mkdir(parents=True); (music / 'models').mkdir()
        synth = music / 'build-hip906/mm-synth'; synth.write_text(FAKE_SYNTH); synth.chmod(0o755)
        env = h / '.local/opt/rocm-gfx906-7.14'; env.mkdir(parents=True); (env / 'env.sh').write_text('true\n')
        examples = music / 'tools/webui/example'; examples.mkdir(parents=True)
        (examples / 'vocal-01.json').write_text(json.dumps({'caption': 'Pop', 'lyrics': '[verse]\nla', 'duration': 40}))
        self.worker = h / 'worker'
        self.worker.mkdir()
        for name in ('bigki_worker.py', 'gpu_broker.py'):
            shutil.copyfile(SRC / name, self.worker / name)
        (self.worker / 'prepare_views.py').write_text(PREPARE)

    def stop_broker(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(str(self.home / '.local/share/3d-modelle-app/broker.sock'))
            sock.sendall(b'{"op":"shutdown"}\n')
            sock.recv(100)
        except OSError:
            pass
        finally:
            sock.close()

    def set(self, name, value):
        (self.home / name).write_text(value)

    def calls(self):
        path = self.home / 'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def start(self, request):
        env = dict(os.environ, HOME=str(self.home), MODELLE_FAKE_GPU='1', MODELLE_BROKER_IDLE='5')
        proc = subprocess.Popen([sys.executable, '-u', str(self.worker / 'bigki_worker.py')], env=env,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.addCleanup(lambda: proc.poll() is None and proc.kill())
        proc.stdin.write((json.dumps(request) + '\n').encode()); proc.stdin.flush()
        return proc

    def collect(self, proc, cancel_on=None, on_event=None, timeout=20):
        events = []
        while True:
            ready, _, _ = select.select([proc.stdout], [], [], timeout)
            self.assertTrue(ready, f'worker timed out: {events[-5:]}')
            line = proc.stdout.readline()
            if not line:
                break
            events.append(json.loads(line))
            if on_event:
                on_event(events[-1])
            if cancel_on and cancel_on in json.dumps(events[-1], ensure_ascii=False):
                proc.stdin.close(); cancel_on = None
            if events[-1]['type'] in ('end', 'error', 'examples', 'machine'):
                break
        if not proc.stdin.closed:
            proc.stdin.close()
        proc.wait(timeout=20); proc.stdout.close(); proc.stderr.close()
        return proc.returncode, events

    def run_job(self, request, **kw):
        return self.collect(self.start(request), **kw)

    def files(self, events):
        out, cur = {}, None
        for e in events:
            if e['type'] == 'begin': cur = e.get('name', 'model'); out[cur] = b''
            elif e['type'] == 'data': out[cur] += base64.b64decode(e['data'])
            elif e['type'] == 'filedone': self.assertEqual(hashlib.sha256(out[e['name']]).hexdigest(), e['sha256'])
        return out

    # ---------------------------------------------------------------- requests
    def h3(self, count=2, **extra):
        value = {'operation': 'h3', 'prompt': 'ein Roboter <Picture 1>', 'count': count, 'vaeTiling': False,
                 'args': ['--seed', '42', '--batch-count', str(count)], 'references': [base64.b64encode(PNG).decode()],
                 'origin': 'MacBook · Test'}
        value.update(extra); return value

    def music(self, **extra):
        value = {'operation': 'music', 'caption': 'Pop', 'lyrics': '[verse]\nla', 'duration': 40, 'steps': 8,
                 'lm_seed': 100, 'seed': 7, 'variants': 3, 'output_format': 'mp3'}
        value.update(extra); return value

    def model(self, color=True):
        return {'operation': 'generate', 'model': 'turbo', 'resolution': 768, 'color': color, 'person': True,
                'images': {view: IMAGE for view in ('front', 'left', 'back', 'right')}}


class ImageTests(FakeBigki):
    def test_image_uses_all_three_cards_and_cleans_up(self):
        code, events = self.run_job(self.h3())
        self.assertEqual(code, 0, events)
        self.assertEqual(events[-1], {'type': 'end', 'count': 2})
        self.assertEqual(len(self.files(events)), 2)
        logs = [e['line'] for e in events if e['type'] == 'log']
        self.assertTrue(any('6/6' in l for l in logs))
        call = self.calls()[0]
        self.assertEqual(call['rocr'], '0,1,2')
        args = call['args']
        self.assertEqual(args[args.index('-p') + 1], 'ein Roboter <Picture 1>')
        self.assertIn('diffusion=ROCm0&ROCm1&ROCm2', ' '.join(args))
        self.assertNotIn('--vae-tiling', args)
        self.assertFalse(Path(args[args.index('-r') + 1]).exists(), 'reference must be cleaned up')
        self.assertEqual(list((self.home / 'h3-image/out').iterdir()), [])

    def test_rejects_output_arguments(self):
        for bad in (['-o', 'x.png'], ['--output=x.png'], ['-ox.png'], ['-r', '/etc/passwd'], ['--ref-image', 'a']):
            code, events = self.run_job(self.h3(args=['--batch-count', '2'] + bad))
            self.assertNotEqual(code, 0); self.assertIn('verwaltet', events[-1]['message'])

    def test_foreign_gpu_job_has_priority_then_image_starts_without_delay(self):
        self.set('fake-foreign', '1')
        threading.Timer(1.5, lambda: self.set('fake-foreign', '')).start()
        began = time.time()
        code, events = self.run_job(self.h3(count=1, args=['--batch-count', '1']))
        self.assertEqual(code, 0, events)
        self.assertTrue(any(e['type'] == 'waiting' and 'Vorrang' in e['message'] for e in events))
        self.assertLess(time.time() - began, 8, 'no long quiet period after the foreign job')

    def test_llm_start_keeps_all_cards_but_leaves_the_mi50_lock_to_strata(self):
        """While Strata starts no job may take a card, yet Strata's own launcher must be able to take the mi50 lock."""
        script = ("import time, bigki_worker as w\n"
                  "b = w.Broker(time.time_ns(), 'llm', 'Strata starten', 'Test')\n"
                  "print(b.acquire(3, lambda *a: None), flush=True)\ntime.sleep(3)\nb.release()\n")
        env = dict(os.environ, HOME=str(self.home), MODELLE_FAKE_GPU='1', MODELLE_BROKER_IDLE='5')
        holder = subprocess.Popen([sys.executable, '-c', script], cwd=self.worker, env=env, stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: holder.poll() is None and holder.kill())
        self.assertEqual(holder.stdout.readline().strip(), '[0, 1, 2]')
        granted = time.time()
        time.sleep(0.5)  # let the broker finish its tick
        with open(self.home / 'mi50.lock', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)  # raises if the broker kept the lock
        code, events = self.run_job(self.h3(count=1, args=['--batch-count', '1']))
        self.assertEqual(code, 0, events[-3:])
        self.assertGreater(self.calls()[0]['start'] - granted, 2.5, 'the image waited until the Strata start was over')
        holder.wait(5); holder.stdout.close()

    def test_preempted_image_restarts_automatically(self):
        self.set('slow', '2')

        def foreign(event):
            if event['type'] == 'log' and not (self.home / 'done-once').exists():
                self.set('done-once', '1')
                self.set('fake-foreign', '0')
                threading.Timer(1.5, lambda: (self.set('fake-foreign', ''), (self.home / 'slow').unlink())).start()
        code, events = self.run_job(self.h3(count=1, args=['--batch-count', '1']), on_event=foreign)
        self.assertEqual(code, 0, events)
        self.assertTrue(any('startet danach neu' in e.get('message', '') for e in events))
        self.assertEqual(len([c for c in self.calls() if c['tool'] == 'h3']), 2)

    def test_heat_stops_own_job(self):
        self.set('slow', '10')

        def heat(event):
            if event['type'] == 'log':
                self.set('fake-temps', '95,40,40')
        code, events = self.run_job(self.h3(count=1, args=['--batch-count', '1']), on_event=heat)
        self.assertNotEqual(code, 0)
        self.assertIn('92 °C', events[-1]['message'])


class MusicTests(FakeBigki):
    def test_three_variants_in_parallel_on_three_cards(self):
        self.set('slow', '1')
        code, events = self.run_job(self.music(lm_model='/etc/passwd'))
        self.assertEqual(code, 0, events)
        files = self.files(events)
        self.assertEqual(sorted(files), ['song-1.json', 'song-1.mp3', 'song-2.json', 'song-2.mp3', 'song-3.json', 'song-3.mp3'])
        self.assertEqual(sorted(files[f'song-{i}.mp3'] for i in (1, 2, 3)), [b'AUDIO-0', b'AUDIO-1', b'AUDIO-2'])
        replay = json.loads(files['song-2.json'])
        self.assertEqual((replay['lm_seed'], replay['seed'], replay['steps']), (101, 8, 8))
        self.assertNotIn('lm_model', replay)
        starts = [c['start'] for c in self.calls()]
        self.assertLess(max(starts) - min(starts), 0.9, 'variants must run at the same time')
        self.assertFalse(any((self.home / 'music3/output/studioportal').iterdir()))

    def test_replay_renders_same_song_in_full_quality(self):
        replay = {'caption': 'Pop', 'lyrics': '[verse]\nla', 'lm_seed': 5, 'seed': 6, 'steps': 8, 'audio_codes': 'xyz', 'duration': 40}
        code, events = self.run_job({'operation': 'music', 'replay': replay, 'steps': 30, 'variants': 3, 'output_format': 'wav16'})
        self.assertEqual(code, 0, events)
        files = self.files(events)
        self.assertEqual(sorted(files), ['song-1.json', 'song-1.wav'])
        used = json.loads(files['song-1.json'])
        self.assertEqual((used['steps'], used['lm_seed']), (30, 5))

    def test_three_full_renders_in_parallel(self):
        self.set('slow', '1')
        replays = [{'caption': 'Pop', 'lyrics': '[verse]', 'lm_seed': i, 'seed': i, 'steps': 8, 'audio_codes': f'c{i}'} for i in (1, 2, 3)]
        code, events = self.run_job({'operation': 'music', 'replays': replays, 'steps': 30, 'output_format': 'mp3'})
        self.assertEqual(code, 0, events)
        files = self.files(events)
        self.assertEqual([json.loads(files[f'song-{i}.json'])['lm_seed'] for i in (1, 2, 3)], [1, 2, 3])
        self.assertEqual({json.loads(files[f'song-{i}.json'])['steps'] for i in (1, 2, 3)}, {30})
        starts = [c['start'] for c in self.calls()]
        self.assertEqual(len(starts), 3)
        self.assertLess(max(starts) - min(starts), 0.9)

    def test_waits_while_cards_are_hot_and_can_cancel(self):
        self.set('fake-temps', '70,70,70')
        code, events = self.run_job(self.music(variants=1), cancel_on='kühlen')
        self.assertNotEqual(code, 0)
        self.assertIn('Abgebrochen', events[-1]['message'])

    def test_one_hot_card_does_not_stop_the_others(self):
        self.set('fake-temps', '70,40,40')
        self.set('slow', '1')
        code, events = self.run_job(self.music(variants=2))
        self.assertEqual(code, 0, events)
        self.assertEqual(sorted(c['card'] for c in self.calls()), ['1', '2'])

    def test_rejects_invalid_input(self):
        for bad in ({'caption': '', 'lyrics': 'x'}, {'caption': 'a', 'lyrics': 'b', 'duration': 999},
                    {'caption': 'a', 'lyrics': 'b', 'audio_codes': 'x'}, {'caption': 'a', 'lyrics': 'b', 'variants': 4}):
            code, events = self.run_job({'operation': 'music', **bad})
            self.assertNotEqual(code, 0); self.assertEqual(events[-1]['type'], 'error')

    def test_examples(self):
        code, events = self.run_job({'operation': 'music_examples'})
        self.assertEqual(events[-1]['items'][0]['name'], 'vocal-01')


class ModelTests(FakeBigki):
    def test_complete_colored_job_shape_on_one_card_surface_on_three(self):
        code, events = self.run_job(self.model())
        self.assertEqual(code, 0, events)
        end = events[-1]
        data = self.files(events)['model']
        self.assertEqual(hashlib.sha256(data).hexdigest(), end['sha256'])
        self.assertEqual(len(data), 2052)
        tools = {c['tool']: c['rocr'] for c in self.calls()}
        self.assertEqual(len(tools['shape'].split(',')), 1)
        self.assertEqual(tools['decode'], '0,1,2')
        self.assertFalse(Path(end['job']).exists(), 'job folder is removed after the transfer')

    def test_disconnect_stops_running_job(self):
        self.set('slow', '30')
        code, events = self.run_job(self.model(), cancel_on='KI-Modell geladen')
        self.assertNotEqual(code, 0)
        self.assertIn('Abgebrochen', events[-1]['message'])

    def test_old_jobs_are_pruned(self):
        old = self.home / 'hunyuan3d-2mv/out/app-jobs/auftrag-alt'
        old.mkdir(parents=True); (old / 'x').write_text('x'); os.utime(old, (0, 0))
        code, events = self.run_job(self.model())
        self.assertEqual(code, 0, events)
        self.assertFalse(old.exists())

    def test_color_requires_four_images(self):
        request = self.model(); del request['images']['back']
        code, events = self.run_job(request)
        self.assertIn('vier Ansichten', events[-1]['message'])


class SchedulingTests(FakeBigki):
    def test_single_card_steps_share_the_machine(self):
        """3D shape (1 card) and two song variants (1 card each) run at the same time."""
        self.set('slow', '2')
        model = self.start(self.model(color=False))
        time.sleep(0.5)
        music = self.start(self.music(variants=2))
        results = {}
        threads = [threading.Thread(target=lambda n=n, p=p: results.__setitem__(n, self.collect(p)))
                   for n, p in (('model', model), ('music', music))]
        for t in threads: t.start()
        for t in threads: t.join()
        self.assertEqual(results['model'][0], 0, results['model'][1][-3:])
        self.assertEqual(results['music'][0], 0, results['music'][1][-3:])
        calls = self.calls()
        shape = next(c for c in calls if c['tool'] == 'shape')
        songs = [c for c in calls if c['tool'] == 'music']
        self.assertEqual(len({shape['rocr']} | {c['card'] for c in songs}), 3, 'three different cards')
        self.assertLess(max(c['start'] for c in songs) - shape['start'], 1.8, 'started while the shape was computing')

    def test_queue_keeps_order(self):
        """An image (3 cards) queued behind a running song waits; a later song does not jump ahead."""
        self.set('slow', '1.5')
        first = self.start(self.music(variants=1))
        time.sleep(0.4)
        image = self.start(self.h3(count=1, args=['--batch-count', '1']))
        time.sleep(0.4)
        second = self.start(self.music(variants=1, lm_seed=5))
        out = {}
        threads = [threading.Thread(target=lambda n=n, p=p: out.__setitem__(n, self.collect(p)))
                   for n, p in (('a', first), ('image', image), ('b', second))]
        for t in threads: t.start()
        for t in threads: t.join()
        for name in out:
            self.assertEqual(out[name][0], 0, out[name][1][-3:])
        order = [c['tool'] for c in sorted(self.calls(), key=lambda c: c['start'])]
        self.assertEqual(order, ['music', 'h3', 'music'])
        self.assertTrue(any('Warteschlange' in e.get('message', '') for e in out['b'][1]))

    def test_machine_status_shows_cards_and_queue(self):
        code, events = self.run_job({'operation': 'machine'})
        self.assertEqual(code, 0, events)
        self.assertEqual(len(events[-1]['cards']), 3)
        self.assertEqual(events[-1]['cards'][0]['temp'], 40)


class LLMTests(FakeBigki):
    """Strata chat path against a fake OpenAI server: validation, streaming, speed figures (no GPUs)."""

    def setUp(self):
        super().setUp()
        import http.server
        from unittest import mock

        class Fake(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_GET(self):
                if self.path == '/metrics/prometheus':
                    self.send_response(200); self.end_headers()
                    self.wfile.write(b'llamacpp:requests_processing 0\nllamacpp:requests_deferred 1\nstrata:requests_total 7\n')
                    return
                self.send_response(200); self.end_headers(); self.wfile.write(b'{"status":"ok"}')
            def do_POST(self):
                Fake.body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
                for piece in ('Hal', 'lo'):
                    self.wfile.write(b'data: ' + json.dumps({'choices': [{'delta': {'content': piece}}]}).encode() + b'\n\n')
                self.wfile.write(b'data: ' + json.dumps({'choices': [{'delta': {}, 'finish_reason': 'stop'}],
                                 'usage': {'prompt_tokens': 5, 'completion_tokens': 2},
                                 'timings': {'predicted_per_second': 131.44}}).encode() + b'\n\ndata: [DONE]\n\n')

        self.fake = Fake
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fake)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        profile = self.home / 'llm/strata-v0.2.7-mi50/strata-orca-iq3_m-mi50.json'
        profile.parent.mkdir(parents=True)
        profile.write_text(json.dumps({'port': server.server_address[1], 'api_key': 'k', 'model_name': 'qwen-test'}))
        bin_dir = self.home / 'bin'; bin_dir.mkdir()
        # fake systemctl: "is-active" answers from a file, every call is logged
        (bin_dir / 'systemctl').write_text('#!/bin/sh\necho "$@" >> "$HOME/systemctl.log"\n'
                                           '[ "$2" = is-active ] && exit $(cat "$HOME/active" 2>/dev/null || echo 3)\nexit 0\n')
        (bin_dir / 'systemctl').chmod(0o755)
        patch = mock.patch.dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}')
        patch.start(); self.addCleanup(patch.stop)

    def chat(self, **extra):
        value = {'operation': 'llm', 'action': 'chat', 'messages': [{'role': 'user', 'content': 'Hi'}], 'start': False}
        value.update(extra); return value

    def test_status_when_stopped(self):
        code, events = self.run_job({'operation': 'llm', 'action': 'status'})
        result = next(e['result'] for e in events if e['type'] == 'result')
        self.assertEqual((result['running'], result['model']), (False, 'qwen-test'))

    def test_invalid_messages_are_rejected_before_strata(self):
        self.set('active', '0')
        for bad in ([], [{'role': 'hacker', 'content': 'x'}], 'Hi', [{'role': 'user', 'content': 3}]):
            code, events = self.run_job(self.chat(messages=bad))
            self.assertEqual(events[-1]['type'], 'error', bad)
        self.assertFalse(hasattr(self.fake, 'body'))

    def test_no_auto_start_when_start_false(self):
        code, events = self.run_job(self.chat())
        self.assertIn('Strata läuft nicht', events[-1]['message'])

    def test_strata_activity_includes_queued_external_requests(self):
        script = "import bigki_worker; print(bigki_worker.strata_activity())"
        result = subprocess.run([sys.executable, '-c', script], cwd=SRC, env={**os.environ, 'HOME': str(self.home)},
                                check=True, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.stdout.strip(), '(True, 7)')

    def test_chat_streams_tokens_and_reports_speed(self):
        self.set('active', '0')
        code, events = self.run_job(self.chat(thinking=True, max_tokens=50))
        self.assertEqual(code, 0, events)
        result = next(e['result'] for e in events if e['type'] == 'result')
        self.assertEqual(result['text'], 'Hallo')
        self.assertEqual(result['reasoning_effort'], 'medium')
        self.assertEqual(''.join(e['text'] for e in events if e['type'] == 'token'), 'Hallo')
        self.assertEqual((result['tokens_per_second'], result['completion_tokens'], result['finish_reason']), (131.4, 2, 'stop'))
        self.assertEqual(self.fake.body['reasoning_effort'], 'medium')
        self.assertEqual(self.fake.body['chat_template_kwargs'], {'enable_thinking': True, 'reasoning_effort': 'medium'})
        self.assertEqual(self.fake.body['max_tokens'], 50)

    def test_chat_reasoning_effort_levels(self):
        self.set('active', '0')
        for given, expected in (('none', 'none'), ('low', 'low'), ('medium', 'medium'), ('high', 'high'), ('hoch', 'high'), (False, 'none')):
            code, events = self.run_job(self.chat(reasoning_effort=given, max_tokens=32))
            self.assertEqual(code, 0, events)
            self.assertEqual(self.fake.body['reasoning_effort'], expected)
            if expected == 'none':
                self.assertEqual(self.fake.body['chat_template_kwargs'], {'enable_thinking': False})
            else:
                self.assertEqual(self.fake.body['chat_template_kwargs'], {'enable_thinking': True, 'reasoning_effort': expected})
        code, events = self.run_job(self.chat(reasoning_effort='ultra'))
        self.assertEqual(events[-1]['type'], 'error')
        self.assertIn('Denkstufe', events[-1]['message'])

    def test_stop_refuses_foreign_strata_without_force(self):
        self.set('active', '0')
        code, events = self.run_job({'operation': 'llm', 'action': 'stop'})
        self.assertIn('nicht von StudioPortal gestartet', events[-1]['message'])
        self.assertNotIn('stop', (self.home / 'systemctl.log').read_text())


class SpeechAndPhoneTests(FakeBigki):
    def setUp(self):
        super().setUp()
        import http.server
        from unittest import mock

        pcm_sample = b'\x01\x02' * 2205  # 50 ms @ 44.1 kHz mono int16
        pcm_b64 = base64.b64encode(pcm_sample).decode('ascii')

        class FakeAudioServer(http.server.BaseHTTPRequestHandler):
            last_speech = None
            last_task = None
            def log_message(self, *a): pass
            def do_GET(self):
                self.send_response(200); self.end_headers()
                self.wfile.write(b'{"status":"ok"}')
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                if self.path == '/v1/audio/speech':
                    FakeAudioServer.last_speech = body
                    self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
                    self.wfile.write(b'data: ' + json.dumps({'type': 'speech.audio.delta', 'audio': pcm_b64}).encode() + b'\n\n')
                    self.wfile.write(b'data: ' + json.dumps({'type': 'speech.audio.done', 'timing': {'ttft_ms': 142.5}}).encode() + b'\n\n')
                    self.wfile.write(b'data: [DONE]\n\n')
                elif self.path == '/v1/tasks/run':
                    FakeAudioServer.last_task = body
                    self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
                    if body.get('model') == 'smart-turn':
                        self.wfile.write(json.dumps({'custom_schema_output': {'data': {'complete': True, 'probability': 0.96}}}).encode())
                    else:
                        self.wfile.write(json.dumps({'text_output': 'Hotel Alpenblick, guten Tag.'}).encode())

        class FakePhoneLLM(http.server.BaseHTTPRequestHandler):
            last_body = None
            def log_message(self, *a): pass
            def do_GET(self):
                self.send_response(200); self.end_headers()
                self.wfile.write(b'{"loaded":true}')
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                FakePhoneLLM.last_body = body
                if not body.get('stream', True):
                    self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
                    self.wfile.write(json.dumps({'choices': [{'message': {'content': 'OK'}}]}).encode())
                    return
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
                for piece in ('Grüß Sie Frau Weber, ', 'hier ist Lukas. ', 'Haben Sie kurz Zeit?'):
                    self.wfile.write(b'data: ' + json.dumps({'choices': [{'delta': {'content': piece}}]}).encode() + b'\n\n')
                self.wfile.write(b'data: ' + json.dumps({
                    'choices': [{'delta': {}, 'finish_reason': 'stop'}],
                    'timings': {'predicted_per_second': 85.2, 'prompt_per_second': 112.0},
                }).encode() + b'\n\ndata: [DONE]\n\n')

        self.audio_srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakeAudioServer)
        self.cpu_srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakeAudioServer)
        self.llm_srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakePhoneLLM)
        for s in (self.audio_srv, self.cpu_srv, self.llm_srv):
            threading.Thread(target=s.serve_forever, daemon=True).start()
            self.addCleanup(s.server_close); self.addCleanup(s.shutdown)
        self.fake_audio = FakeAudioServer
        self.fake_llm = FakePhoneLLM

        # Create dummy model markers and PID files pointing to our own live PID so servers appear running
        models = self.home / 'drama3/models'
        (models / 'Drama-3-GGUF-V2').mkdir(parents=True)
        (models / 'Drama-3-GGUF-V2/drama-3-backbone-8bit-F32-routers-experts-Q4_K_S.gguf').write_bytes(b'GGUF')
        (models / 'Nemotron-3.5-ASR-Streaming-0.6B-GGUF').mkdir(parents=True)
        (models / 'Nemotron-3.5-ASR-Streaming-0.6B-GGUF/nemotron-3.5-asr-streaming-0.6b-q8_0.gguf').write_bytes(b'GGUF')
        (models / 'Smart-Turn-v3-GGUF').mkdir(parents=True)
        (models / 'Smart-Turn-v3-GGUF/smart-turn-v3.2-f32.gguf').write_bytes(b'GGUF')
        (self.home / 'drama3/audio.cpp/build-hip-gfx906/bin').mkdir(parents=True)
        srv_bin = self.home / 'drama3/audio.cpp/build-hip-gfx906/bin/audiocpp_server'
        srv_bin.write_text('#!/bin/sh\nsleep 60\n'); srv_bin.chmod(0o755)
        (self.home / 'drama3/strata-phone-2gpu.json').write_text(json.dumps({'model_name': 'qwen-phone'}))

        speech_dir = self.home / '.local/share/3d-modelle-app/speech'
        phone_dir = self.home / '.local/share/3d-modelle-app/phone'
        speech_dir.mkdir(parents=True); phone_dir.mkdir(parents=True)
        (speech_dir / 'pid').write_text(str(os.getpid()))
        (speech_dir / 'card').write_text('1')
        (phone_dir / 'cpu_pid').write_text(str(os.getpid()))
        (phone_dir / 'llm_pid').write_text(str(os.getpid()))

        env_patch = mock.patch.dict(os.environ, {
            'MODELLE_SPEECH_PORT': str(self.audio_srv.server_address[1]),
            'MODELLE_CPU_AUDIO_PORT': str(self.cpu_srv.server_address[1]),
            'MODELLE_PHONE_LLM_PORT': str(self.llm_srv.server_address[1]),
        })
        env_patch.start(); self.addCleanup(env_patch.stop)

    def test_speech_speak_streams_pcm_chunks_and_reports_ttfa(self):
        code, events = self.run_job({'operation': 'speech', 'action': 'speak', 'text': 'Grüß Sie Frau Weber!', 'seed': 42})
        self.assertEqual(code, 0, events)
        chunks = [e for e in events if e['type'] == 'audio_chunk']
        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0]['sample_rate'], 44100)
        res = next(e['result'] for e in events if e['type'] == 'result')
        self.assertEqual(res['ttfa_ms'], 142.5)
        self.assertEqual(res['engine'], 'drama-3')
        self.assertEqual(self.fake_audio.last_speech['seed'], 42)

    def test_phone_listen_runs_smart_turn_and_nemotron_asr(self):
        wav_b64 = base64.b64encode(b'RIFF0000WAVE').decode('ascii')
        code, events = self.run_job({'operation': 'phone', 'action': 'listen', 'audio_b64': wav_b64})
        self.assertEqual(code, 0, events)
        res = next(e['result'] for e in events if e['type'] == 'result')
        self.assertTrue(res['turn_complete'])
        self.assertEqual(res['text'], 'Hotel Alpenblick, guten Tag.')

    def test_phone_turn_pipelines_llm_sentences_into_streaming_tts(self):
        code, events = self.run_job({
            'operation': 'phone', 'action': 'turn', 'tts_engine': 'drama-3',
            'messages': [{'role': 'user', 'content': 'Hotel Alpenblick, guten Tag.'}],
        })
        self.assertEqual(code, 0, events)
        chunks = [e for e in events if e['type'] == 'audio_chunk']
        self.assertEqual(len(chunks), 2)  # 2 sentences pipelined into 2 TTS calls
        res = next(e['result'] for e in events if e['type'] == 'result')
        self.assertIn('Grüß Sie Frau Weber', res['text'])
        self.assertEqual(res['sentences'], 2)
        self.assertEqual(res['tokens_per_second'], 85.2)

    def test_phone_converse_single_hop_locks_voice_and_disables_reasoning(self):
        voices = self.home / 'drama3/voices'
        voices.mkdir(parents=True)
        (voices / 'laura-de.wav').write_bytes(b'RIFF0000WAVE')
        (voices / 'laura-de.txt').write_text('Grüß Sie, hier ist Laura von Studio Nordweb.\n')
        wav_b64 = base64.b64encode(b'RIFF0000WAVE').decode('ascii')
        code, events = self.run_job({
            'operation': 'phone', 'action': 'converse', 'tts_engine': 'drama-3',
            'voice_preset': 'laura', 'voice_style': '[calm, warm]',
            'audio_b64': wav_b64,
            'messages': [{'role': 'system', 'content': 'Du bist Laura.'}],
        })
        self.assertEqual(code, 0, events)
        types = [e['type'] for e in events]
        self.assertIn('transcript', types)
        self.assertLess(types.index('transcript'), types.index('token'))
        self.assertLess(types.index('transcript'), types.index('audio_chunk'))
        self.assertEqual(self.fake_llm.last_body['reasoning_effort'], 'none')
        self.assertFalse(self.fake_llm.last_body['chat_template_kwargs']['enable_thinking'])
        self.assertEqual(self.fake_audio.last_speech['voice_ref'], str(voices / 'laura-de.wav'))
        self.assertTrue(self.fake_audio.last_speech['input'].startswith('[calm, warm] '))
        self.assertEqual(
            self.fake_audio.last_speech['options']['reference_text'],
            'Grüß Sie, hier ist Laura von Studio Nordweb.',
        )
        res = next(e['result'] for e in events if e['type'] == 'result')
        self.assertTrue(res['turn_complete'])
        self.assertEqual(res['user_text'], 'Hotel Alpenblick, guten Tag.')
        self.assertIsNotNone(res['e2e_first_audio_ms'])

    def test_phone_warmup_prefills_system_prompt_with_reasoning_off(self):
        code, events = self.run_job({
            'operation': 'phone', 'action': 'warmup',
            'messages': [{'role': 'system', 'content': 'Du bist Lukas.'}],
        })
        self.assertEqual(code, 0, events)
        res = next(e['result'] for e in events if e['type'] == 'result')
        self.assertTrue(res['warmed'])
        self.assertEqual(res['warmup_reply'], 'OK')
        self.assertEqual(self.fake_llm.last_body['reasoning_effort'], 'none')
        self.assertEqual(self.fake_llm.last_body['max_tokens'], 2)

    def test_phone_session_runs_warmup_and_converse_over_single_pipe(self):
        wav_b64 = base64.b64encode(b'RIFF0000WAVE').decode('ascii')
        proc = self.start({'operation': 'phone', 'action': 'session'})
        ready = json.loads(proc.stdout.readline().decode())
        self.assertEqual(ready['type'], 'session_ready')
        self.assertTrue(ready['ready'])

        cmds = [
            {'id': 1, 'cmd': 'warmup', 'messages': [{'role': 'system', 'content': 'Du bist Lukas.'}]},
            {'id': 2, 'cmd': 'converse', 'audio_b64': wav_b64, 'tts_engine': 'drama-3',
             'messages': [{'role': 'system', 'content': 'Du bist Lukas.'}]},
            {'id': 3, 'cmd': 'llm_stream', 'messages': [{'role': 'user', 'content': 'Hallo'}]},
            {'id': 4, 'cmd': 'tts_stream', 'text': 'Grüß Sie!', 'tts_engine': 'drama-3'},
        ]
        events = []
        for cmd in cmds:
            proc.stdin.write((json.dumps(cmd) + '\n').encode())
            proc.stdin.flush()
            while True:
                ev = json.loads(proc.stdout.readline().decode())
                events.append(ev)
                if ev['type'] in ('session_result', 'session_error'):
                    break
        proc.stdin.write((json.dumps({'cmd': 'quit'}) + '\n').encode())
        proc.stdin.flush()
        proc.stdin.close()
        proc.wait(timeout=10)
        proc.stdout.close(); proc.stderr.close()
        self.assertEqual(proc.returncode, 0)
        r1 = next(e['result'] for e in events if e['type'] == 'session_result' and e['id'] == 1)
        r2 = next(e['result'] for e in events if e['type'] == 'session_result' and e['id'] == 2)
        r3 = next(e['result'] for e in events if e['type'] == 'session_result' and e['id'] == 3)
        r4 = next(e['result'] for e in events if e['type'] == 'session_result' and e['id'] == 4)
        self.assertTrue(r1['warmed'])
        self.assertEqual(r2['user_text'], 'Hotel Alpenblick, guten Tag.')
        self.assertEqual(r2['sentences'], 2)
        self.assertIn('Grüß Sie Frau Weber', r3['text'])
        self.assertEqual(r4['chunks'], 1)

    def test_german_sentence_splitter_keeps_abbreviations_intact(self):
        script = (
            "import bigki_worker as w; "
            "s1, r1 = w.pop_ready_sentence('Wir prüfen z. B. das Buchungsformular. '); "
            "s2, r2 = w.pop_ready_sentence('Das ist Dr. Weber aus München. Hallo'); "
            "print(repr((s1, r1, s2, r2)))"
        )
        out = subprocess.run([sys.executable, '-c', script], cwd=SRC, check=True, capture_output=True, text=True).stdout.strip()
        self.assertEqual(out, "('Wir prüfen z. B. das Buchungsformular.', '', 'Das ist Dr. Weber aus München.', 'Hallo')")


class SyncAndTelemetryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def run_worker(self, payload):
        env = {**os.environ, 'HOME': str(self.home)}
        run = subprocess.run([sys.executable, str(SRC / 'bigki_worker.py')],
                             input=(json.dumps(payload) + '\n').encode(),
                             capture_output=True, timeout=20, env=env)
        events = [json.loads(line) for line in run.stdout.decode().splitlines() if line.strip().startswith('{')]
        return run.returncode, events

    def test_sync_manifest_put_verify_and_delete(self):
        rc, ev = self.run_worker({'operation': 'sync', 'action': 'manifest', 'dest': '~/blender-auftraege/demo'})
        self.assertEqual(rc, 0, ev)
        res = next(e['result'] for e in ev if e['type'] == 'result')
        self.assertFalse(res['exists'])
        self.assertEqual(res['files'], {})

        data = b'print("hallo")\n'
        sha = hashlib.sha256(data).hexdigest()
        rc, ev = self.run_worker({
            'operation': 'sync', 'action': 'put', 'dest': '~/blender-auftraege/demo',
            'files': [{'path': 'skripte/a.py', 'data': base64.b64encode(data).decode('ascii'), 'sha256': sha}],
        })
        self.assertEqual(rc, 0, ev)
        put_res = next(e['result'] for e in ev if e['type'] == 'result')
        self.assertEqual(put_res['written'], ['skripte/a.py'])
        self.assertEqual((self.home / 'blender-auftraege/demo/skripte/a.py').read_bytes(), data)

        rc, ev = self.run_worker({'operation': 'sync', 'action': 'manifest', 'dest': '~/blender-auftraege/demo'})
        self.assertEqual(rc, 0, ev)
        manifest = next(e['result'] for e in ev if e['type'] == 'result')
        self.assertTrue(manifest['exists'])
        self.assertEqual(manifest['files']['skripte/a.py']['sha256'], sha)

        rc, ev = self.run_worker({
            'operation': 'sync', 'action': 'put', 'dest': '~/blender-auftraege/demo',
            'files': [], 'delete': ['skripte/a.py'],
        })
        self.assertEqual(rc, 0, ev)
        self.assertFalse((self.home / 'blender-auftraege/demo/skripte/a.py').exists())

    def test_sync_rejects_bad_checksum_and_forbidden_paths(self):
        rc, ev = self.run_worker({'operation': 'sync', 'action': 'manifest', 'dest': '~/.ssh'})
        self.assertNotEqual(rc, 0)
        self.assertTrue(any(e['type'] == 'error' and 'geschützt' in e['message'] for e in ev))

        rc, ev = self.run_worker({'operation': 'sync', 'action': 'manifest', 'dest': '/tmp/outside'})
        self.assertNotEqual(rc, 0)
        self.assertTrue(any(e['type'] == 'error' and 'Home-Verzeichnis' in e['message'] for e in ev))

        rc, ev = self.run_worker({
            'operation': 'sync', 'action': 'put', 'dest': '~/blender-auftraege/demo',
            'files': [{'path': '../escape.py', 'data': base64.b64encode(b'x').decode('ascii')}],
        })
        self.assertNotEqual(rc, 0)
        self.assertTrue(any(e['type'] == 'error' and 'Ungültiger relativer Dateipfad' in e['message'] for e in ev))

        rc, ev = self.run_worker({
            'operation': 'sync', 'action': 'put', 'dest': '~/blender-auftraege/demo',
            'files': [{'path': 'bad.py', 'data': base64.b64encode(b'hello').decode('ascii'), 'sha256': '0' * 64}],
        })
        self.assertNotEqual(rc, 0)
        self.assertTrue(any(e['type'] == 'error' and 'Prüfsummenfehler' in e['message'] for e in ev))

    def test_host_cpu_info_returns_cores(self):
        out = subprocess.run([sys.executable, '-c', 'import json, bigki_worker as w; print(json.dumps(w.host_cpu_info()))'],
                             cwd=SRC, check=True, capture_output=True, text=True).stdout
        info = json.loads(out)
        self.assertGreaterEqual(info.get('cores', 0), 1)


if __name__ == '__main__':
    unittest.main()
