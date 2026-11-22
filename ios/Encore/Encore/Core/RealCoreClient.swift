// The real core: `CoreClient` over the shared Rust core (`crates/core`) through UniFFI
// (`crates/ffi`, Swift package `ios/EncoreCore`).
//
// Every call is the desktop's own: `invoke(cmd, args)` takes the command and argument names of
// `ui/src/lib/api.ts` and answers the JSON the desktop UI gets, which the `Codable` models in
// Models*.swift decode (they mirror api.ts). Where the iOS models are shaped differently from the
// core's answer (the library snapshot, the play context), the adaptation is here and nowhere else.
// Events arrive through the UniFFI `EventListener` with the desktop's names and payloads.
import Foundation
import os
import EncoreCore

/// What the engine side of the core offers beyond `CoreClient` (PlaybackBridge, debug menu). Only
/// the real core has an audio output; the mock doesn't conform.
protocol AudioEngineControl: AnyObject {
    /// Reopen mpv's audio output (interruption end, route change, media-services reset).
    func aoReload()
    /// `audiounit` (default) or `pcm` / `null` for tests. `pcmFile`: where `ao=pcm` writes.
    func setAudioOutput(_ ao: String, pcmFile: String?)
    /// Player volume 0–100.
    func setVolume(_ volume: Int)
    /// The position right now (not the last `position` event).
    var position: Double { get }
    /// Check the loopback stream proxies, rebuilding one iOS reclaimed while suspended. Blocking
    /// (a self-connect, at most a few hundred ms): call off the main thread. True when one was dead.
    func checkProxies(_ reason: String) -> Bool
    /// Debug: close the proxy listeners the way iOS does.
    func killProxies()
    /// Debug: kill the audio proxy right after the next stream URL is handed out.
    func killProxyOnNextLoad()
    /// What the engine can do here (pitch / reverb are off on iOS's FFmpeg; stream ios-eq).
    var capabilities: AudioCaps { get }
}

/// The UI hides controls the engine can't run (`app.audioCaps`).
struct AudioCaps: Equatable {
    var pitch: Bool
    var reverb: Bool
    var speed: Bool
    var eqFlavor: String
    /// The mock, and iOS's MPVKit build: speed only.
    static let iosDefault = AudioCaps(pitch: false, reverb: false, speed: true, eqFlavor: "portable")
}

let coreLog = Logger(subsystem: "studio.chladni.ios", category: "core")

/// A core error with the core's message (`CoreError.Failed`).
struct CoreFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

