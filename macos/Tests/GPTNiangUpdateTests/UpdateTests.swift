import XCTest
import Foundation
import Darwin
@testable import GPTNiangUpdate

final class UpdateTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func app(_ path: URL, version: String) throws {
        try FileManager.default.createDirectory(at: path.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": UpdatePolicy.bundleID, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: path.appendingPathComponent("Contents/Info.plist"))
    }
    private func fixture() throws -> (UpdateStore, UpdateJournal) {
        let current = root.appendingPathComponent("GPTNiangMac.app")
        try app(current, version: "1.3.2")
        let store = try UpdateStore(app: current, data: root.appendingPathComponent("state"))
        let token = UUID().uuidString
        try store.createOwned(store.cache(token), token: token); try store.createOwned(store.artifact(token), token: token)
        try app(store.staged(token), version: "1.3.3")
        let archive = Data("verified native test archive".utf8)
        try archive.write(to: store.cache(token).appendingPathComponent("release.zip"))
        try Data("custom user preferences".utf8).write(to: store.data.appendingPathComponent("preferences.json"))
        let journal = UpdateJournal(token: token, app: store.app, data: store.data, version: "1.3.3", oldVersion: "1.3.2", hash: UpdatePolicy.hash(archive), parentPID: getpid())
        try store.save(journal); return (store, journal)
    }
    private func release(_ tag: String = "v1.3.3", prerelease: Bool = false, repository: String = "GPT-Niang") throws -> OfficialRelease {
        let name = "gpt-niang-usage-widget-\(tag)-macos-universal.zip"
        let assets = [name, "SHA256SUMS.txt"].map { ["name": $0, "browser_download_url": "https://github.com/Calvin-bot-ui/\(repository)/releases/download/\(tag)/\($0)", "size": 20] as [String: Any] }
        return try JSONDecoder().decode(OfficialRelease.self, from: JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": false, "prerelease": prerelease, "assets": assets]))
    }
    func testStableVersionsAndOfficialMacAsset() throws {
        XCTAssertTrue(StableVersion("999999999999999999999.0.0")! > StableVersion("2.0.0")!)
        XCTAssertNil(StableVersion("01.3.3")); XCTAssertNil(StableVersion("1.3.3-beta"))
        XCTAssertEqual(try UpdatePolicy.select(release(), current: "1.3.2")?.version, "1.3.3")
        XCTAssertNil(try UpdatePolicy.select(release(), current: "1.3.3"))
        XCTAssertNil(try UpdatePolicy.select(release(prerelease: true), current: "1.3.2"))
        XCTAssertThrowsError(try UpdatePolicy.select(release(repository: "foreign"), current: "1.3.2"))
        XCTAssertFalse(UpdatePolicy.allowed(URL(string: "https://github.com.evil.test/Calvin-bot-ui/GPT-Niang/releases/download/v1.3.3/file")!))
        XCTAssertFalse(UpdatePolicy.allowed(URL(string: "http://github.com/Calvin-bot-ui/GPT-Niang/releases/download/v1.3.3/file")!))
    }
    func testChecksumAndGitHubDigestMustAgree() throws {
        let bytes = Data("abc".utf8); let hash = UpdatePolicy.hash(bytes)
        let value = try JSONDecoder().decode(ReleaseAsset.self, from: JSONSerialization.data(withJSONObject: ["name": "release.zip", "browser_download_url": "https://github.com/file", "size": 3, "digest": "sha256:" + hash]))
        XCTAssertEqual(try UpdatePolicy.verifyArchive(bytes, checksums: Data("\(hash)  release.zip\n".utf8), asset: value), hash)
        XCTAssertThrowsError(try UpdatePolicy.verifyArchive(bytes, checksums: Data("\(hash)  other.zip\n".utf8), asset: value))
        XCTAssertThrowsError(try UpdatePolicy.verify(Data("abd".utf8), asset: value))
    }
    func testSuccessfulInstallConfirmsHealthBeforeCleanup() async throws {
        let (store, original) = try fixture(); var journal = original; var healthSawBackup = false
        try await NativeInstaller.install(store, journal: &journal, verify: { XCTAssertEqual(try NativeArchive.version(of: $0), $1) },
            launch: { _ in 123 }, health: { _, record in
                healthSawBackup = FileManager.default.fileExists(atPath: store.staged(record.token).path)
                return true
            }, stop: { _ in XCTFail("Healthy application must remain running") })
        XCTAssertTrue(healthSawBackup); XCTAssertEqual(journal.phase, .committed)
        XCTAssertEqual(try NativeArchive.version(of: store.app), "1.3.3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.artifact(journal.token).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.cache(journal.token).path))
        XCTAssertEqual(try String(contentsOf: store.data.appendingPathComponent("preferences.json")), "custom user preferences")
        XCTAssertFalse(try XCTUnwrap(store.journal()).cleanupPending)
    }
    func testFailedHealthStopsNewProcessBeforeRollback() async throws {
        let (store, original) = try fixture(); var journal = original; var stopped = false; var launches = 0
        do {
            try await NativeInstaller.install(store, journal: &journal, verify: { _, _ in }, launch: { path in
                launches += 1
                if launches == 2 { XCTAssertTrue(stopped); XCTAssertEqual(try NativeArchive.version(of: path), "1.3.2") }
                return 456
            }, health: { _, _ in false }, stop: { _ in
                XCTAssertEqual(try NativeArchive.version(of: store.app), "1.3.3"); stopped = true
            })
            XCTFail("Expected startup failure")
        } catch { XCTAssertTrue(stopped) }
        XCTAssertEqual(journal.phase, .rolledBack); XCTAssertEqual(launches, 2)
        XCTAssertEqual(try NativeArchive.version(of: store.app), "1.3.2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.artifact(journal.token).path))
    }
    func testFailedProcessTerminationPreservesRecoveryFiles() async throws {
        let (store, original) = try fixture(); var journal = original
        do {
            try await NativeInstaller.install(store, journal: &journal, verify: { _, _ in }, launch: { _ in 456 },
                health: { _, _ in false }, stop: { _ in throw UpdateFailure("Process still active") })
            XCTFail("Expected recovery failure")
        } catch { }
        XCTAssertEqual(journal.phase, .recoveryFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.artifact(journal.token).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.cache(journal.token).path))
        XCTAssertThrowsError(try store.cleanup())
    }
    func testInterruptedAtomicReplacementRecoversOnEitherSide() throws {
        for exchanged in [false, true] {
            let (store, original) = try fixture(); var journal = original
            journal.phase = .replacing; try store.save(journal)
            if exchanged { try NativeInstaller.exchange(store.app, store.staged(journal.token)) }
            try NativeInstaller.restore(store, journal: &journal); try store.cleanup()
            XCTAssertEqual(try NativeArchive.version(of: store.app), "1.3.2")
            XCTAssertEqual(journal.phase, .rolledBack)
            try FileManager.default.removeItem(at: store.app); try FileManager.default.removeItem(at: store.data)
        }
    }
    func testChangedArchiveNeverReplacesApp() async throws {
        let (store, original) = try fixture(); var journal = original
        try Data("tampered".utf8).write(to: store.cache(journal.token).appendingPathComponent("release.zip"))
        do {
            try await NativeInstaller.install(store, journal: &journal, verify: { _, _ in }, launch: { _ in XCTFail("Must not launch"); return 1 }, health: { _, _ in true }, stop: { _ in })
            XCTFail("Expected digest rejection")
        } catch { }
        XCTAssertEqual(try NativeArchive.version(of: store.app), "1.3.2")
    }
    func testCleanupRejectsForeignOwnershipAndSymlinks() throws {
        let (store, original) = try fixture(); var journal = original
        journal.phase = .rolledBack; try store.save(journal)
        let outside = root.appendingPathComponent("user.txt"); try Data("keep".utf8).write(to: outside)
        let link = store.artifact(journal.token).appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try store.cleanup()); XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        try FileManager.default.removeItem(at: link)
        try Data("foreign marker".utf8).write(to: store.artifact(journal.token).appendingPathComponent("owner.json"))
        XCTAssertThrowsError(try store.cleanup())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.artifact(journal.token).path))
    }
    func testCleanupFailureKeepsCommittedVersionAndRetries() async throws {
        let (store, original) = try fixture(); var journal = original
        let outside = root.appendingPathComponent("user.txt"); try Data("keep".utf8).write(to: outside)
        let link = store.artifact(journal.token).appendingPathComponent("link")
        try await NativeInstaller.install(store, journal: &journal, verify: { _, _ in }, launch: { _ in 123 }, health: { _, _ in
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside); return true
        }, stop: { _ in XCTFail("Must not roll back after commit") })
        XCTAssertEqual(journal.phase, .committed); XCTAssertTrue(try XCTUnwrap(store.journal()).cleanupPending)
        XCTAssertEqual(try NativeArchive.version(of: store.app), "1.3.3")
        try FileManager.default.removeItem(at: link); try store.cleanup()
        XCTAssertFalse(try XCTUnwrap(store.journal()).cleanupPending)
    }
    func testOrphanCleanupPreservesUnownedFolders() throws {
        let (store, original) = try fixture(); var journal = original
        journal.phase = .rolledBack; try store.save(journal)
        let orphan = UUID().uuidString; try store.createOwned(store.cache(orphan), token: orphan)
        let foreign = store.cache(UUID().uuidString); try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        try store.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.cache(orphan).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }
    func testConcurrentUpdateLockIsExclusive() throws {
        let (store, _) = try fixture(); let lock = try UpdateLock(at: store.data)
        try withExtendedLifetime(lock) { XCTAssertThrowsError(try UpdateLock(at: store.data)) }
    }
    private func zip(_ names: [String], mode: Int = 0x8000) -> Data {
        var local = Data(), directory = Data()
        func put(_ data: inout Data, _ value: Int, _ length: Int) { for index in 0..<length { data.append(UInt8((value >> (index * 8)) & 255)) } }
        for name in names {
            let bytes = Data(name.utf8); let offset = local.count
            for (value, size) in [(0x04034b50,4),(20,2),(0,2),(0,2),(0,2),(0,2),(0,4),(0,4),(0,4),(bytes.count,2),(0,2)] { put(&local, value, size) }
            local.append(bytes)
            for (value, size) in [(0x02014b50,4),(0x0314,2),(20,2),(0,2),(0,2),(0,2),(0,2),(0,4),(0,4),(0,4),(bytes.count,2),(0,2),(0,2),(0,2),(0,2),(mode << 16,4),(offset,4)] { put(&directory, value, size) }
            directory.append(bytes)
        }
        var result = local; result.append(directory)
        for (value, size) in [(0x06054b50,4),(0,2),(0,2),(names.count,2),(names.count,2),(directory.count,4),(local.count,4),(0,2)] { put(&result, value, size) }
        return result
    }
    func testArchiveRejectsTraversalLinksDuplicatesAndTruncation() throws {
        XCTAssertNoThrow(try NativeArchive.inspect(zip(["GPTNiangMac.app/Contents/Info.plist"])))
        XCTAssertThrowsError(try NativeArchive.inspect(zip(["GPTNiangMac.app/../user.txt"])))
        XCTAssertThrowsError(try NativeArchive.inspect(zip(["GPTNiangMac.app/link"], mode: 0xa000)))
        XCTAssertThrowsError(try NativeArchive.inspect(zip(["GPTNiangMac.app/A", "GPTNiangMac.app/a"])))
        XCTAssertThrowsError(try NativeArchive.inspect(zip(["GPTNiangMac.app/A"]).dropLast()))
    }
}
