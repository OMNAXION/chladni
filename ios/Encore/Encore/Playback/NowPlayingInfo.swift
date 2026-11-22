// The system's Now Playing (lock screen, Notification Center, Dynamic Island, Control Center,
// AirPlay receivers), built the way Spotify's iOS app fills it:
// - title, with the "E" badge for an explicit song (`MPMediaItemPropertyIsExplicit`);
// - every artist joined with ", " ("Kanye West, PARTYNEXTDOOR"), not YouTube's " & " byline;
// - square artwork, ready with (or right after) the first publish, the next track's prefetched;
// - elapsed + rate on every jump, so the system's own extrapolation keeps the scrubber honest.
// `PlaybackBridge` owns the state and the session; this file is the pure dictionary builder (unit
// tested in `NowPlayingInfoTests`), the artwork store, and a read-back for on-device checks.
import AVFoundation
import MediaPlayer
import UIKit

/// What the bridge knows at publish time, as plain values.
struct NowPlayingState: Equatable {
    var now: NowPlaying
    var paused: Bool
    var position: Double
    var duration: Double
    var speed: Double = 1
}

enum NowPlayingInfo {
    /// Spotify lists every artist, comma-separated. The core's runs are already split into names
    /// (joiners like " & " / " x " / "feat." dropped, "Simon & Garfunkel" kept whole); without runs
    /// the plain byline stays as YouTube wrote it.
    static func artistLine(_ n: NowPlaying) -> String {
        var seen = Set<String>()
        let names = (n.artistRuns ?? [])
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return names.isEmpty ? n.artists : names.joined(separator: ", ")
    }

    static func dictionary(_ s: NowPlayingState, artwork: MPMediaItemArtwork?) -> [String: Any] {
        let n = s.now
        let live = n.live == true
        var elapsed = max(0, s.position)
        if s.duration > 0 { elapsed = min(elapsed, s.duration) }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: n.title,
            MPMediaItemPropertyArtist: artistLine(n),
            MPMediaItemPropertyIsExplicit: n.explicit == true,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: live ? 0.0 : elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: s.paused ? 0.0 : s.speed,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: n.videoId,
        ]
        if let a = n.album?.trimmingCharacters(in: .whitespaces), !a.isEmpty { info[MPMediaItemPropertyAlbumTitle] = a }
        if live {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        } else if s.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = s.duration
            info[MPNowPlayingInfoPropertyPlaybackProgress] = elapsed / s.duration
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        return info
    }

    /// "m:ss" / "h:mm:ss" → seconds.
    static func parseClock(_ s: String?) -> Double {
        guard let s else { return 0 }
        return s.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
    }

    /// The art URL the system gets: a googleusercontent cover asked at lock-screen size.
    static func artURL(_ thumbnail: String?) -> String? {
        guard let t = thumbnail, !t.isEmpty else { return nil }
        return sizedArt(t, 720) ?? t
    }

    /// What the system actually holds right now, read back from `MPNowPlayingInfoCenter` and the
    /// command center: the on-device check (the phone's screen can't be seen from the Mac).
    @MainActor static func dump(_ reason: String) -> String {
        let c = MPNowPlayingInfoCenter.default()
        let i = c.nowPlayingInfo ?? [:]
        let rc = MPRemoteCommandCenter.shared()
        let cmds: [(String, MPRemoteCommand)] = [
            ("play", rc.playCommand), ("pause", rc.pauseCommand), ("toggle", rc.togglePlayPauseCommand),
            ("next", rc.nextTrackCommand), ("prev", rc.previousTrackCommand), ("seek", rc.changePlaybackPositionCommand),
            ("skip+", rc.skipForwardCommand), ("skip-", rc.skipBackwardCommand), ("like", rc.likeCommand),
            ("dislike", rc.dislikeCommand), ("bookmark", rc.bookmarkCommand),
            ("repeat", rc.changeRepeatModeCommand), ("shuffle", rc.changeShuffleModeCommand),
        ]
        let on = cmds.filter { $0.1.isEnabled }.map(\.0).joined(separator: ",")
        let art: String = {
            guard let a = i[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork else { return "none" }
            guard let img = a.image(at: CGSize(width: 300, height: 300)) else { return "nil-image" }
            return "\(Int(img.size.width * img.scale))x\(Int(img.size.height * img.scale))"
        }()
        let s = AVAudioSession.sharedInstance()
        let state: String = switch c.playbackState {
        case .playing: "playing"
        case .paused: "paused"
        case .stopped: "stopped"
        case .interrupted: "interrupted"
        default: "unknown"
        }
        let app = switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        default: "background"
        }
        func num(_ k: String) -> String { (i[k] as? NSNumber).map { String(format: "%.2f", $0.doubleValue) } ?? "-" }
        return "NPDUMP reason=\(reason) title=\"\(i[MPMediaItemPropertyTitle] as? String ?? "-")\" "
            + "artist=\"\(i[MPMediaItemPropertyArtist] as? String ?? "-")\" album=\"\(i[MPMediaItemPropertyAlbumTitle] as? String ?? "-")\" "
            + "explicit=\((i[MPMediaItemPropertyIsExplicit] as? NSNumber)?.boolValue == true ? 1 : 0) artwork=\(art) "
            + "duration=\(num(MPMediaItemPropertyPlaybackDuration)) elapsed=\(num(MPNowPlayingInfoPropertyElapsedPlaybackTime)) "
            + "rate=\(num(MPNowPlayingInfoPropertyPlaybackRate)) live=\((i[MPNowPlayingInfoPropertyIsLiveStream] as? NSNumber)?.boolValue == true ? 1 : 0) "
            + "state=\(state) commands=\(on) session=\(s.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")) "
            + "mixable=\(s.categoryOptions.contains(.mixWithOthers) ? 1 : 0) options=\(s.categoryOptions.rawValue) "
            + "mode=\(s.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: "")) policy=\(s.routeSharingPolicy.rawValue) "
            + "otherAudio=\(s.isOtherAudioPlaying ? 1 : 0) route=\(PlaybackBridge.routeName(s.currentRoute)) app=\(app)"
    }
}