final class RealCoreClient: CoreClient, AudioEngineControl, @unchecked Sendable {
    let core: EncoreCore
    private let events: Events
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Starts the core: database, transport, player (mpv opens its AO later, on the first file;
    /// the audio session must be active by then) and background services.
    init(config: CoreConfig, secrets: SecretStore?) throws {
        let ev = Events()
        events = ev
        core = try EncoreCore(config: config, listener: ev, secrets: secrets)
    }

    /// The standard iOS locations: Application Support/Encore, Caches/Encore, Documents for exports.
    static func start() throws -> RealCoreClient {
        var config = try CoreConfig.standard()
        config.exportDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
        return try RealCoreClient(config: config, secrets: KeychainStore())
    }

    /// The first screen is up: a restored queue may start (the core's `play_on_start`).
    func uiMounted() { core.uiMounted() }

    // MARK: invoke

    /// One api.ts command. `args` are its camelCase arguments (`Encodable` values or plain JSON).
    func call(_ cmd: String, _ args: [String: Any?] = [:]) async throws -> Data {
        var obj: [String: Any] = [:]
        for (k, v) in args {
            guard let v else { continue }
            obj[k] = try jsonObject(v)
        }
        let body = String(data: try JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]), encoding: .utf8) ?? "{}"
        do {
            let out = try await core.invoke(cmd: cmd, argsJson: body)
            return Data(out.utf8)
        } catch let CoreError.Failed(message) {
            coreLog.error("\(cmd, privacy: .public) failed: \(message, privacy: .public)")
            throw CoreFailure(message: message)
        }
    }

    func call<T: Decodable>(_ cmd: String, _ args: [String: Any?] = [:], as: T.Type = T.self) async throws -> T {
        let data = try await call(cmd, args)
        do { return try decoder.decode(T.self, from: data) } catch {
            coreLog.error("\(cmd, privacy: .public): undecodable answer: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func jsonObject(_ v: Any) throws -> Any {
        switch v {
        case let s as String: return s
        case let b as Bool: return b
        case let i as Int: return i
        case let d as Double: return d
        case let e as Encodable:
            return try JSONSerialization.jsonObject(with: try encoder.encode(AnyEncodable(e)), options: [.fragmentsAllowed])
        default: return v
        }
    }

    // MARK: browse / search

    func search(query: String) async throws -> [SongItem] {
        try await call("search", ["query": query, "recordHistory": false])
    }
    // stream: search2
    func searchOverview(query: String) async throws -> SearchOverview {
        try await call("search_overview", ["query": query, "recordHistory": false])
    }

    func searchLyrics(query: String) async throws -> [LyricMatch] {
        try await call("search_lyrics", ["query": query])
    }

    func searchBlendLyrics(query: String, songs: [SongItem], lyric: [LyricMatch], interacted: Bool, topTitle: String?) async throws -> LyricBlend {
        try await call("search_blend_lyrics", ["query": query, "songs": songs, "lyric": lyric, "interacted": interacted, "topTitle": topTitle])
    }

    func searchPage(query: String, filter: String, continuation: String?) async throws -> SearchPage {
        try await call("search_page", ["query": query, "filter": filter, "continuation": continuation])
    }

    func searchAll(query: String, recordHistory: Bool) async throws -> SearchResults {
        try await call("search_all", ["query": query, "recordHistory": recordHistory])
    }
    func searchSuggestions(query: String) async throws -> SearchSuggestions {
        try await call("search_suggestions", ["query": query])
    }
    func getHome(params: String?) async throws -> HomePage { try await call("get_home", ["params": params]) }
    func smartHome() async throws -> [Shelf] {
        try await call("smart_home", as: Lossy<Shelf>.self).items.map { s in
            var s = s
            s.items = s.items.map { var i = $0; i.thumbnail = Self.mfyArt(id: i.id, title: i.title, i.thumbnail); return i }
            return s
        }
    }

    /// Made for you covers are SVG files the core draws for the desktop; the app draws the same
    /// design natively (`MfyCoverArt`, `mfy:<title>#<n>`), so point those at it.
    static func mfyArt(id: String, title: String, _ thumb: String?) -> String? {
        guard id.hasPrefix("MFY_") || (thumb.map { !$0.contains("://") && $0.contains(".svg") } ?? false) else { return thumb }
        let n = Int(id.split(separator: "_").last ?? "") ?? 0
        let seed = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return mfyCoverURL(title, n + seed % 7)
    }
    func getMoods() async throws -> [MoodSection] { try await call("get_moods") }
    func getMoodArt(params: [String]) async throws -> [String: String] { try await call("get_mood_art", ["params": params]) }
    func getAlbum(id: String) async throws -> AlbumPage { try await call("get_album", ["id": id]) }
    func getArtist(id: String) async throws -> ArtistPage { try await call("get_artist", ["id": id]) }
    func getPlaylist(id: String) async throws -> PlaylistPage { try await call("get_playlist", ["id": id]) }
    func getLyrics(videoId: String, title: String, artists: String, duration: Double?) async throws -> Lyrics? {
        try await call("get_lyrics", ["videoId": videoId, "title": title, "artists": artists, "duration": duration])
    }

    // MARK: library

    /// The core's `LibrarySnapshot` (pins are rows, the private session an object); the app's is flatter.
    private struct CoreSnapshot: Decodable {
        struct Pin: Decodable { var itemId: String }
        struct Private: Decodable { var enabled: Bool }
        var likedIds: [String]
        var playlists: Lossy<LibPlaylist>
        var folders: Lossy<Folder>?
        var pins: Lossy<Pin>
        var saved: Lossy<SavedItem>
        var lastPlayed: [String: Double]
        var privateSession: Private?
        /// Hidden everywhere (the core's `hidden_ids`).
        var hiddenSongIds: [String]?
    }

    func librarySnapshot() async throws -> LibrarySnapshot {
        let s: CoreSnapshot = try await call("lib_snapshot")
        return LibrarySnapshot(likedIds: s.likedIds, playlists: s.playlists.items, saved: s.saved.items,
                               pinnedIds: s.pins.items.map(\.itemId), lastPlayed: s.lastPlayed,
                               folders: s.folders?.items, privateSession: s.privateSession?.enabled,
                               hiddenIds: s.hiddenSongIds)
    }

    func recentContexts(limit: Int) async throws -> [RecentContext] {
        try await call("lib_recent_contexts", ["limit": limit], as: Lossy<RecentContext>.self).items
    }

    func setLiked(_ song: SongItem, liked: Bool) async throws {
        if liked { _ = try await call("lib_like", ["songs": [song]]) } else { _ = try await call("lib_unlike", ["videoIds": [song.videoId]]) }
        // The desktop's `setRating`: the like is this phone's, mirrored to the YouTube account
        // best-effort. Signed out the core refuses at once (no request), so that's not logged.
        let args = "{\"videoId\":\"\(song.videoId)\",\"rating\":\"\(liked ? "like" : "indifferent")\"}"
        Task.detached { [core] in _ = try? await core.invoke(cmd: "rate", argsJson: args) }
    }

    func setSaved(_ item: BrowseItem, saved: Bool) async throws {
        if saved { _ = try await call("lib_save", ["card": item]) } else { _ = try await call("lib_unsave", ["id": item.id]) }
    }

    func createPlaylist(name: String) async throws -> LibPlaylist {
        try await call("lib_playlist_create", ["name": name])
    }

    // MARK: playback

    func getQueue() async throws -> QueueState { try await call("get_queue") }
    func getPlayback() async throws -> PlaybackSnapshot { try await call("get_playback") }

    /// The core's `PlayContext` (Recents, "PLAYING FROM", the radio after the list) for the kinds it
    /// knows; a search result list or a single song has none.
    private struct CoreContext: Encodable { var kind: String; var id: String; var title: String; var thumbnail: String? }

    func playPlaylist(items: [SongItem], start: Int, context: PlayContext, shuffle: Bool, startSecs: Double?) async throws {
        var ctx: CoreContext?
        if let id = context.id, [.playlist, .album, .artist, .liked, .radio, .dailyMix, .audiobook].contains(context.kind) {
            ctx = CoreContext(kind: context.kind.rawValue, id: id, title: context.title, thumbnail: items.first?.thumbnail)
        }
        // A Your Mix is no YouTube playlist: like the desktop's mix page, no source id (autoplay
        // would ask YouTube about `dailymix:…`); the context alone records it for Recents and Home.
        // stream: audiobooks — nor is a book.
        let sourceId = context.kind == .dailyMix || context.kind == .audiobook ? nil : context.id
        _ = try await call("play_playlist", ["items": items, "start": start, "sourceId": sourceId,
                                             "sourceName": context.title, "shuffle": shuffle, "context": ctx,
                                             "startSecs": startSecs])
    }
    func playSingle(_ song: SongItem, from: String?) async throws {
        _ = try await call("play", ["item": song, "from": from])
    }
    func hintPlay(_ song: SongItem) {
        Task.detached(priority: .utility) { [self] in _ = try? await call("hint_play", ["item": song]) }
    }
    func playIndex(_ index: Int) async throws { _ = try await call("play_index", ["index": index]) }
    func startRadio(song: SongItem) async throws {
        _ = try await call("start_radio", ["kind": "song", "id": song.videoId, "name": song.title])
    }
    func nextTrack() async throws { _ = try await call("next_track") }
    func prevTrack() async throws { _ = try await call("prev_track") }
    func togglePause() async throws { _ = try await call("toggle_pause") }
    func seek(position: Double) async throws { _ = try await call("seek", ["position": position]) }
    func toggleShuffle() async throws { _ = try await call("toggle_shuffle") }
    func setRepeat(_ mode: RepeatMode) async throws { _ = try await call("set_repeat", ["mode": mode.rawValue]) }
    func addToQueue(_ items: [SongItem], from: String?) async throws { _ = try await call("add_to_queue", ["items": items, "from": from]) }
    func playNext(_ items: [SongItem], from: String?) async throws { _ = try await call("play_next", ["items": items, "from": from]) }
    func removeFromQueue(index: Int) async throws { _ = try await call("remove_from_queue", ["index": index]) }
    func moveInQueue(from: Int, to: Int) async throws { _ = try await call("move_in_queue", ["from": from, "to": to]) }

    /// The core keeps the episode and music speeds apart and applies the playing item's own
    /// (crates/core/src/speeds.rs), so each call says which one it changes.
    func setSpeed(_ rate: Double) async throws {
        _ = try await call("set_playback_params", ["speed": rate, "target": "episode"])
    }
    func setPlaybackParams(_ e: PlaybackEffects) async throws {
        _ = try await call("set_playback_params", ["speed": e.speed, "semitones": e.semitones, "reverb": e.reverb, "target": "music"])
    }
    func seekRelative(_ seconds: Double) async throws {
        try await seek(position: max(0, core.position() + seconds))
    }

    // MARK: podcasts

    func podcastSearch(query: String) async throws -> PodcastSearchResults { try await call("podcast_search", ["query": query]) }
    func podcastShow(id: String, sort: EpisodeSort) async throws -> PodcastShowPage {
        try await call("podcast_show", ["id": id, "sort": sort.rawValue])
    }
    func podcastEpisode(id: String) async throws -> PodcastEpisode { try await call("podcast_episode", ["id": id]) }
    func podcastChapters(id: String, durationSecs: Double?) async throws -> PodcastChapters {
        try await call("podcast_chapters", ["id": id, "durationSecs": durationSecs.flatMap { $0 > 0 ? $0 : nil }])
    }
    func podcastEpisodeVideo(id: String) async throws -> EpisodeVideo? {
        try await call("podcast_episode_video", ["id": id])
    }
    func podcastFollow(_ show: PodcastShow, follow: Bool) async throws {
        if follow { _ = try await call("podcast_follow", ["show": show]) } else { _ = try await call("podcast_unfollow", ["id": show.id]) }
    }
    func podcastFollows() async throws -> [PodcastShow] { try await call("podcast_follows") }
    func podcastSavedEpisodes() async throws -> [PodcastEpisode] { try await call("podcast_saved_episodes") }
    func podcastNewEpisodes(limit: Int) async throws -> [PodcastEpisode] { try await call("podcast_new_episodes", ["limit": limit]) }
    func podcastContinueListening(limit: Int) async throws -> [PodcastEpisode] {
        try await call("podcast_continue_listening", ["limit": limit])
    }
    func podcastSaveEpisode(_ episode: PodcastEpisode, saved: Bool) async throws {
        _ = try await call("podcast_save_episode", ["episode": episode, "saved": saved])
    }
    func podcastMarkPlayed(id: String, played: Bool) async throws -> EpisodeProgress {
        try await call("podcast_mark_played", ["id": id, "played": played])
    }

    // MARK: audio

    func audioSettings() async throws -> AudioSettings { try await call("audio_settings") }
    func eqInfo() async throws -> EqInfo { try await call("audio_eq_info") }
    func setEq(enabled: Bool, gains: [Double], commit: Bool) async throws -> EqState {
        try await call("set_eq", ["enabled": enabled, "gains": gains, "commit": commit])
    }
    func setEqPreset(_ name: String) async throws -> EqState { try await call("set_eq_preset", ["name": name]) }
    func setCrossfade(seconds: Int) async throws -> Int {
        Int(try await call("set_crossfade_secs", ["secs": Double(seconds)], as: Double.self).rounded())
    }
    func setNormalize(_ on: Bool) async throws { _ = try await call("set_normalize_volume", ["on": on]) }
    func setVolumeLevel(_ level: VolumeLevel) async throws { _ = try await call("set_volume_level", ["level": level.rawValue]) }
    func setSleepTimer(minutes: Int?, endOfTrack: Bool) async throws -> SleepState {
        try await call("set_sleep_timer", ["minutes": minutes.map(Double.init), "endOfTrack": endOfTrack])
    }
    func cancelSleepTimer() async throws -> SleepState { try await call("cancel_sleep_timer") }

    // MARK: smart

    func smartSettings() async throws -> SmartSettings { try await call("smart_settings") }
    func smartSetSetting(key: String, value: String) async throws { _ = try await call("smart_set_setting", ["key": key, "value": value]) }
    func madeForYou() async throws -> [MfyCard] {
        try await call("made_for_you", as: Lossy<MfyCard>.self).items.map { c in
            var c = c; c.thumbnail = Self.mfyArt(id: c.id, title: c.title, c.thumbnail); return c
        }
    }
    func smartMix(id: String, size: Int?) async throws -> [SongItem] { try await call("smart_mix", ["id": id, "size": size]) }
    func whatsNew() async throws -> WhatsNew { try await call("whats_new") }
    func whatsNewMarkSeen() async throws { _ = try await call("whats_new_mark_seen") }
    func smartShuffleState() async throws -> SmartShuffleState { try await call("smart_shuffle_state") }
    func smartShuffleSet(_ on: Bool) async throws -> SmartShuffleState { try await call("smart_shuffle_set", ["on": on]) }

    // MARK: downloads

    func downloadsSnapshot() async throws -> DownloadsSnapshot { try await call("downloads_snapshot") }
    func downloadsAdd(_ collection: DownloadCollection, songs: [SongItem]?) async throws {
        _ = try await call("downloads_add", ["collection": collection, "songs": songs])
    }
    func downloadsRemove(id: String) async throws { _ = try await call("downloads_remove", ["id": id]) }
    func downloadsRemoveAll() async throws { _ = try await call("downloads_remove_all") }
    func downloadsSetSettings(_ patch: DownloadSettingsPatch) async throws -> DownloadsSnapshot {
        try await call("downloads_set_settings", ["patch": patch])
    }

    // MARK: library extras

    func setPinned(id: String, kind: String, pinned: Bool) async throws {
        if pinned { _ = try await call("lib_pin", ["itemId": id, "kind": kind]) } else { _ = try await call("lib_unpin", ["itemId": id]) }
    }
    func createFolder(name: String) async throws -> Folder { try await call("lib_folder_create", ["name": name]) }
    func setPrivateSession(_ on: Bool) async throws { _ = try await call("lib_set_private_session", ["enabled": on]) }

    // MARK: settings

    func getSettings() async throws -> [String: String] {
        try await call("get_settings", as: [String: LooseString].self).mapValues(\.value)
    }
    func setSetting(key: String, value: String) async throws { _ = try await call("set_setting", ["key": key, "value": value]) }

    // MARK: Spotify import

    func importRead(link: String) async throws -> ImportPreview { try await call("import_read", ["link": link]) }
    /// A picked file is security-scoped and may be in another app's container: copy it to tmp first.
    func importReadFile(url: URL) async throws -> ImportPreview {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: url, to: tmp)
        return try await call("import_read", ["path": tmp.path])
    }
    func importStart(lists: [Int]) async throws -> ImportSnapshot { try await call("import_start", ["lists": lists]) }
    func importStatus() async throws -> ImportSnapshot? { try await call("import_status") }

    // MARK: formerly UI-local

    func smartShuffleRemove(videoId: String) async throws -> SmartShuffleState { try await call("smart_shuffle_remove", ["videoId": videoId]) }
    func smartShuffleKeep(videoId: String) async throws -> SmartShuffleState { try await call("smart_shuffle_keep", ["videoId": videoId]) }
    func cacheSize() async throws -> Double { try await call("cache_size") }
    func clearCaches() async throws { _ = try await call("clear_caches") }
    func moveToFolder(itemId: String, folderId: String?) async throws {
        _ = try await call("lib_folder_set_item", ["itemId": itemId, "folderId": folderId])
    }
    func podcastShowMore(id: String, continuation: String, sort: EpisodeSort) async throws -> PodcastEpisodePage {
        try await call("podcast_show_more", ["id": id, "continuation": continuation, "sort": sort.rawValue])
    }
    func addToPlaylist(id: String, songs: [SongItem]) async throws {
        guard isLocalPlaylistId(id) else { try await addToYouTubePlaylist(id, songs: songs); return }
        _ = try await call("lib_playlist_add", ["id": id, "songs": songs])
    }
    func startRadio(kind: String, id: String, name: String?) async throws {
        _ = try await call("start_radio", ["kind": kind, "id": id, "name": name])
    }

    func clearQueued() async throws { _ = try await call("clear_queued") }
    func setHidden(_ song: SongItem, hidden: Bool) async throws {
        if hidden { _ = try await call("lib_hide_song", ["videoId": song.videoId, "song": song]) }
        else { _ = try await call("lib_unhide_song", ["videoId": song.videoId]) }
    }
    func whatsNewRefreshed() async throws -> WhatsNew { try await call("whats_new", ["refresh": true]) }
    func updatePlaylist(id: String, name: String?, description: String?) async throws {
        guard isLocalPlaylistId(id) else { return try await editPlaylistDetails(playlistId: id, name: name, description: description, public: nil) }
        _ = try await call("lib_playlist_update", ["id": id, "name": name, "description": description])
    }
    func deletePlaylist(id: String) async throws {
        guard isLocalPlaylistId(id) else { return try await deletePlaylist(playlistId: id) }
        _ = try await call("lib_playlist_delete", ["id": id])
    }
    func restorePlaylist(id: String) async throws { _ = try await call("lib_playlist_restore", ["id": id]) }
    func playlistEntries(id: String) async throws -> [PlaylistEntry] {
        try await call("lib_playlist_entries", ["id": id], as: [PlaylistEntry].self)
    }
    func removeFromPlaylist(id: String, rowIds: [Int64]) async throws { _ = try await call("lib_playlist_remove", ["id": id, "rowIds": rowIds]) }
    func setPlaylistOrder(id: String, rowIds: [Int64]) async throws { _ = try await call("lib_playlist_set_order", ["id": id, "rowIds": rowIds]) }

    // MARK: entity pages (stream magic-ib)

    func playlistRecommendations(playlistId: String, n: Int, refresh: Int) async throws -> [Recommendation] {
        try await call("playlist_recommendations", ["playlistId": playlistId, "n": n, "refresh": refresh], as: Lossy<Recommendation>.self).items
    }
    func getPlaylist(id: String, sort: String?, desc: Bool) async throws -> PlaylistPage {
        try await call("get_playlist", ["id": id, "sort": sort, "desc": desc])
    }
    func setPlaylistSort(playlistId: String, sort: String) async throws {
        _ = try await call("set_playlist_sort", ["playlistId": playlistId, "sort": sort])
    }
    func podcastHome() async throws -> [Shelf] { try await call("podcast_home", as: Lossy<Shelf>.self).items }
    func podcastCategory(genre: String) async throws -> [ShelfItem] { try await call("podcast_category", ["genre": genre]) }
    // stream: audiobooks
    func audiobookSearch(query: String) async throws -> [Audiobook] { try await call("audiobook_search", ["query": query], as: Lossy<Audiobook>.self).items }
    func audiobookHome() async throws -> [Shelf] { try await call("audiobook_home", as: Lossy<Shelf>.self).items }
    func audiobookGenre(genre: String) async throws -> [Audiobook] { try await call("audiobook_genre", ["genre": genre], as: Lossy<Audiobook>.self).items }
    func audiobookPage(id: String) async throws -> AudiobookPage { try await call("audiobook_page", ["id": id]) }
    func audiobookForChapter(id: String) async throws -> AudiobookPage? { try await call("audiobook_for_chapter", ["id": id]) }
    func audiobookSave(_ book: Audiobook, saved: Bool) async throws { _ = try await call("audiobook_save", ["book": book, "saved": saved]) }
    func audiobookSaved() async throws -> [Audiobook] { try await call("audiobook_saved", as: Lossy<Audiobook>.self).items }
    func smartHomeLocal() async throws -> [Shelf] {
        try await call("smart_home_local", as: Lossy<Shelf>.self).items.map { s in
            var s = s
            s.items = s.items.map { var i = $0; i.thumbnail = Self.mfyArt(id: i.id, title: i.title, i.thumbnail); return i }
            return s
        }
    }
    func playableFlags(_ items: [SongItem]) async throws -> [String: Bool] {
        try await call("playable_flags", ["items": items])
    }

    /// The artist page's shelves with their "more" targets (the app's `ArtistCarousel` drops them).
    struct MoreShelf: Decodable { var kind: String?; var items: Lossy<BrowseItem>; var moreBrowseId: String?; var moreParams: String? }
    private struct CoreArtist: Decodable { var name: String?; var sections: [MoreShelf]; var topSongs: Lossy<SongItem> }

    /// Every release (each shelf through its "more" page) and the top songs, into the core's chips.
    func artistDiscography(id: String) async throws -> Discography {
        let a: CoreArtist = try await call("get_artist", ["id": id])
        async let albums = releases(a.sections.first { $0.kind == "albums" })
        async let singles = releases(a.sections.first { $0.kind == "singles" })
        return Discography.build(albums: await albums, singles: await singles, topSongs: a.topSongs.items, artistName: a.name ?? "")
    }

    /// One release shelf in full through its "more" page; a shelf whose page fails keeps its first ten.
    private func releases(_ s: MoreShelf?) async -> [BrowseItem] {
        guard let s else { return [] }
        guard let more = s.moreBrowseId,
              let all = try? await call("get_browse_grid", ["id": more, "params": s.moreParams], as: Lossy<BrowseItem>.self).items,
              !all.isEmpty else { return s.items.items }
        return all
    }

    // MARK: events

    func setListener(_ listener: CoreEventListener?) { events.set(listener) }

    // MARK: engine (AudioEngineControl)

    func aoReload() {
        do { try core.aoReload() } catch { coreLog.error("ao-reload failed: \(String(describing: error), privacy: .public)") }
    }
    func setAudioOutput(_ ao: String, pcmFile: String?) {
        do { try core.setAudioOutput(ao: ao, pcmFile: pcmFile) } catch { coreLog.error("ao=\(ao, privacy: .public) failed: \(String(describing: error), privacy: .public)") }
    }
    func setVolume(_ volume: Int) {
        do { try core.setVolume(volume: Int64(volume)) } catch { coreLog.error("volume failed: \(String(describing: error), privacy: .public)") }
    }
    var position: Double { core.position() }
    func checkProxies(_ reason: String) -> Bool { core.checkProxies(reason: reason) }
    func killProxies() { core.debugKillProxies() }
    func killProxyOnNextLoad() { core.debugKillProxyOnLoad() }
    /// Probed once by the player (a short decode); cached here.
    private(set) lazy var capabilities: AudioCaps = {
        let c = core.audioCapabilities()
        return AudioCaps(pitch: c.pitch, reverb: c.reverb, speed: c.speed, eqFlavor: c.eqFlavor)
    }()
}

