"""Exercise the folder tool through MCP, including subdirectory confinement."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class PhotoFolder(unittest.TestCase):
    def test_folder_scope(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            folder = base / "input"
            folder.mkdir()
            (folder / "status.psd").write_bytes(b"x" * 5)
            os.utime(folder / "status.psd", (1_700_000_000, 1_700_000_000))  # 14.11.2023
            (folder / "sub").mkdir()
            (folder / "sub" / "deep.png").touch()
            (folder / ".private.png").touch()
            (folder / "notes.txt").touch()
            (folder / "outside").symlink_to(base)
            helper = Path(__file__).resolve().parents[1] / "src/web-search.mjs"
            queries = [dict(directory="."), dict(directory=".", recursive=True), dict(directory=".."), dict(directory="outside")]
            requests = [json.dumps(dict(jsonrpc="2.0", id=i, method="tools/call",
                            params=dict(name="list_documents", arguments=q)))
                        for i, q in enumerate(queries)]
            result = subprocess.run(["node", str(helper), "files", os.fspath(folder)],
                                    input="\n".join(requests), capture_output=True, text=True, check=True)
            replies = [json.loads(line)["result"] for line in result.stdout.splitlines()]
            flat, deep = (json.loads(reply["content"][0]["text"])["entries"] for reply in replies[:2])
            self.assertEqual([e["path"] for e in flat], ["status.psd", "sub/"])
            self.assertEqual([e["path"] for e in deep], ["status.psd", "sub/", "sub/deep.png"])
            self.assertTrue(flat[0]["modified"].startswith("2023-11-1"))  # Ortszeit
            self.assertRegex(flat[0]["created"], r"^\d{4}-\d\d-\d\d \d\d:\d\d$")
            self.assertEqual(flat[0]["bytes"], 5)
            folder_info = json.loads(replies[0]["content"][0]["text"])["folder"]
            self.assertEqual(folder_info["path"], "./")
            self.assertRegex(folder_info["created"], r"^\d{4}-\d\d-\d\d \d\d:\d\d$")
            self.assertIn("modified", flat[1])  # Unterordner haben ebenfalls Datum
            self.assertNotIn("bytes", flat[1])
            self.assertTrue(all(reply["isError"] for reply in replies[2:]))
            self.assertEqual(len(replies), len(queries))


if __name__ == "__main__":
    unittest.main()
