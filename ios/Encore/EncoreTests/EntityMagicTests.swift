// Stream magic-ib: find and sort in a playlist (gap #25), the Recommended footer's data (gap #4),
// the artist discography (gap #26), Search re-tap focus (gap #31), the Home shelf request (#27),
// and the new FFI arms on the real core (offline ones; the network ones only with ENCORE_LIVE=1).
import XCTest
@testable import Encore
import EncoreCore

final class EntityMagicTests: XCTestCase {
    private func song(_ id: String, _ title: String, _ artist: String, _ album: String? = nil) -> SongItem {
        SongItem(videoId: id, title: title, artists: artist, album: album)
    }

    // MARK: sort + find

    func testSortOrders() {
        let items = [song("a", "beta", "Zed", "Mid"), song("b", "Alpha", "yan", "end"), song("c", "gamma", "Abe", "Art"), song("d", "alpha", "Bo", nil)]
        XCTAssertEqual(PlaylistViewSort.custom.apply(items).map(\.videoId), ["a", "b", "c", "d"])
        // Case-insensitive, stable for ties ("Alpha" before "alpha": list order).
        XCTAssertEqual(PlaylistViewSort.title.apply(items).map(\.videoId), ["b", "d", "a", "c"])
        XCTAssertEqual(PlaylistViewSort.artist.apply(items).map(\.videoId), ["c", "d", "b", "a"])
        XCTAssertEqual(PlaylistViewSort.album.apply(items).map(\.videoId), ["d", "c", "b", "a"])
        // Recently added: newest first; equal times fall back to the list read backwards.
        XCTAssertEqual(PlaylistViewSort.recentlyAdded.apply(items, addedAt: ["a": 5, "b": 9, "c": 1, "d": 9]).map(\.videoId), ["d", "b", "a", "c"])
        XCTAssertEqual(PlaylistViewSort.recentlyAdded.apply(items).map(\.videoId), ["d", "c", "b", "a"])
        XCTAssertEqual(PlaylistViewSort.options(liked: true).first, .recentlyAdded)
        XCTAssertFalse(PlaylistViewSort.options(liked: true).contains(.custom))
        XCTAssertEqual(PlaylistViewSort.recentlyAdded.server, "newest")
    }

    func testSortIsRememberedPerPlaylist() {
        let d = UserDefaults(suiteName: "magic-ib-tests")!
        PlaylistViewSort.store(.artist, for: "P1", defaults: d)
        XCTAssertEqual(PlaylistViewSort.stored(for: "P1", defaults: d), .artist)
        XCTAssertNil(PlaylistViewSort.stored(for: "P2", defaults: d))
        PlaylistViewSort.store(nil, for: "P1", defaults: d)
        XCTAssertNil(PlaylistViewSort.stored(for: "P1", defaults: d))
    }

    func testFindMatchesTitleArtistAlbum() {
        let s = song("x", "Harder, Better", "Daft Punk", "Discovery")
        XCTAssertTrue(matchSong(s, ""))
        XCTAssertTrue(matchSong(s, "  "))
        XCTAssertTrue(matchSong(s, "harder"))
        XCTAssertTrue(matchSong(s, "DAFT"))
        XCTAssertTrue(matchSong(s, "disc"))
        XCTAssertFalse(matchSong(s, "radiohead"))
        XCTAssertTrue(matchSong(song("y", "Café", "Él"), "cafe"))
    }

    // MARK: discography

    private func card(_ id: String, _ sub: String) -> BrowseItem { BrowseItem(kind: .album, id: id, title: id, subtitle: sub) }

    // The rules (types, compilations, Popular releases, lines) are the core's:
    // `crates/core/src/discography.rs` tests. Here: the Swift side reaches them.

    func testDiscographyComesFromTheCore() {
        let d = Discography.build(albums: [card("old", "1997"), card("mid", "2005"), card("comp", "Compilation • 2010")],
                                  singles: [card("new", "Single • 2026"), card("s2", "Single • 2001")], topSongs: [])
        XCTAssertEqual(d.album.map(\.id), ["mid", "old"])
        XCTAssertEqual(d.compilation.map(\.id), ["comp"])
        XCTAssertEqual(d.all.map(\.id), ["new", "comp", "mid", "s2", "old"])
        XCTAssertEqual(d.all.first?.line, "2026 • Single")
        XCTAssertEqual(d.filters, [.popular, .albums, .singles, .compilations])
        XCTAssertEqual(Discography.build(albums: [card("a", "2000")], singles: [], topSongs: []).filters, [.popular, .albums])
    }

