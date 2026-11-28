"""Freigabe-Regeln im Modus „Fragen“ (src/CommandRules.swift): welche Programme ein Befehl braucht, ohne App, ohne GPU."""
import pathlib
import subprocess
import tempfile
import unittest

SRC = pathlib.Path(__file__).resolve().parent.parent / 'src'
CHECK = r'''
import Foundation
@main struct Check { static func main() {
    func k(_ command: String) -> [String]? { CommandRules.keys(title: "Befehl ausführen?", detail: command) }
    precondition(k("mv a.psd b/") == ["mv"])
    precondition(k("mkdir -p Kunden && mv a.psd Kunden/ && mv b.psd Kunden/") == ["mkdir", "mv"])
    precondition(k("LC_ALL=C mv a b") == ["mv"], "Variablen vor dem Befehl")
    precondition(k("/bin/rm -f x") == ["rm"])
    precondition(k("ls 2>/dev/null; mv a b 2>&1") == ["ls", "mv"], "harmlose Umleitungen")
    precondition(k("echo hi > notiz.md") == ["echo", ">"], "Umleitung in Datei ist eine eigene Regel")
    precondition(k("ls $(rm x)") == nil && k("ls `rm x`") == nil, "Ersetzungen nie per Regel")
    precondition(k("find . -name x | xargs rm") == nil && k("sh -c 'rm x'") == nil, "Wrapper nie per Regel")
    precondition(CommandRules.keys(title: "Datei ändern?", detail: "/x/a.md") == [CommandRules.files])
    precondition(CommandRules.allowed(["mkdir", "mv"], by: ["mv", "mkdir", "rm"]))
    precondition(!CommandRules.allowed(["mkdir", "mv"], by: ["mv"]), "alle Teile müssen frei sein")
    precondition(!CommandRules.allowed(nil, by: ["mv"]) && !CommandRules.allowed([], by: ["mv"]))
    precondition(CommandRules.label(["mv", ">"]) == "mv, Umleitung >" && CommandRules.label([CommandRules.files]) == "Dateiänderungen")
    print("ok")
} }
'''


class CommandRulesTests(unittest.TestCase):
    def test_rules(self):
        with tempfile.TemporaryDirectory() as tmp:
            main = pathlib.Path(tmp) / 'check.swift'
            main.write_text(CHECK)
            binary = pathlib.Path(tmp) / 'check'
            subprocess.run(['swiftc', '-Onone', '-parse-as-library', '-o', str(binary), str(main), str(SRC / 'CommandRules.swift')],
                           check=True, capture_output=True, timeout=300)
            self.assertEqual(subprocess.run([str(binary)], capture_output=True, text=True, timeout=30).stdout.strip(), 'ok')


if __name__ == '__main__':
    unittest.main()