/// Lock-screen artwork, kept ready: a few `MPMediaItemArtwork`s by URL (current, next, previous),
/// so a queue advance publishes its cover in the same dictionary as its title.
@MainActor
final class NowPlayingArtwork {
    private var cache: [String: MPMediaItemArtwork] = [:]
    private var order: [String] = []
    private var inflight: [String: Task<MPMediaItemArtwork?, Never>] = [:]
    private let limit = 6

    func cached(_ url: String?) -> MPMediaItemArtwork? { url.flatMap { cache[$0] } }

    func load(_ url: String) async -> MPMediaItemArtwork? {
        if let hit = cache[url] { return hit }
        if let t = inflight[url] { return await t.value }
        // Stored by the task itself (main actor), before any waiter resumes: a caller woken first
        // must find it in `cached` already.
        let t = Task<MPMediaItemArtwork?, Never> { [weak self] in
            let img = await ArtworkCache.shared.image(url)
            let art = img.map { Self.artwork(Self.squared($0)) }
            if let art { self?.store(url, art) }
            self?.inflight[url] = nil
            return art
        }
        inflight[url] = t
        return await t.value
    }

    /// Warm the next/previous covers so a skip never shows an empty square.
    func prefetch(_ urls: [String?]) {
        for u in urls.compactMap({ $0 }) where cache[u] == nil && inflight[u] == nil {
            Task { _ = await load(u) }
        }
    }

    private func store(_ url: String, _ art: MPMediaItemArtwork) {
        cache[url] = art
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > limit { cache[order.removeFirst()] = nil }
    }

    /// The handler runs on whatever queue MediaPlayer likes: nonisolated, capturing only the image.
    nonisolated static func artwork(_ img: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }

    /// Spotify's cover is always square; a video thumbnail (16:9, or 4:3 letterboxed) is cropped to
    /// its centre so the island and lock screen don't show bars.
    nonisolated static func squared(_ img: UIImage) -> UIImage {
        guard let cg = img.cgImage else { return img }
        let w = cg.width, h = cg.height
        guard abs(w - h) > max(w, h) / 50 else { return img }
        var side = min(w, h)
        // A 4:3 YouTube `hqdefault` frames a 16:9 picture between black bars: crop inside them.
        if w > h, abs(Double(w) / Double(h) - 4.0 / 3.0) < 0.02 { side = w * 9 / 16 }
        let rect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
        guard let c = cg.cropping(to: rect) else { return img }
        return UIImage(cgImage: c, scale: img.scale, orientation: img.imageOrientation)
    }
}

/// The audio trace on disk too (`Library/Caches/Encore/audio.log`, one rollover to `.1` at 512 KB):
/// on a real phone the stdout console only lives while devicectl launched the process, so a
/// relaunch from the home screen or the lock screen would leave no `NOWPLAYING` lines. Read with
/// `devicectl device copy from --domain-type appDataContainer --domain-identifier studio.chladni.ios`.
enum AudioTraceFile {
    private static let queue = DispatchQueue(label: "studio.chladni.audio-trace")
    private static let url: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Encore", isDirectory: true).appendingPathComponent("audio.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func append(_ line: String) {
        guard let url else { return }
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512 * 1024 {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            guard let data = text.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
