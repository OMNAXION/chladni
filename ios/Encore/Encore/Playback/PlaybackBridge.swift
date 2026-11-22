// iOS audio plumbing around the core's player (docs/research/23-ios-plan.md §2.3):
// - the audio session (`.playback`, long-form), active before mpv opens its AudioUnit output.
//   It must stay non-mixable or iOS never makes us the Now Playing app: mpv rewrites the category
//   on every output open, hence `audio-exclusive=yes` in crates/player (docs/streams/island.md);
// - the lock screen / Control Center (`MPNowPlayingInfoCenter`), from the core's events;
// - remote commands (headphones, lock screen, CarPlay later) back into the core;
// - interruptions (calls, Siri, alarms), route changes (headphones out → pause) and media-services
//   resets, with mpv's `ao-reload` where its AudioUnit has to be reopened.
// Engine-agnostic: works over `CoreClient` (the mock gets a lock screen too); the real core adds
// `AudioEngineControl` for the output itself.
import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
import UIKit
import os

let audioLog = Logger(subsystem: "studio.chladni.ios", category: "audio")

/// One line to the unified log and the diagnostics file (`audio.log`), and in Debug builds to stdout
/// too (`simctl launch --console-pty` in the verify script). Release builds print nothing.
func audioTrace(_ s: String) {
    audioLog.info("\(s, privacy: .public)")
    #if DEBUG
    print("ENCORE_AUDIO \(s)")
    #endif
    AudioTraceFile.append(s)
}

@MainActor
final class PlaybackBridge {
    static let shared = PlaybackBridge()

    private(set) weak var app: AppModel?
    private var engine: AudioEngineControl? { app?.core as? AudioEngineControl }
    private let session = AVAudioSession.sharedInstance()
    private let center = MPNowPlayingInfoCenter.default()
    private var observers: [NSObjectProtocol] = []

    // what the lock screen shows
    private var now: NowPlaying?
    private var paused = true
    private var duration: Double = 0
    private var position: Double = 0
    /// Wall clock of the last `position` we published, to tell a seek from normal progress.
    private var publishedAt = Date()
    private var publishedPosition: Double = 0
    /// Lock-screen covers, current + neighbours (NowPlayingInfo.swift).
    private let art = NowPlayingArtwork()
    private var artTask: Task<Void, Never>?
    private var statePublish: Task<Void, Never>?
    private var speed: Double = 1

    // interruptions
    /// Playing when an interruption began: resume when it ends with `.shouldResume`.
    private(set) var interruptedWhilePlaying = false
    /// The session couldn't be reactivated in the background (OSStatus 560557684): retry on foreground.
    private var pendingReactivation = false
    private var stallCheck: Task<Void, Never>?

    private init() {}

    // MARK: session

