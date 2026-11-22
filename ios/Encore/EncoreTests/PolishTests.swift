import XCTest
@testable import Encore

/// Stream ios-polish: links in and out, the library album line, the playlist mosaic, the picker's core calls.
final class PolishTests: XCTestCase {
    func testWebLinksMapToScreens() {
        XCTAssertEqual(LinkTarget.parse("https://music.youtube.com/watch?v=4D7u5KF7SP8&si=x"), .song("4D7u5KF7SP8"))
        XCTAssertEqual(LinkTarget.parse("https://youtu.be/4D7u5KF7SP8"), .song("4D7u5KF7SP8"))
        XCTAssertEqual(LinkTarget.parse("youtu.be/abc"), .song("abc"))
        XCTAssertEqual(LinkTarget.parse("https://www.youtube.com/watch?v=abc"), .song("abc"))
        XCTAssertEqual(LinkTarget.parse("https://music.youtube.com/browse/MPREb_K8qWMWVqXGi"), .album("MPREb_K8qWMWVqXGi"))
        XCTAssertEqual(LinkTarget.parse("https://music.youtube.com/playlist?list=OLAK5uy_abc"), .album("OLAK5uy_abc"))
        XCTAssertEqual(LinkTarget.parse("https://music.youtube.com/playlist?list=PL123"), .playlist("VLPL123"))
        XCTAssertEqual(LinkTarget.parse("https://music.youtube.com/browse/VLPL123"), .playlist("VLPL123"))
        XCTAssertEqual(LinkTarget.parse("https://music.youtube.com/channel/UCRr1xG_2WIDs18a6cIiCxeA"), .artist("UCRr1xG_2WIDs18a6cIiCxeA"))
        XCTAssertEqual(LinkTarget.parse("https://open.spotify.com/playlist/37i9"), .spotify("https://open.spotify.com/playlist/37i9"))
        XCTAssertNil(LinkTarget.parse("https://example.com/watch?v=x"))
        XCTAssertNil(LinkTarget.parse("https://music.youtube.com/"))
    }

    func testSharedLinksOpenWhatWasShared() {
        let album = BrowseItem(kind: .album, id: "MPREb_K8qWMWVqXGi", title: "RAM")
        XCTAssertEqual(LinkTarget.parse(ShareLinks.item(album).web!.absoluteString), .album(album.id))
        XCTAssertEqual(ShareLinks.item(album).app.absoluteString, "chladni://album/MPREb_K8qWMWVqXGi")
        let pl = BrowseItem(kind: .playlist, id: "VLPL123", title: "Mix")
        XCTAssertEqual(LinkTarget.parse(ShareLinks.item(pl).web!.absoluteString), .playlist("VLPL123"))
        let artist = BrowseItem(kind: .artist, id: "UCx", title: "A")
        XCTAssertEqual(LinkTarget.parse(ShareLinks.item(artist).web!.absoluteString), .artist("UCx"))
        let song = SongItem(videoId: "4D7u5KF7SP8", title: "Get Lucky", artists: "Daft Punk")
        XCTAssertEqual(LinkTarget.parse(ShareLinks.song(song).web!.absoluteString), .song(song.videoId))
        XCTAssertEqual(ShareLinks.song(song).app.absoluteString, "chladni://song/4D7u5KF7SP8")
        // Own playlists only open on this phone: no web link.
        XCTAssertNil(ShareLinks.item(BrowseItem(kind: .playlist, id: "LOCALPLAYLIST:3", title: "Mine")).web)
    }

    func testAlbumLibraryLine() {
        XCTAssertEqual(albumSubtitle("Album • Daft Punk • 2001"), "Album • Daft Punk")
        XCTAssertEqual(albumSubtitle("Single • Dua Lipa • 2020"), "Single • Dua Lipa")
        XCTAssertEqual(albumSubtitle("Daft Punk"), "Album • Daft Punk")
        XCTAssertEqual(albumSubtitle(nil), "Album")
    }

    func testMosaicNeedsFourDifferentAlbums() {
        func s(_ id: String, _ album: String) -> SongItem {
            var x = SongItem(videoId: id, title: id, artists: "", thumbnail: "https://x/\(album).jpg"); x.albumId = album; return x
        }
        XCTAssertNil(MosaicCover.covers([s("1", "a"), s("2", "a"), s("3", "b"), s("4", "c")]))
        XCTAssertEqual(MosaicCover.covers([s("1", "a"), s("2", "a"), s("3", "b"), s("4", "c"), s("5", "d")])?.count, 4)
    }

    func testPickerCoreCallsOnMock() async throws {
        let core = MockCoreClient()
        let lists = try await core.librarySnapshot().playlists
        let song = try await core.getPlaylist(id: lists[0].id).items[0]
        let before = try await core.playlistsContaining(videoId: song.videoId)
        XCTAssertTrue(before.contains(lists[0].id))
        try await core.removeFromPlaylist(id: lists[0].id, videoIds: [song.videoId])
        let after = try await core.playlistsContaining(videoId: song.videoId)
        XCTAssertFalse(after.contains(lists[0].id))
        try await core.addToPlaylist(id: lists[0].id, songs: [song])
        let again = try await core.playlistsContaining(videoId: song.videoId)
        XCTAssertTrue(again.contains(lists[0].id))
    }
}