extension AppModel {
    /// Which audio controls to show (pitch and reverb are hidden on iOS).
    var audioCaps: AudioCaps { (core as? AudioEngineControl)?.capabilities ?? .iosDefault }
}

/// The UniFFI listener: hands every event (name + desktop JSON) to the app's listener.
private final class Events: EventListener, @unchecked Sendable {
    private let lock = NSLock()
    private weak var target: CoreEventListener?
    func set(_ l: CoreEventListener?) { lock.lock(); target = l; lock.unlock() }
    func onEvent(name: String, json: String) {
        lock.lock(); let t = target; lock.unlock()
        t?.onEvent(name: name, json: Data(json.utf8))
    }
}

/// Decodes an array, dropping elements the app's models can't represent (a kind added on the
/// desktop later) instead of failing the whole screen.
struct Lossy<T: Decodable>: Decodable {
    var items: [T]
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [T] = []
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) { out.append(v) } else {
                _ = try? c.decode(Skip.self)
                coreLog.debug("dropped an undecodable \(String(describing: T.self), privacy: .public)")
            }
        }
        items = out
    }
    private struct Skip: Decodable {}
}

/// A settings value as a string, whatever JSON scalar the core stored.
struct LooseString: Decodable {
    var value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let b = try? c.decode(Bool.self) { value = b ? "true" : "false" }
        else if let d = try? c.decode(Double.self) { value = d == d.rounded() ? String(Int(d)) : String(d) }
        else { value = "" }
    }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ v: Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
