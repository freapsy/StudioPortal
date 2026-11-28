import XCTest
@testable import H3_Studio

final class CoreTests: XCTestCase {
    // Runs the same base64 decode loop the remote wrapper uses, locally in bash.
    func testPromptSurvivesEncoding() throws {
        let prompts = ["Ein \"Fuchs\" mit 'Hut' für $HOME & `id`", "Zeile 1\nZeile 2\n", "  Leerzeichen  ", "Grüße 😀 <Picture 1> \\n x", ""]
        let decode = #"args=(); while [ "$#" -gt 0 ]; do value="$(printf '%s' "$1" | base64 -d; printf x)" || exit 2; args+=("${value%x}"); shift; done; printf '%s\0' "${args[@]}""#
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", decode, "_"] + encodedArguments(prompts)
        process.standardOutput = pipe
        try process.run(); process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let decoded = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        XCTAssertEqual(decoded, prompts)
    }

    func testArguments() throws {
        var s = Settings(); s.prompt = "Katze"; s.seed = 42; s.count = 2
        XCTAssertEqual(try s.arguments(remoteReferences: []), ["Katze", "-W", "1024", "-H", "1024", "--seed", "42", "--batch-count", "2", "--cfg-scale", "1.0", "--sampling-method", "euler", "--rng", "cpu"])
        s.mode = "Bearbeiten"; s.steps = 8; s.scheduler = "karras"; s.flashAttention = false; s.extra = "-n 'unscharf, grau'"
        let args = try s.arguments(remoteReferences: ["/a.png", "/b.png"])
        XCTAssertEqual(Array(args.suffix(12)), ["--steps", "8", "--scheduler", "karras", "--flash-attn", "off", "-r", "/a.png", "-r", "/b.png", "-n", "unscharf, grau"])
        XCTAssertThrowsError(try s.arguments(remoteReferences: []))
        s.extra = "-o /tmp/x.png"; XCTAssertThrowsError(try s.arguments(remoteReferences: ["/a.png"]))
        s.extra = "--output=/x"; XCTAssertThrowsError(try s.arguments(remoteReferences: ["/a.png"]))
        s.extra = "'offen"; XCTAssertThrowsError(try s.arguments(remoteReferences: ["/a.png"]))
        var size = Settings(); size.width = 1000; size.height = 33; size.normalizeSize()
        XCTAssertEqual([size.width, size.height], [1024, 64])
    }

    func testParserOnRealLogs() throws {
        let folder = URL(fileURLWithPath: "/Volumes/stori/Mac/instin-tmp/h3-image")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: folder.path), "Stori not mounted")
        var parser = LogParser(), sawStep = false, sawVAETiles = false
        let text = try String(contentsOf: folder.appendingPathComponent("edit1.log"), encoding: .utf8)
        for line in text.components(separatedBy: CharacterSet(charactersIn: "\r\n")) {
            parser.consume(line)
            if parser.phase == "Rechnen", parser.total == 6 { sawStep = true }
            if parser.phase == "VAE", parser.total == 49 { sawVAETiles = true }
        }
        XCTAssertTrue(sawStep); XCTAssertTrue(sawVAETiles)
        XCTAssertEqual(parser.names, ["/home/bigki/h3-image/out/edit1.png"])
        XCTAssertEqual(parser.seeds.count, 1)
        XCTAssertNil(parser.message)
    }

    func testParserMessages() {
        let cases = ["Blender is active; wait and retry": "Blender", "GPU lock busy": "belegt", "/sys/class/drm/card1 is in use; wait": "belegt",
                     "Stopping inference: unsafe hotspot at x (93000)": "92 °C", "Cannot verify all three MI50 temperature sensors": "Temperaturen",
                     "H3STUDIO_PID=4711": ""]
        for (line, expected) in cases {
            var p = LogParser(); p.consume(line)
            if expected.isEmpty { XCTAssertEqual(p.pid, 4711); XCTAssertNil(p.message) }
            else { XCTAssertTrue(p.message?.contains(expected) == true, line) }
        }
    }

    func testUniqueNameIsSafe() {
        let name = uniqueName()
        XCTAssertNotNil(match(name, #"^h3-\d{8}-\d{6}-[0-9a-f-]{36}$"#, 0))
        XCTAssertNotEqual(name, uniqueName())
    }
}
