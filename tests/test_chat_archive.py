"""Check that existing chats open and new chats preserve the Pi setting."""
import pathlib
import subprocess
import tempfile
import unittest


SOURCE = pathlib.Path(__file__).resolve().parents[1] / "src/ChatArchive.swift"
CHECK = r"""
import Foundation

struct ChatMessage: Codable { let role: String; let text: String }
enum ThinkingEffort: String, Codable { case medium }

@main struct Check {
    static func main() throws {
        let legacy = SavedLLMChat(id: UUID(), savedAt: .now, messages: [],
                                  photoCraftEnabled: true, photoCraftEffort: .medium,
                                  documentName: nil, sourceFolder: nil, snapshot: UUID())
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let data = try encoder.encode(legacy)
        let legacyFields = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(legacyFields["piEnabled"] == nil)
        let restoredLegacy = try decoder.decode(SavedLLMChat.self, from: data)
        precondition(restoredLegacy.photoCraftEnabled && restoredLegacy.piEnabled == nil)
        var coding = legacy
        coding.piEnabled = true
        let restoredCoding = try decoder.decode(SavedLLMChat.self, from: encoder.encode(coding))
        precondition(restoredCoding.piEnabled == true)
    }
}
"""


class ChatArchiveTests(unittest.TestCase):
    def test_pi_setting_is_backward_compatible(self):
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "main.swift"
            source.write_text(CHECK)
            binary = source.with_suffix("")
            subprocess.run(
                ["swiftc", "-parse-as-library", "-o", str(binary), str(source), str(SOURCE)],
                check=True, timeout=120,
            )
            subprocess.run([str(binary)], check=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