    /// Before the core starts (mpv opens its AudioUnit on the first file, under this session).
    static func configureSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try s.setActive(true)
            audioTrace("session active category=\(s.category.rawValue) policy=longFormAudio route=\(routeName(s.currentRoute))")
        } catch {
            audioTrace("session setup failed: \(error)")
        }
    }

    func attach(_ app: AppModel) {
        guard self.app == nil else { return }
        self.app = app
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
                let info = n.userInfo ?? [:]
                MainActor.assumeIsolated { self?.handleInterruption(info) }
            },
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
                let info = n.userInfo ?? [:]
                MainActor.assumeIsolated { self?.handleRouteChange(info) }
            },
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleMediaServicesReset() }
            },
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didBecomeActive() }
            },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkProxies("foreground") }
            },
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.log("background (playing=\(!(self?.paused ?? true)))")
                    self?.resync("background")
                }
            },
        ]
        setupRemoteCommands()
        AudioRoute.shared.update(session.currentRoute)
        DebugAudio.listen(self)
        // `-traceAudio`: a position line every 2 s (the verify script reads these, also in the background).
        if UserDefaults.standard.bool(forKey: "traceAudio") {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let state = UIApplication.shared.applicationState == .background ? "background" : "foreground"
                    self.log(String(format: "POS t=%.1f pos=%.2f paused=%@ app=%@ id=%@", Date().timeIntervalSince1970,
                                    self.engine?.position ?? self.position, self.paused ? "1" : "0", state, self.now?.videoId ?? "-"))
                }
            }
        }
    }

    private func log(_ s: String) { audioTrace(s) }

    /// iOS reclaims a suspended app's listening sockets, which kills the core's loopback stream
    /// proxies: every track then fails to open. Check (and rebuild) them whenever the app comes
    /// back or the session is (re)activated. Off the main thread: the check is a blocking connect.
    func checkProxies(_ reason: String) {
        guard let engine else { return }
        Task.detached(priority: .userInitiated) {
            let dead = engine.checkProxies(reason)
            if dead { audioTrace("proxy: rebuilt (\(reason))") }
        }
    }

    // MARK: core events → Now Playing

    /// Called for every core event (AppModel.apply), in order.
    func handle(_ ev: CoreEvent) {
        switch ev {
        case .nowPlaying(let n):
            let changed = n.videoId != now?.videoId
            now = n
            if changed {
                position = 0; publishedPosition = 0
                duration = NowPlayingInfo.parseClock(n.duration)
                speed = 1
            }
            updateRemoteAvailability()
            publish(reason: changed ? "track" : "meta")
            if changed { prefetchNeighbours() }
            claimNowPlaying()
        case .duration(let d):
            guard abs(d - duration) > 0.5 else { return }
            duration = d
            publish(reason: "duration")
        case .playbackState(let p):
            guard p != paused else { return }
            paused = p
            if !p { interruptedWhilePlaying = false }
            position = engine?.position ?? position
            // Coalesced: at launch mpv reports `playing` while idle and the core corrects it to
            // `paused` a moment later; publishing both flashed the island's bars for a restored track.
            statePublish?.cancel()
            statePublish = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let self, !Task.isCancelled else { return }
                self.publish(reason: self.paused ? "pause" : "play")
            }
        case .position(let p):
            position = p
            // Publish only on a jump (seek, restart); the system extrapolates from elapsed + rate.
            let expected = publishedPosition + (paused ? 0 : Date().timeIntervalSince(publishedAt) * speed)
            if abs(p - expected) > 1 { publish(reason: "seek") }
        case .playbackParams(let e):
            speed = e.speed
            publish(reason: "rate")
        case .rating(let id, let r) where id == now?.videoId:
            now?.rating = r
        case .queueChanged, .queueIndex, .queueAppended:
            prefetchNeighbours()
        default: break
        }
    }

    /// After the stores have applied this event (they run right after the bridge): warm the covers
    /// a skip either way would publish.
    private func prefetchNeighbours() {
        Task { @MainActor [weak self] in
            guard let self, let p = self.app?.player else { return }
            self.art.prefetch([p.next, p.previous].map { NowPlayingInfo.artURL($0?.thumbnail) })
        }
    }

    /// Cold launch: the core restores the last track paused, possibly before this listener was
    /// attached. Spotify shows that track on the lock screen, paused, right away; so do we.
    func seed(from player: PlayerStore) {
        guard now == nil, let n = player.now else { return }
        now = n
        paused = player.paused
        position = player.position
        duration = player.duration > 0 ? player.duration : NowPlayingInfo.parseClock(n.duration)
        updateRemoteAvailability()
        publish(reason: "restore")
        prefetchNeighbours()
        claimNowPlaying()
    }

    /// iOS only makes an app the Now Playing app (island, lock screen, Control Center) once its
    /// non-mixable session has actually rendered audio. After a relaunch nothing has played yet,
    /// so the restored track appeared nowhere (`NPAPP pid=0`, docs/streams/island.md). A quarter
    /// second of silence through the same session claims it, like Spotify's paused restore. The
    /// session is already active and non-mixable from launch, so this interrupts nothing extra.
    /// Real engine only: the mock (tests, previews) has no audio to claim for.
    private var claimEngine: AVAudioEngine?
    /// Once per launch: set by the claim itself, or by any real playback (published, so after the
    /// boot `playing` flip has been coalesced away).
    private var claimed = false
    private var claimTask: Task<Void, Never>?
    private func claimNowPlaying() {
        guard engine != nil, !claimed, claimTask == nil else { return }
        // A moment after the restore settles: if the user (or a resume) starts playback first,
        // mpv's own output claims it and this does nothing.
        claimTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            self.claimTask = nil
            if !self.claimed, self.paused, self.now != nil { self.playSilence() }
        }
    }
    private func playSilence() {
        claimed = true
        let e = AVAudioEngine()
        let node = AVAudioPlayerNode()
        e.attach(node)
        let format = e.mainMixerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate / 4)) else { return }
        buf.frameLength = buf.frameCapacity
        if let ch = buf.floatChannelData {
            for i in 0..<Int(format.channelCount) { ch[i].update(repeating: 0, count: Int(buf.frameLength)) }
        }
        e.connect(node, to: e.mainMixerNode, format: format)
        do { try e.start() } catch { log("now playing claim failed: \(error)"); return }
        claimEngine = e
        node.scheduleBuffer(buf) { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                node.stop(); self.claimEngine?.stop(); self.claimEngine = nil
                self.publish(reason: "claim")
            }
        }
        node.play()
        log("now playing claim: silent buffer on restore")
    }

    private func publish(reason: String) {
        guard let n = now else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        let url = NowPlayingInfo.artURL(n.thumbnail)
        let artwork = art.cached(url)
        if artwork == nil, let url { loadArtwork(url) }
        let state = NowPlayingState(now: n, paused: paused, position: position, duration: duration, speed: speed)
        center.nowPlayingInfo = NowPlayingInfo.dictionary(state, artwork: artwork)
        center.playbackState = paused ? .paused : .playing
        if !paused { claimed = true }
        publishedAt = Date()
        publishedPosition = position
        log(String(format: "NOWPLAYING reason=%@ title=\"%@\" artist=\"%@\" explicit=%@ duration=%.1f elapsed=%.1f rate=%.2f artwork=%@ state=%@",
                   reason, n.title, NowPlayingInfo.artistLine(n), n.explicit == true ? "1" : "0", duration, position,
                   paused ? 0 : speed, artwork == nil ? "no" : "yes", paused ? "paused" : "playing"))
    }

    /// Republish the real clock (after a long background, an unlock, a stall): the system only
    /// extrapolates from the last elapsed + rate.
    func resync(_ reason: String) {
        guard now != nil else { return }
        if let p = engine?.position, p > 0 || position == 0 { position = p }
        publish(reason: reason)
    }

    private func loadArtwork(_ url: String) {
        artTask?.cancel()
        artTask = Task { [weak self] in
            guard let self, await self.art.load(url) != nil, !Task.isCancelled else { return }
            if NowPlayingInfo.artURL(self.now?.thumbnail) == url { self.publish(reason: "artwork") }
        }
    }

    // MARK: remote commands

    private func setupRemoteCommands() {
        let rc = MPRemoteCommandCenter.shared()
        rc.playCommand.addTarget { [weak self] _ in self?.remote("play") { $0.paused ? .toggle : .none } ?? .commandFailed }
        rc.pauseCommand.addTarget { [weak self] _ in self?.remote("pause") { $0.paused ? .none : .toggle } ?? .commandFailed }
        rc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.remote("toggle") { _ in .toggle } ?? .commandFailed }
        rc.nextTrackCommand.addTarget { [weak self] _ in self?.remote("next") { _ in .next } ?? .commandFailed }
        rc.previousTrackCommand.addTarget { [weak self] _ in self?.remote("previous") { _ in .previous } ?? .commandFailed }
        rc.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.remote("seek \(Int(e.positionTime))") { _ in .seek(e.positionTime) } ?? .commandFailed
        }
        rc.skipForwardCommand.preferredIntervals = [15]
        rc.skipBackwardCommand.preferredIntervals = [15]
        rc.skipForwardCommand.addTarget { [weak self] _ in self?.remote("skip+15") { _ in .relative(15) } ?? .commandFailed }
        rc.skipBackwardCommand.addTarget { [weak self] _ in self?.remote("skip-15") { _ in .relative(-15) } ?? .commandFailed }
        // Spotify's lock screen and island show previous / play-pause / next only: no like,
        // dislike or bookmark (those would take a transport slot or add a "…" menu).
        rc.likeCommand.isEnabled = false
        rc.dislikeCommand.isEnabled = false
        rc.bookmarkCommand.isEnabled = false
        rc.changeRepeatModeCommand.isEnabled = false
        rc.changeShuffleModeCommand.isEnabled = false
        MPRemoteDispatch.handlers[.toggle] = { [weak self] in _ = self?.remote("toggle") { _ in .toggle } }
        MPRemoteDispatch.handlers[.next] = { [weak self] in _ = self?.remote("next") { _ in .next } }
        updateRemoteAvailability()
    }

    /// Music: previous / next. Episodes: ±15 s skips in their place, like Spotify. A live broadcast
    /// has nothing to scrub.
    private func updateRemoteAvailability() {
        let rc = MPRemoteCommandCenter.shared()
        let episode = now?.isEpisode ?? (app?.player.current?.isEpisode == true)
        rc.skipForwardCommand.isEnabled = episode
        rc.skipBackwardCommand.isEnabled = episode
        rc.nextTrackCommand.isEnabled = !episode
        rc.previousTrackCommand.isEnabled = !episode
        rc.changePlaybackPositionCommand.isEnabled = now?.live != true
        rc.likeCommand.isEnabled = false
    }

    enum RemoteAction { case none, toggle, next, previous, seek(Double), relative(Double) }

    private func remote(_ name: String, _ decide: (PlaybackBridge) -> RemoteAction) -> MPRemoteCommandHandlerStatus {
        guard let app else { return .commandFailed }
        guard now != nil else { log("remote \(name): nothing playing"); return .noActionableNowPlayingItem }
        let action = decide(self)
        log("remote \(name)")
        let core = app.core
        switch action {
        case .none: break
        case .toggle:
            // Don't wait for the event: the lock screen should flip at once.
            paused.toggle(); position = engine?.position ?? position
            app.player.paused = paused
            publish(reason: paused ? "pause" : "play")
            Task { try? await core.togglePause() }
        case .next: app.player.lastDirection = 1; Task { try? await core.nextTrack() }
        case .previous: app.player.lastDirection = -1; Task { try? await core.prevTrack() }
        case .seek(let t):
            position = t; publish(reason: "seek")
            Task { try? await core.seek(position: t) }
        case .relative(let d):
            Task { try? await core.seekRelative(d) }
        }
        return .success
    }

    // MARK: interruptions, routes, resets

    func handleInterruption(_ info: [AnyHashable: Any]) {
        guard let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            let reason = (info[AVAudioSessionInterruptionReasonKey] as? UInt) ?? 0
            log("interruption began (reason=\(reason), playing=\(!paused))")
            if !paused {
                interruptedWhilePlaying = true
                setPaused(true)
            }
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(rawValue: (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
            log("interruption ended (shouldResume=\(opts.contains(.shouldResume)), wasPlaying=\(interruptedWhilePlaying))")
            guard opts.contains(.shouldResume), interruptedWhilePlaying else {
                interruptedWhilePlaying = false
                return
            }
            resumeAfterInterruption()
        @unknown default: break
        }
    }

    /// Reactivate, reopen mpv's AudioUnit, play. In the background the reactivation can be refused
    /// (`AVAudioSession.ErrorCode.cannotInterruptOthers`, 560557684): retry when foregrounded.
    private func resumeAfterInterruption() {
        do {
            try session.setActive(true)
        } catch {
            log("reactivate failed (\((error as NSError).code)); retry on foreground")
            pendingReactivation = true
            return
        }
        pendingReactivation = false
        checkProxies("session-activated")
        engine?.aoReload()
        interruptedWhilePlaying = false
        if paused { setPaused(false) }
        log("resumed after interruption")
    }

    private func didBecomeActive() {
        checkProxies("active")
        resync("foreground")
        if pendingReactivation {
            log("foreground: retrying the deferred resume")
            resumeAfterInterruption()
        } else if interruptedWhilePlaying, !session.isOtherAudioPlaying {
            // `.ended` sometimes never arrives. Don't start audio on our own; just make sure the
            // output is usable when the user taps play.
            // The flag stays: a late `.ended(shouldResume)` for this same interruption still resumes
            // (coming to the foreground can race the interruption itself), and playing by hand
            // clears it.
            log("foreground: interruption end not seen yet; reactivating, staying paused")
            try? session.setActive(true)
            engine?.aoReload()
        }
    }

    func handleRouteChange(_ info: [AnyHashable: Any]) {
        guard let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        let prev = (info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription).map(Self.routeName) ?? "?"
        log("route change reason=\(Self.reasonName(reason)) from=\(prev) to=\(Self.routeName(session.currentRoute))")
        AudioRoute.shared.update(session.currentRoute)
        switch reason {
        case .oldDeviceUnavailable:
            // Headphones pulled / Bluetooth gone: pause, never blast the speaker (Apple, Spotify).
            if !paused { setPaused(true); log("paused: old device unavailable") }
        case .newDeviceAvailable, .override, .routeConfigurationChange:
            checkStall()
        default: break
        }
    }

    /// After a new route: if the clock doesn't move within 1.5 s while playing, reopen the output.
    private func checkStall() {
        stallCheck?.cancel()
        guard !paused, let engine else { return }
        let start = engine.position
        stallCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, !self.paused else { return }
            if abs(engine.position - start) < 0.2 {
                self.log("output stalled on the new route: ao-reload")
                engine.aoReload()
            }
        }
    }

    func handleMediaServicesReset() {
        log("media services were reset: rebuilding the session and mpv's output")
        Self.configureSession()
        engine?.aoReload()
        setupRemoteCommands()
        publish(reason: "reset")
    }

    private func setPaused(_ p: Bool) {
        guard let app, p != paused else { return }
        paused = p
        position = engine?.position ?? position
        app.player.paused = p
        publish(reason: p ? "pause" : "play")
        Task { try? await app.core.togglePause() }
    }

    // MARK: helpers

    static func routeName(_ r: AVAudioSessionRouteDescription) -> String {
        r.outputs.map { "\($0.portType.rawValue)" }.joined(separator: "+")
    }

    static func reasonName(_ r: AVAudioSession.RouteChangeReason) -> String {
        switch r {
        case .unknown: "unknown"
        case .newDeviceAvailable: "newDeviceAvailable"
        case .oldDeviceUnavailable: "oldDeviceUnavailable"
        case .categoryChange: "categoryChange"
        case .override: "override"
        case .wakeFromSleep: "wakeFromSleep"
        case .noSuitableRouteForCategory: "noSuitableRoute"
        case .routeConfigurationChange: "routeConfigurationChange"
        @unknown default: "other"
        }
    }

    /// For the debug menu and logs.
    var stateLine: String {
        "now=\(now?.title ?? "-") paused=\(paused) pos=\(String(format: "%.1f", engine?.position ?? position)) interrupted=\(interruptedWhilePlaying) route=\(Self.routeName(session.currentRoute))"
    }
}

