"""Aufräumen alter PhotoCraft-Arbeitsstände im gemeinsamen Ergebnisordner (src/Checkpoints.swift), ohne App."""
import os
import pathlib
import subprocess
import tempfile
import time
import unittest

SRC = pathlib.Path(__file__).resolve().parent.parent / 'src'
CHECK = r'''
import Foundation
@main struct Check { static func main() {
    let folder = URL(fileURLWithPath: CommandLine.arguments[1])
    let trashed = Checkpoints.trashOld(in: folder, keep: folder.appendingPathComponent(".studioportal-stand-mein.psd"))
    print(trashed.sorted().joined(separator: ","))
} }
'''


class CheckpointTests(unittest.TestCase):
    def test_only_old_foreign_checkpoints_go(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = pathlib.Path(tmp, 'PhotoCraft-Ergebnisse')
            folder.mkdir()
            old = time.time() - 8 * 86_400
            for name in ('.studioportal-stand-alt.psd', '.studioportal-stand-mein.psd', 'Rechnung.psd', '.studioportal-stand-alt.txt'):
                (folder / name).write_bytes(b'x')
                os.utime(folder / name, (old, old))
            (folder / '.studioportal-stand-neu.psd').write_bytes(b'x')
            (folder / '.studioportal-stand-link.psd').symlink_to(folder / 'Rechnung.psd')
            main, binary = pathlib.Path(tmp, 'check.swift'), pathlib.Path(tmp, 'check')
            main.write_text(CHECK)
            subprocess.run(['swiftc', '-Onone', '-parse-as-library', '-o', str(binary), str(main), str(SRC / 'Checkpoints.swift')],
                           check=True, capture_output=True, timeout=300)
            out = subprocess.run([str(binary), str(folder)], capture_output=True, text=True, timeout=30).stdout.strip()
            self.assertEqual(out, '.studioportal-stand-alt.psd')
            self.assertEqual(sorted(p.name for p in folder.iterdir()),
                             ['.studioportal-stand-alt.txt', '.studioportal-stand-link.psd', '.studioportal-stand-mein.psd',
                              '.studioportal-stand-neu.psd', 'Rechnung.psd'])


if __name__ == '__main__':
    unittest.main()
