"""Auto-Compact of the Mac LLM chat (src/ChatCompaction.swift): compiled with a stub ChatMessage, no app, no GPU."""
import pathlib
import subprocess
import tempfile
import unittest

SRC = pathlib.Path(__file__).resolve().parent.parent / 'src'
CHECK = r'''
import Foundation
struct ChatMessage { var role: String; var text: String }
@main struct Check { static func main() {
    func chat(_ n: Int, size: Int) -> [ChatMessage] {
        (0..<n).map { ChatMessage(role: $0 % 2 == 0 ? "user" : "assistant", text: "\($0)" + String(repeating: "x", count: size)) }
    }
    let options = ChatCompaction.keepOptions
    precondition(options == [20_000, 30_000, 40_000])
    precondition(options.map { ChatCompaction.retainedTokens($0, limit: 246_000) } == options)
    precondition(ChatCompaction.retainedTokens(40_000, limit: 32_000) == 10_666)
    let long = chat(161, size: 4000)
    let cuts = options.map { keep in
        ChatCompaction.plan(long, summary: nil, from: 0, before: long.count, tokensPerChar: 0.25,
                            limit: 128_000, keep: ChatCompaction.retainedTokens(keep, limit: 128_000))!.cut
    }
    precondition(cuts[0] > cuts[1] && cuts[1] > cuts[2], "larger settings keep more of the original chat")
    let small = chat(11, size: 100)
    precondition(ChatCompaction.plan(small, summary: nil, from: 0, before: 11, tokensPerChar: 0.25, limit: 1000, keep: 200) == nil, "under the limit: no compact")
    let big = chat(41, size: 1000)  // ~10k tokens at 0.25 token/char, limit 8k
    guard let plan = ChatCompaction.plan(big, summary: nil, from: 0, before: 41, tokensPerChar: 0.25, limit: 8000, keep: 2000) else { fatalError("over the limit: compact") }
    precondition(big[plan.cut].role == "user", "the kept part starts with a user message")
    precondition((41 - plan.cut) >= 7 && (41 - plan.cut) <= 9, "keeps ~2k tokens = ~8 messages, got \(41 - plan.cut)")
    let after = ChatCompaction.history(big, summary: "S", from: plan.cut, before: 41)
    precondition(after.first?["role"] == "system" && after.first?["content"]?.hasSuffix("S") == true && after.count == 41 - plan.cut + 1)
    let transcript = ((plan.request["messages"] as! [[String: String]])[1]["content"])!
    precondition(transcript.hasPrefix("Nutzer: 0") && !transcript.contains("Nutzer: \(plan.cut)x"), "summarises exactly the older part")
    let again = ChatCompaction.plan(big, summary: "S", from: plan.cut, before: 41, tokensPerChar: 0.25, limit: 8000, keep: 2000)
    precondition(again == nil, "after compacting the rest fits")
    let huge = [ChatMessage(role: "user", text: String(repeating: "x", count: 100_000))]
    precondition(ChatCompaction.plan(huge, summary: nil, from: 0, before: 1, tokensPerChar: 0.25, limit: 8000, keep: 2000) == nil, "nothing older to fold in")
    let many = chat(391, size: 1)
    precondition(ChatCompaction.plan(many, summary: nil, from: 0, before: 391, tokensPerChar: 0.25, limit: 100_000, keep: 20_000)?.cut ?? 0 > 90, "too many messages for the worker: compact")
    guard let manual = ChatCompaction.plan(small, summary: "S", from: 3, before: 11, tokensPerChar: 0.25, limit: 1000, keep: 200,
                                           force: true, focus: "Dateinamen") else { fatalError("/compact always compacts") }
    precondition(manual.cut == 11 && ChatCompaction.history(small, summary: "X", from: 11, before: 11).count == 1, "/compact folds everything")
    let manualText = (manual.request["messages"] as! [[String: String]])
    precondition(manualText[0]["content"]!.hasSuffix("Besonders wichtig: Dateinamen") && manualText[1]["content"]!.hasPrefix("Bisherige Zusammenfassung:\nS"))
    precondition(ChatCompaction.plan(small, summary: nil, from: 11, before: 11, tokensPerChar: 0.25, limit: 0, keep: 0, force: true) == nil, "nothing new: nothing to do")
    print("ok")
} }
'''


class CompactionTests(unittest.TestCase):
    def test_plan(self):
        with tempfile.TemporaryDirectory() as tmp:
            main = pathlib.Path(tmp) / 'check.swift'
            main.write_text(CHECK)
            binary = pathlib.Path(tmp) / 'check'
            subprocess.run(['swiftc', '-Onone', '-parse-as-library', '-o', str(binary), str(main), str(SRC / 'ChatCompaction.swift')],
                           check=True, capture_output=True, timeout=300)
            self.assertEqual(subprocess.run([str(binary)], capture_output=True, text=True, timeout=30).stdout.strip(), 'ok')


if __name__ == '__main__':
    unittest.main()
