// Synthetic audio-session events for tests (plan §6 "Interruptions/route changes"): the simulator
// can't place a call or unplug headphones, so these post the real notifications with real userInfo
// through `NotificationCenter`, exercising PlaybackBridge's own observers.
//
// Triggers: the Debug menu (encore://debug), or from the command line with a Darwin notification:
//   xcrun simctl spawn <udid> notifyutil -p app.encore.debug.interruption-began
// Names: interruption-began, interruption-ended-resume, interruption-ended, route-old-unavailable,
// route-new-available, media-reset, remote-toggle, remote-next, seek-near-end, state, np-dump,
// kill-proxy, kill-proxy-on-load.
// On a real phone (no notifyutil): `chladni://debug?audio=<name>` (devicectl --payload-url).
import AVFoundation
import SwiftUI

enum DebugAudio {
    enum Action: String, CaseIterable, Identifiable {
        case interruptionBegan = "interruption-began"
        case interruptionEndedResume = "interruption-ended-resume"
        case interruptionEnded = "interruption-ended"
        case routeOldUnavailable = "route-old-unavailable"
        case routeNewAvailable = "route-new-available"
        case mediaReset = "media-reset"
        case remoteToggle = "remote-toggle"
        case remoteNext = "remote-next"
        case seekNearEnd = "seek-near-end"
        case state = "state"
        case npDump = "np-dump"
        case killProxy = "kill-proxy"
        case killProxyOnLoad = "kill-proxy-on-load"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .interruptionBegan: "Interruption began"
            case .interruptionEndedResume: "Interruption ended (should resume)"
            case .interruptionEnded: "Interruption ended (no resume)"
            case .routeOldUnavailable: "Route: headphones unplugged"
            case .routeNewAvailable: "Route: new device"
            case .mediaReset: "Media services reset"
            case .remoteToggle: "Remote: play/pause"
            case .remoteNext: "Remote: next track"
            case .seekNearEnd: "Seek to 10 s before the end"
            case .state: "Log state"
            case .npDump: "Log system Now Playing"
            case .killProxy: "Kill the stream proxies (as iOS does when suspended)"
            case .killProxyOnLoad: "Kill the audio proxy after the next load"
            }
        }
    }

    @MainActor static func fire(_ a: Action) {
        let s = AVAudioSession.sharedInstance()
        let nc = NotificationCenter.default
        audioTrace("debug: \(a.rawValue)")
        switch a {
        case .interruptionBegan:
            nc.post(name: AVAudioSession.interruptionNotification, object: s, userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
                AVAudioSessionInterruptionReasonKey: AVAudioSession.InterruptionReason.default.rawValue,
            ])
        case .interruptionEndedResume, .interruptionEnded:
            nc.post(name: AVAudioSession.interruptionNotification, object: s, userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: a == .interruptionEndedResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0,
            ])
        case .routeOldUnavailable, .routeNewAvailable:
            nc.post(name: AVAudioSession.routeChangeNotification, object: s, userInfo: [
                AVAudioSessionRouteChangeReasonKey: (a == .routeOldUnavailable
                    ? AVAudioSession.RouteChangeReason.oldDeviceUnavailable : .newDeviceAvailable).rawValue,
                AVAudioSessionRouteChangePreviousRouteKey: s.currentRoute,
            ])
        case .mediaReset:
            nc.post(name: AVAudioSession.mediaServicesWereResetNotification, object: s)
        case .remoteToggle:
            _ = MPRemoteDispatch.send(.toggle)
        case .remoteNext:
            _ = MPRemoteDispatch.send(.next)
        case .seekNearEnd:
            if let app = PlaybackBridge.shared.app, app.player.duration > 15 {
                let t = app.player.duration - 10
                Task { try? await app.core.seek(position: t) }
            }
        case .state:
            audioTrace("state: \(PlaybackBridge.shared.stateLine)")
        case .npDump:
            audioTrace(NowPlayingInfo.dump("debug"))
            #if DEBUG
            SystemNowPlayingProbe.log()
            #endif
        case .killProxy:
            (PlaybackBridge.shared.app?.core as? AudioEngineControl)?.killProxies()
        case .killProxyOnLoad:
            (PlaybackBridge.shared.app?.core as? AudioEngineControl)?.killProxyOnNextLoad()
        }
    }

    /// Darwin-notification triggers (`notifyutil -p app.encore.debug.<name>`).
    @MainActor static func listen(_ bridge: PlaybackBridge) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for a in Action.allCases {
            let name = "app.encore.debug.\(a.rawValue)" as CFString
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let raw = name?.rawValue as String?,
                      let a = DebugAudio.Action(rawValue: String(raw.dropFirst("app.encore.debug.".count))) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { DebugAudio.fire(a) } }
            }, name, nil, .deliverImmediately)
        }
    }
}

/// Fires the same handlers the lock screen would (the command center has no public "send").
@MainActor enum MPRemoteDispatch {
    enum Cmd { case toggle, next }
    static var handlers: [Cmd: () -> Void] = [:]
    static func send(_ c: Cmd) -> Bool {
        guard let h = handlers[c] else { return false }
        h()
        return true
    }
}

/// encore://debug: the buttons, plus the live state line.
struct DebugAudioMenu: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state = PlaybackBridge.shared.stateLine
    var body: some View {
        NavigationStack {
            List {
                Section("Audio session") {
                    ForEach(DebugAudio.Action.allCases) { a in
                        Button(a.title) { DebugAudio.fire(a); state = PlaybackBridge.shared.stateLine }
                            .accessibilityIdentifier("debug-\(a.rawValue)")
                    }
                }
                Section("State") { Text(state).font(.footnote.monospaced()) }
            }
            .navigationTitle("Debug")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

#if DEBUG
/// Debug only: asks MediaRemote (private) which process the system treats as the Now Playing app,
/// the one thing `MPNowPlayingInfoCenter` can't tell us. `NPAPP pid=<theirs> self=<ours> us=1`
/// means the island and lock screen are ours. iOS may refuse it to third-party apps: then
/// `NPAPP unavailable`, and the lock-screen screenshot is the evidence.
enum SystemNowPlayingProbe {
    private typealias GetPID = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    private typealias GetBool = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void

    static func log() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else {
            audioTrace("NPAPP unavailable (no MediaRemote)"); return
        }
        let me = getpid()
        if let f = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID") {
            unsafeBitCast(f, to: GetPID.self)(.main) { pid in
                audioTrace("NPAPP pid=\(pid) self=\(me) us=\(pid == me ? 1 : 0)")
            }
        } else { audioTrace("NPAPP unavailable (no symbol)") }
        if let f = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            unsafeBitCast(f, to: GetBool.self)(.main) { playing in audioTrace("NPAPP isPlaying=\(playing ? 1 : 0)") }
        }
    }
}
#endif