    func testMockDiscographyComesFromTheArtistShelves() async throws {
        let core = MockCoreClient(bundle: Bundle(for: AppModel.self))
        let d = try await core.artistDiscography(id: "UCRr1xG_2WIDs18a6cIiCxeA")
        XCTAssertEqual(d.artistName, "Daft Punk")
        XCTAssertFalse(d.album.isEmpty)
        XCTAssertFalse(d.single.isEmpty)
    }

    // MARK: recommended (mock)

    func testMockRecommendationsSkipThePlaylistAndRefreshMoves() async throws {
        let core = MockCoreClient(bundle: Bundle(for: AppModel.self))
        let page = try await core.getPlaylist(id: "LOCALPLAYLIST:8")
        let have = Set(page.items.map(\.videoId))
        let first = try await core.playlistRecommendations(playlistId: "LOCALPLAYLIST:8", n: 10, refresh: 0)
        XCTAssertEqual(first.count, 10)
        XCTAssertTrue(first.allSatisfy { !have.contains($0.song.videoId) })
        let next = try await core.playlistRecommendations(playlistId: "LOCALPLAYLIST:8", n: 10, refresh: 1)
        XCTAssertNotEqual(first.map(\.song.videoId), next.map(\.song.videoId))
        // Adding one: it is in the playlist now, so it is not recommended again.
        try await core.addToPlaylist(id: "LOCALPLAYLIST:8", songs: [first[0].song])
        let again = try await core.playlistRecommendations(playlistId: "LOCALPLAYLIST:8", n: 10, refresh: 0)
        XCTAssertFalse(again.contains { $0.song.videoId == first[0].song.videoId })
        do { try await core.setPlaylistSort(playlistId: "LOCALPLAYLIST:8", sort: "title"); XCTFail("a local playlist has no YouTube order") } catch {}
    }

    func testMockD1Commands() async throws {
        let core = MockCoreClient(bundle: Bundle(for: AppModel.self))
        let s = core.pool[3]
        let r = try await core.radioTracks(kind: "song", id: s.videoId, name: s.title)
        XCTAssertEqual(r.title, "\(s.title) Radio")
        XCTAssertEqual(r.items.first?.videoId, s.videoId)
        XCTAssertEqual(r.items.count, min(50, core.pool.count))
        let credits = try await core.songCredits(s)
        XCTAssertFalse(credits.sections.isEmpty)
        try await core.tasteSetExcluded(id: "P", kind: "playlist", title: nil, videoIds: [], excluded: true)
        let excluded = try await core.tasteExcluded()
        XCTAssertEqual(excluded, ["P"])
    }

    // MARK: router

    @MainActor func testSearchRetapAtRootFocusesTheField() {
        let r = Router()
        r.select(.search)
        XCTAssertFalse(r.searchFocused, "switching to Search doesn't focus")
        r.select(.search)
        XCTAssertTrue(r.searchFocused, "re-tapping Search at its root focuses the field")
        r.searchFocused = false
        r.push(.artist("A"))
        r.select(.search)
        XCTAssertEqual(r.paths[.search], [], "with a page pushed, the re-tap pops to root first")
        XCTAssertFalse(r.searchFocused)
        r.select(.home); r.select(.home)
        XCTAssertFalse(r.searchFocused)
    }

    @MainActor func testEntityDeepLinks() {
        let app = AppModel(core: MockCoreClient(bundle: Bundle(for: AppModel.self)))
        let r = app.router
        r.handle(URL(string: "chladni://playlist/LOCALPLAYLIST:1?find=daft&sort=title")!, app: app)
        XCTAssertEqual(r.playlistFind, PlaylistFindRequest(id: "LOCALPLAYLIST:1", query: "daft", sort: .title))
        XCTAssertEqual(r.paths[r.tab]?.last, .playlist("LOCALPLAYLIST:1"))
        r.handle(URL(string: "chladni://discography/UC123?filter=singles")!, app: app)
        XCTAssertEqual(r.discography, DiscographyRequest(artistId: "UC123", filter: .singles))
        XCTAssertEqual(r.paths[r.tab]?.last, .artist("UC123"))
        r.handle(URL(string: "chladni://shelf/recently_played?title=Recents")!, app: app)
        XCTAssertEqual(r.tab, .home)
        XCTAssertEqual(r.paths[.home], [.shelf("recently_played", "Recents")])
        r.handle(URL(string: "chladni://playlist/LOCALPLAYLIST:2")!, app: app)
        XCTAssertEqual(r.playlistFind?.id, "LOCALPLAYLIST:1", "a plain playlist link asks for nothing")
    }

    // MARK: real core (the FFI arms)

