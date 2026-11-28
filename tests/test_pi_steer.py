"""Pi-Verhalten, auf das StudioPortal beim Steuern und Stoppen baut (echtes Pi, Modell durch einen lokalen Fake ersetzt):
- `steer` während eines Auftrags: Pi liest die Nachricht vor dem nächsten Modellaufruf und macht weiter (eine zusätzliche
  Nutzer-`message_end`), nur ein `agent_settled` am Ende.
- `abort`: `agent_settled` mit aborted, die Sitzung bleibt und kennt beim nächsten Auftrag den bisherigen Verlauf.
- `compact` (/compact) fasst den Verlauf zusammen; der nächste Auftrag sieht die Zusammenfassung statt der alten Nachrichten.
- Modus „Fragen“ (src/pi-permissions.mjs): ein `rm` per bash löst eine Rückfrage aus; erlaubt läuft er, abgelehnt nicht.
- `steer` nach dem Ende bleibt liegen; `clear_queue` gibt ihn zurück (StudioPortal schickt ihn dann als neuen Auftrag).
Läuft ohne Strata. Übersprungen, wenn Pi fehlt."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PI = Path.home() / ".local/bin/pi"
REQUESTS = []


def chunk(delta, finish=None):
    return {"id": "x", "object": "chat.completion.chunk", "model": "fake",
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}


class Model(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        REQUESTS.append(body)
        users = [m for m in body["messages"] if m["role"] == "user"]
        last = json.dumps(users[-1]["content"], ensure_ascii=False) if users else ""
        tool_results = sum(m["role"] == "tool" for m in body["messages"])
        if "langsam" in last:
            time.sleep(4)
        if "LÖSCHE:" in last and tool_results == 0:
            target = last.split("LÖSCHE:")[1].split('"')[0].strip()
            parts = [chunk({"role": "assistant", "tool_calls": [{"index": 0, "id": "r1", "type": "function",
                     "function": {"name": "bash", "arguments": json.dumps({"command": f"rm {target}"})}}]}), chunk({}, "tool_calls")]
        elif "Auftrag" in last and "langsam" not in last and tool_results == 0:
            time.sleep(1.5)  # Zeit für die Zwischennachricht, während das Modell „arbeitet“
            parts = [chunk({"role": "assistant", "tool_calls": [{"index": 0, "id": "c1", "type": "function",
                     "function": {"name": "ls", "arguments": json.dumps({"path": "."})}}]}), chunk({}, "tool_calls")]
        else:
            parts = [chunk({"role": "assistant", "content": "gelesen: " + ("ja" if "Zwischen" in last else "nein")}), chunk({}, "stop")]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for part in parts:
            self.wfile.write(f"data: {json.dumps(part)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")


@unittest.skipUnless(PI.exists() and Path("/opt/homebrew/bin/node").exists(), "Pi fehlt")
class PiSteer(unittest.TestCase):
    extra = []

    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.home = tempfile.mkdtemp()
        model = {"id": "fake", "name": "fake", "contextWindow": 32000, "maxTokens": 1000, "input": ["text"]}
        Path(self.home, "models.json").write_text(json.dumps({"providers": {"fake": {
            "baseUrl": f"http://127.0.0.1:{self.server.server_port}/v1", "api": "openai-completions",
            "apiKey": "x", "models": [model], "compat": {"supportsDeveloperRole": False}}}}))
        Path(self.home, "settings.json").write_text(json.dumps({"defaultProvider": "fake", "defaultModel": "fake",
            "compaction": {"enabled": True, "reserveTokens": 100, "keepRecentTokens": 10}}))  # klein, damit compact etwas zu tun hat
        self.pi = subprocess.Popen([str(PI), "--mode", "rpc", "--no-session", "--no-extensions", "--no-context-files",
                                    "--no-skills", "--no-prompt-templates", "--no-themes", "--provider", "fake",
                                    "--model", "fake", "--tools", "ls,bash"] + self.extra,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                                   cwd=self.home, env={**os.environ, "HOME": self.home, "PI_CODING_AGENT_DIR": self.home,
                                        "PATH": "/opt/homebrew/bin:/usr/bin:/bin"})  # wie in der App: Homebrew-Node
        REQUESTS.clear()

    def tearDown(self):
        self.pi.kill()
        self.server.shutdown()
        shutil.rmtree(self.home, ignore_errors=True)

    def send(self, **command):
        self.pi.stdin.write(json.dumps(command) + "\n")
        self.pi.stdin.flush()

    def until_settled(self):
        events = []
        while True:
            line = self.pi.stdout.readline()
            self.assertTrue(line, "Pi hat sich beendet")
            event = json.loads(line)
            events.append(event)
            if event.get("type") == "agent_settled":
                return events

    @staticmethod
    def users(events):
        return sum(e.get("type") == "message_end" and e["message"]["role"] == "user" for e in events)

    def test_steer_is_read_and_work_continues(self):
        self.send(type="prompt", id="p", message="Auftrag: Ordner ansehen")
        for _ in range(100):  # erst senden, wenn der erste Modellaufruf läuft (sonst liest Pi sie schon davor)
            if REQUESTS:
                break
            time.sleep(0.05)
        self.send(type="steer", id="s", message="Zwischennachricht: nimm nur PSDs")
        events = self.until_settled()
        self.assertEqual(self.users(events), 2)                    # Auftrag + gelesene Zwischennachricht
        self.assertTrue(any(e.get("type") == "tool_execution_start" for e in events))
        self.assertIn("Zwischennachricht", json.dumps(REQUESTS[-1]["messages"], ensure_ascii=False))
        texts = [b.get("text") for e in events if e.get("type") == "message_end" and e["message"]["role"] == "assistant"
                 for b in e["message"]["content"] if b.get("type") == "text"]
        self.assertEqual(texts[-1], "gelesen: ja")

    def test_abort_keeps_history_and_late_steer_comes_back(self):
        self.send(type="prompt", id="p", message="langsam arbeiten")
        time.sleep(1)
        self.send(type="abort", id="a")
        events = self.until_settled()
        self.assertTrue(events[-1].get("aborted"))
        self.send(type="steer", id="steer", message="zu spät")   # Pi ist fertig: bleibt liegen
        while not (event := json.loads(self.pi.stdout.readline())).get("id") == "steer":
            pass  # wie StudioPortal: Bestätigung abwarten, Pi bearbeitet Befehle nebenläufig
        self.send(type="clear_queue", id="c")
        while not (event := json.loads(self.pi.stdout.readline())).get("id") == "c":
            pass
        cleared = event["data"]["steering"]
        self.assertEqual(cleared, ["zu spät"])
        self.send(type="prompt", id="p2", message="weiter")
        self.until_settled()
        history = json.dumps(REQUESTS[-1]["messages"], ensure_ascii=False)
        self.assertIn("langsam arbeiten", history)
        self.assertNotIn("zu spät", history)

    def test_compact_now(self):
        self.send(type="prompt", id="p", message="erste Frage mit Geheimwort Kolibri")
        self.until_settled()
        self.send(type="prompt", id="p1", message="zweite Frage")  # Pi behält mindestens die letzte Runde wörtlich
        self.until_settled()
        self.send(type="compact", id="k", customInstructions="Dateinamen behalten")
        while not (event := json.loads(self.pi.stdout.readline())).get("id") == "k":
            pass
        self.assertTrue(event["success"], event)
        self.send(type="prompt", id="p2", message="weiter")
        self.until_settled()
        history = json.dumps(REQUESTS[-1]["messages"], ensure_ascii=False)
        self.assertNotIn("Geheimwort Kolibri", history)  # alte Nachricht durch die Zusammenfassung ersetzt


@unittest.skipUnless(PI.exists() and Path("/opt/homebrew/bin/node").exists(), "Pi fehlt")
class PiAsk(PiSteer):
    extra = ["-e", str(Path(__file__).resolve().parents[1] / "src/pi-permissions.mjs")]

    def ask_delete(self, allow, instead=None):
        target = Path(self.home, "weg.txt")
        target.write_text("x")
        self.send(type="prompt", id="p", message=f"LÖSCHE:{target}")
        asked = None
        while True:
            event = json.loads(self.pi.stdout.readline())
            if event.get("type") == "extension_ui_request" and event.get("method") == "confirm":
                asked = event
                self.send(type="extension_ui_response", id=event["id"], confirmed=allow)
            if event.get("type") == "extension_ui_request" and event.get("method") == "input":
                self.assertFalse(allow)  # nur nach einem Nein fragt Pi „Was stattdessen?“
                self.send(type="extension_ui_response", id=event["id"], **({"value": instead} if instead else {"cancelled": True}))
            if event.get("type") == "agent_settled":
                break
        self.assertIsNotNone(asked)
        self.assertIn("rm ", asked["message"])
        return target.exists()

    def test_allowed_delete_runs(self):
        self.assertFalse(self.ask_delete(True))

    def test_declined_delete_is_blocked(self):
        self.assertTrue(self.ask_delete(False))

    def test_declined_with_instead_reaches_the_model(self):
        self.assertTrue(self.ask_delete(False, instead="verschiebe sie nach Archiv/"))
        self.assertIn("verschiebe sie nach Archiv/", json.dumps(REQUESTS[-1]["messages"], ensure_ascii=False))

    # Die Grundtests laufen in PiSteer; hier nur die Rückfragen.
    test_steer_is_read_and_work_continues = test_abort_keeps_history_and_late_steer_comes_back = test_compact_now = None


if __name__ == "__main__":
    unittest.main()
