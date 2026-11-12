import Foundation
import XCTest
@testable import KongVox

final class UpdaterTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateLogic.isNewer("0.13.1", than: "0.13.0"))
        XCTAssertTrue(UpdateLogic.isNewer("v0.14", than: "0.13.9"))
        XCTAssertTrue(UpdateLogic.isNewer("1.0", than: "0.99.99"))
        XCTAssertTrue(UpdateLogic.isNewer("0.13.0.1", than: "0.13"))
        XCTAssertFalse(UpdateLogic.isNewer("0.13.0", than: "0.13"))
        XCTAssertFalse(UpdateLogic.isNewer("0.9", than: "0.13"))
        XCTAssertFalse(UpdateLogic.isNewer("0.13.0", than: "0.13.1"))
        // Anything that is not dotted numbers never counts as an update, in either position.
        XCTAssertFalse(UpdateLogic.isNewer("1.0-beta", than: "0.1"))
        XCTAssertFalse(UpdateLogic.isNewer("9.9", than: "开发版"))
        XCTAssertNil(UpdateLogic.parts("1..2"))
        XCTAssertNil(UpdateLogic.parts(""))
    }
    func release(_ assets: [[String: Any]], tag: String = "v0.14.0") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tag_name": tag, "body": "说明", "html_url": "https://github.com/kongxiangruihello/KongVox/releases/tag/\(tag)", "assets": assets])
    }
    func testReleaseParsingAcceptsOnlyThisRepositorysArchive() throws {
        let base = "https://github.com/kongxiangruihello/KongVox/releases/download/v0.14.0/"
        let digest = String(repeating: "ab", count: 32)
        let parsed = try UpdateLogic.parse(release([
            ["name": "KongVox-0.14.0-Mac.dmg", "browser_download_url": base + "KongVox-0.14.0-Mac.dmg", "size": 9],
            ["name": "KongVox-0.14.0-Mac.zip", "browser_download_url": base + "KongVox-0.14.0-Mac.zip", "size": 7, "digest": "sha256:" + digest.uppercased()],
        ]))
        XCTAssertEqual(parsed.version, "0.14.0")
        XCTAssertEqual(parsed.archive.lastPathComponent, "KongVox-0.14.0-Mac.zip")
        XCTAssertEqual(parsed.sha256, digest)
        XCTAssertEqual(parsed.size, 7)
        XCTAssertEqual(parsed.notes, "说明")
        // A malformed digest is ignored rather than trusted.
        XCTAssertNil(try UpdateLogic.parse(release([["name": "a-Mac.zip", "browser_download_url": base + "a-Mac.zip", "digest": "sha256:xyz"]])).sha256)
        for bad in ["http://github.com/kongxiangruihello/KongVox/releases/download/v0.14.0/a-Mac.zip",
                    "https://example.com/kongxiangruihello/KongVox/releases/download/v0.14.0/a-Mac.zip",
                    "https://github.com/someone/else/releases/download/v0.14.0/a-Mac.zip"] {
            XCTAssertThrowsError(try UpdateLogic.parse(release([["name": "a-Mac.zip", "browser_download_url": bad]])))
        }
        XCTAssertThrowsError(try UpdateLogic.parse(release([])))
        XCTAssertThrowsError(try UpdateLogic.parse(release([["name": "a-Mac.zip", "browser_download_url": base + "a-Mac.zip"]], tag: "nightly")))
        XCTAssertThrowsError(try UpdateLogic.parse(Data("[]".utf8)))
    }
    func testDigestOfFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try UpdateLogic.sha256(of: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    /// Runs the real swap script against stand-in folders; "no-open" skips relaunching.
    func swap(in dir: URL, pid: Int32) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", UpdateLogic.swapScript, "kongvox-update", String(pid), dir.appendingPathComponent("new/KongVox.app").path, dir.appendingPathComponent("Apps/KongVox.app").path, "no-open"]
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }
    func testSwapReplacesTheAppAndKeepsItWhenTheNewCopyIsMissing() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let installed = dir.appendingPathComponent("Apps/KongVox.app"), fresh = dir.appendingPathComponent("new/KongVox.app")
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: fresh.appendingPathComponent("marker"))
        // A process that has already exited stands in for the app that just quit.
        let finished = Process(); finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run(); finished.waitUntilExit()
        XCTAssertEqual(try swap(in: dir, pid: finished.processIdentifier), 0)
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("marker"), encoding: .utf8), "new")
        XCTAssertFalse(fm.fileExists(atPath: fresh.path))
        XCTAssertFalse(fm.fileExists(atPath: installed.path + ".previous"))
        // The new copy is gone now, so a second run must leave the installed app exactly as it is.
        _ = try swap(in: dir, pid: finished.processIdentifier)
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("marker"), encoding: .utf8), "new")
        XCTAssertFalse(fm.fileExists(atPath: installed.path + ".previous"))
    }
    func testReplaceBlockers() {
        XCTAssertNotNil(UpdateLogic.replaceBlocker(URL(fileURLWithPath: "/usr/bin/true")))
        XCTAssertNotNil(UpdateLogic.replaceBlocker(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/y/KongVox.app")))
        XCTAssertNotNil(UpdateLogic.replaceBlocker(URL(fileURLWithPath: "/System/Applications/Nope.app")))
    }
}