    private func realCore() throws -> RealCoreClient {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("magic-ib-\(UUID())")
        let data = base.appendingPathComponent("data"), cache = base.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return try RealCoreClient(config: CoreConfig(dataDir: data.path, cacheDir: cache.path, exportDir: base.path),
                                  secrets: KeychainStore(service: "app.encore.ios.test"))
    }

    /// Offline: the arms exist, take api.ts's argument names, and answer what the models decode.
    func testRealCoreEntityArms() async throws {
        let core = try realCore()
        let pl = try await core.createPlaylist(name: "Magic")
        // An empty playlist has nothing to seed recommendations with (no network asked).
        let recs = try await core.playlistRecommendations(playlistId: pl.id, n: 10, refresh: 0)
        XCTAssertEqual(recs, [])
        // A playlist on this phone has no YouTube order to write: the core says so.
        do {
            try await core.setPlaylistSort(playlistId: pl.id, sort: "title")
            XCTFail("set_playlist_sort on a local playlist must fail")
        } catch let e as CoreFailure {
            XCTAssertFalse(e.message.contains("unknown command"), e.message)
        }
        let page = try await core.getPlaylist(id: pl.id, sort: "title", desc: false)
        XCTAssertEqual(page.items.count, 0)
        let s = SongItem(videoId: "dQw4w9WgXcQ", title: "T", artists: "A", explicit: true)
        let flags = try await core.playableFlags([s])
        XCTAssertEqual(flags["dQw4w9WgXcQ"], true)
        try await core.setHidden(s, hidden: true)
        let hidden = try await core.playableFlags([s])
        XCTAssertEqual(hidden["dQw4w9WgXcQ"], false, "a hidden song may not play")
        // Lane D1's arms: taste exclusion round-trips; credits of a local song are empty (no network).
        try await core.tasteSetExcluded(id: pl.id, kind: "playlist", title: "Magic", videoIds: ["dQw4w9WgXcQ"], excluded: true)
        let ex1 = try await core.tasteExcluded()
        XCTAssertEqual(ex1, [pl.id])
        try await core.tasteSetExcluded(id: pl.id, kind: "playlist", title: nil, videoIds: [], excluded: false)
        let ex2 = try await core.tasteExcluded()
        XCTAssertEqual(ex2, [])
        let credits = try await core.songCredits(SongItem(videoId: "LOCAL:/tmp/x.mp3", title: "x", artists: "y"))
        XCTAssertEqual(credits.sections, [])
        let local = try await core.smartHomeLocal()
        XCTAssertTrue(local.allSatisfy { $0.source == "local" })
        let explicit = try await core.call("explicit_flags", ["items": [s]], as: [String: Bool].self)
        XCTAssertEqual(explicit["dQw4w9WgXcQ"], true)
    }

    /// Live: recommendations for a real playlist, and a real artist's full discography.
    func testRealCoreLive() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ENCORE_LIVE"] == "1", "live test: set TEST_RUNNER_ENCORE_LIVE=1")
        let core = try realCore()
        let songs = try await core.search(query: "Daft Punk One More Time")
        let pl = try await core.createPlaylist(name: "Magic live")
        try await core.addToPlaylist(id: pl.id, songs: Array(songs.prefix(3)))
        let recs = try await core.playlistRecommendations(playlistId: pl.id, n: 10, refresh: 0)
        XCTAssertFalse(recs.isEmpty)
        let radio = try await core.radioTracks(kind: "song", id: songs[0].videoId, name: songs[0].title)
        XCTAssertFalse(radio.items.isEmpty)
        _ = try await core.songCredits(songs[0])
        let d = try await core.artistDiscography(id: "UCRr1xG_2WIDs18a6cIiCxeA")
        XCTAssertGreaterThan(d.all.count, 0)
    }
}

// MARK: snapshots

final class EntityMagicSnapshotTests: SnapshotCase {
    func testPlaylistFindOpen() async {
        await snap("encore://playlist/LOCALPLAYLIST:1?find=")
    }

    func testPlaylistFindQuery() async {
        await snap("encore://playlist/LOCALPLAYLIST:1?find=one")
    }

    func testPlaylistFindNoMatch() async {
        await snap("encore://playlist/LOCALPLAYLIST:1?find=zzzz")
    }

    func testPlaylistSortedByTitle() async {
        await snap("encore://playlist/LOCALPLAYLIST:1?sort=title")
    }

    func testDiscographyPage() async {
        await snap("encore://discography/UCRr1xG_2WIDs18a6cIiCxeA", wait: 1.5)
    }

    func testDiscographyPageSingles() async {
        await snap("encore://discography/UCRr1xG_2WIDs18a6cIiCxeA?filter=singles", wait: 1.5)
    }
}
