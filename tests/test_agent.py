"""Agent/CLI parameter checks: wrong input must fail with a clear message before anything reaches bigki.
Uses the built app (build/StudioPortal.app, else ~/Applications). Run: python3 -I tests/test_agent.py"""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = next(p for p in (ROOT / 'build/StudioPortal.app/Contents/MacOS/StudioPortal',
                       Path.home() / 'Applications/StudioPortal.app/Contents/MacOS/StudioPortal') if p.exists())


class AgentParameters(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(); cls.png = Path(cls.tmp.name) / 'p.png'
        cls.png.write_bytes(b'\x89PNG\r\n\x1a\n' + b'x' * 100)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def fails(self, *args, says):
        run = subprocess.run([str(CLI), *args], capture_output=True, text=True, timeout=20)
        self.assertNotEqual(run.returncode, 0, run.stdout)
        message = json.loads(run.stdout or '{}').get('error', '') + run.stderr
        self.assertIn(says, message)

    def test_video_rejects_unknown_aspect(self):
        self.fails('video', 'eine Katze', '--aspect', '7:3', says='aspect muss')

    def test_music_rejects_unknown_preset(self):
        self.fails('music', 'Pop', '--preset', 'gibtsnicht', says='preset:')

    def test_music_needs_caption(self):
        self.fails('music', says='caption fehlt')

    def test_figure_rejects_unknown_pose(self):
        self.fails('figur', '--image', str(self.png), '--pose', 'salto', says='pose:')

    def test_figure_needs_existing_image(self):
        self.fails('figur', '--image', '/nicht/da.png', says='nicht gefunden')

    def test_3d_rejects_bad_resolution(self):
        self.fails('3d', '--front', str(self.png), '--no-color', '--resolution', '500', says='resolution')

    def test_llm_chat_needs_prompt(self):
        self.fails('llm', '--action', 'chat', says='prompt oder messages fehlt')

    def test_llm_chat_rejects_bad_thinking_level(self):
        self.fails('llm', 'Hallo', '--thinking', 'ultra', says='Denkstufe')

    def test_speech_needs_text(self):
        self.fails('speech', '--action', 'speak', says='text fehlt')

    def test_sync_needs_source(self):
        self.fails('sync', says='source fehlt')

    def test_sync_rejects_missing_source(self):
        self.fails('sync', '/nicht/vorhanden/ordner', says='Quelle existiert nicht')

    def test_blender_python_rejects_missing_script(self):
        self.fails('blender', 'python', '--script', '/nicht/da/skript.py', says='gibt es auf diesem Mac nicht')


if __name__ == '__main__':
    unittest.main()
