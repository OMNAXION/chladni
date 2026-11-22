// Stream magic-ib (I-B2): every SYNC-GAPS bridge method on the real core (offline: no network
// needed for any of these) and on the mock, so lanes P1–P3 can build on either.
import XCTest
@testable import Encore
import EncoreCore

final class SyncBridgeTests: XCTestCase {
    private func realCore() throws -> RealCoreClient {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sync-bridge-\(UUID())")
        let data = base.appendingPathComponent("data"), cache = base.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return try RealCoreClient(config: CoreConfig(dataDir: data.path, cacheDir: cache.path, exportDir: base.path),
                                  secrets: KeychainStore(service: "app.encore.ios.test"))
    }

    /// Runs the same checks on either client.
    private func exercise(_ core: CoreClient, file: StaticString = #filePath, line: UInt = #line) async throws {
        let n = try await core.restoreQueued([])
        XCTAssertEqual(n, 0, file: file, line: line)
        _ = try await core.smartTagsLiked()

        let pl = try await core.createPlaylist(name: "Bridge")
        let e0 = try await core.enhanceState(playlistId: pl.id)
        XCTAssertFalse(e0.on, file: file, line: line)
        let e1 = try await core.enhanceKeep(playlistId: pl.id, videoId: "x")
        XCTAssertEqual(e1.playlistId, pl.id, file: file, line: line)
        _ = try await core.enhanceRemove(playlistId: pl.id, videoId: "x")

        try await core.deletePlaylist(id: pl.id)
        let deleted = try await core.deletedPlaylists()
        XCTAssertTrue(deleted.contains { $0.id == pl.id }, "a deleted playlist can be recovered", file: file, line: line)
        try await core.restorePlaylist(id: pl.id)
        let after = try await core.deletedPlaylists()
        XCTAssertFalse(after.contains { $0.id == pl.id }, file: file, line: line)

        _ = try await core.recentTracks(limit: 10)
        let stats = try await core.listeningStats(since: 0)
        XCTAssertGreaterThanOrEqual(stats.plays, 0, file: file, line: line)
        _ = try await core.topArtists(limit: 5)
        try await core.clearListeningHistory()
        let cleared = try await core.recentTracks(limit: 10)
        XCTAssertEqual(cleared, [], file: file, line: line)

        let blocked = try await core.blockArtist(id: "UCbridge", name: "Bridge Band")
        XCTAssertTrue(blocked.contains { $0.key == "UCbridge" }, file: file, line: line)
        let list = try await core.blockedArtists()
        XCTAssertEqual(list.map(\.key), blocked.map(\.key), file: file, line: line)
        let unblocked = try await core.unblockArtist(key: "UCbridge")
        XCTAssertFalse(unblocked.contains { $0.key == "UCbridge" }, file: file, line: line)

        let folder = try await core.createFolder(name: "F")
        try await core.renameFolder(id: folder.id, name: "G")
        let snap = try await core.deleteFolder(id: folder.id)
        XCTAssertEqual(snap.folder.name, "G", file: file, line: line)
        let back = try await core.restoreFolder(snap)
        XCTAssertEqual(back.id, folder.id, file: file, line: line)

        let pl2 = try await core.createPlaylist(name: "Cover")
        _ = try await core.setPlaylistCover(playlistId: pl2.id, path: nil)
        let cont = try await core.playlistContinuation(id: pl2.id)
        XCTAssertNil(cont, "a local playlist is one page", file: file, line: line)
    }

    func testRealCoreBridge() async throws { try await exercise(try realCore()) }

    func testMockBridge() async throws {
        let core = MockCoreClient(bundle: Bundle(for: AppModel.self))
        try await exercise(core)
        // Mock specifics the UI lanes lean on: chips need ≥ 5 liked tracks; Enhance ≈ one per two songs.
        let chips = try await core.smartTagsLiked()
        XCTAssertFalse(chips.chips.isEmpty)
        XCTAssertTrue(chips.chips.allSatisfy { $0.videoIds.count >= 5 })
        let on = try await core.enhanceSet(playlistId: "LOCALPLAYLIST:1", on: true, len: 10)
        XCTAssertEqual(on.recs.count, 5)
        let n = try await core.restoreQueued([core.pool[0]])
        XCTAssertEqual(n, 1)
    }

    func testFolderSnapshotRoundTrips() throws {
        let json = #"{"folder":{"id":"F1","name":"A","parentId":null,"position":0,"createdAt":1,"updatedAt":2,"items":["P"]},"childFolders":[["F2",0]],"items":[["P",3]]}"#
        let snap = try JSONDecoder().decode(FolderSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.items.first?.first, "P")
        XCTAssertEqual(snap.items.first?.second, 3)
        let again = try JSONDecoder().decode(FolderSnapshot.self, from: try JSONEncoder().encode(snap))
        XCTAssertEqual(again, snap)
    }

    @MainActor func testDebugLinkOnlyInDebugBuilds() {
        let app = AppModel(core: MockCoreClient(bundle: Bundle(for: AppModel.self)))
        app.router.handle(URL(string: "chladni://debug")!, app: app)
        #if DEBUG
        XCTAssertTrue(app.router.debugOpen)
        #else
        XCTAssertFalse(app.router.debugOpen)
        #endif
    }
}