/// Where the audio goes, for the player chrome (Spotify: when the output isn't the phone, the
/// mini player's second line becomes the device name in accent and the devices glyph turns accent).
@MainActor @Observable
final class AudioRoute {
    static let shared = AudioRoute()

    /// The output's name when it isn't the phone itself (AirPlay, Bluetooth, CarPlay, HDMI, USB);
    /// nil on the built-in speaker, the receiver and wired headphones.
    private(set) var externalName: String?
    /// Tests and screenshots: pretend the output is this device (`-fakeRoute "Kitchen"`).
    var fake: String? { didSet { externalName = fake ?? live } }
    private var live: String?

    private init() {
        fake = UserDefaults.standard.string(forKey: "fakeRoute").flatMap { $0.isEmpty ? nil : $0 }
    }

    func update(_ route: AVAudioSessionRouteDescription) {
        live = Self.externalName(route.outputs.map { ($0.portType, $0.portName) })
        externalName = fake ?? live
    }

    /// The first output that isn't part of the phone; its system name ("Living Room", "AirPods Pro").
    nonisolated static func externalName(_ outputs: [(AVAudioSession.Port, String)]) -> String? {
        let phone: Set<AVAudioSession.Port> = [.builtInSpeaker, .builtInReceiver, .headphones, .lineOut]
        guard let o = outputs.first(where: { !phone.contains($0.0) }) else { return nil }
        let name = o.1.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        switch o.0 {
        case .airPlay: return "AirPlay"
        case .carAudio: return "CarPlay"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "Bluetooth"
        default: return "External device"
        }
    }
}

/// The system AirPlay / Bluetooth picker: iOS's stand-in for Spotify Connect's device list.
struct RoutePicker: UIViewRepresentable {
    var tint: UIColor = .white
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .clear
        v.activeTintColor = .clear
        v.prioritizesVideoDevices = false
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}

extension View {
    /// Make this (the devices glyph) open the system route picker: the real picker sits on top,
    /// invisible, so the tap lands on it while the Spotify-style icon stays what you see.
    func routePickerOverlay() -> some View {
        // 44 pt hit area whatever the glyph's size; an overlay doesn't change the layout.
        overlay(RoutePicker().frame(width: 44, height: 44).accessibilityLabel("Connect to a device").accessibilityIdentifier("route-picker"))
    }
}
