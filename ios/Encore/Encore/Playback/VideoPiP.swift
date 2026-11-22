// Picture in Picture for videos (stream video-pods): leave the app with a video showing (a video
// podcast or a music video) and the picture keeps playing in a floating window; close it and the
// sound carries on alone.
//
// mpv draws through Metal, and a backgrounded app may not use the GPU, so PiP can't take mpv's own
// output. Instead, while PiP is up, mpv switches to `vo=null` with copy-back decoding (no GPU at
// all) and keeps decoding and timing every frame against the audio clock; this pulls each new frame
// as BGRA (`EncoreCore.pipFrame`), wraps it in a `CMSampleBuffer` and enqueues it on the
// `AVSampleBufferDisplayLayer` that `AVPictureInPictureController` shows (iOS 15's sample-buffer
// content source). Back in the app, mpv draws into its layer again.
//
// In the app the display layer sits under mpv's layer in the same box, holding one still (the cover)
// so PiP has a live layer to start from automatically when the app goes to the background. No
// frames are pulled in the app: on `gpu-next` that would be a GPU readback, which MoltenVK aborted
// in on the simulator; the core refuses frames outside PiP mode.
import AVKit
import CoreMedia
import SwiftUI
import UIKit

/// One decoded frame: BGRA, rows top-down, `width * 4` bytes a row.
struct PipFrameData {
    var pts: Double
    var width: Int
    var height: Int
    var bgra: Data
}

final class SampleBufferView: UIView {
    static let shared = SampleBufferView(frame: CGRect(x: 0, y: 0, width: 16, height: 9))
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var display: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        display.videoGravity = .resizeAspect
        accessibilityIdentifier = "np-video-pip-layer"
    }
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class VideoPiP: NSObject {
    static let shared = VideoPiP()

    private var controller: AVPictureInPictureController?
    private weak var store: VideoStore?
    private weak var player: PlayerStore?
    private var engine: VideoEngine?
    private var openNowPlaying: (() -> Void)?
    private var enabled = false
    private let feeder = PipFeeder()
    private var timebase: CMTimebase?
    private var clock: Task<Void, Never>?

    func attach(store: VideoStore, player: PlayerStore, engine: VideoEngine?, openNowPlaying: @escaping () -> Void) {
        self.store = store
        self.player = player
        self.engine = engine
        self.openNowPlaying = openNowPlaying
        feeder.engine = engine
        feeder.layer = SampleBufferView.shared.display
    }

    /// A video is showing: PiP may start (automatically, on leaving the app). Off: no PiP, no feed.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            if controller == nil, AVPictureInPictureController.isPictureInPictureSupported() {
                let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: SampleBufferView.shared.display, playbackDelegate: self)
                let c = AVPictureInPictureController(contentSource: source)
                c.delegate = self
                c.requiresLinearPlayback = false
                controller = c
                setUpTimebase()
            }
            controller?.canStartPictureInPictureAutomaticallyFromInline = true
            if store?.pipActive == true { feeder.start() } else { standBy() }
            startClock()
        } else {
            controller?.canStartPictureInPictureAutomaticallyFromInline = false
            if store?.pipActive != true {
                feeder.stop()
                clock?.cancel()
            }
        }
    }

    /// Tell PiP the play state moved (its play/pause button and scrubber read the delegate).
    /// The still PiP opens on: the cover, black until it loads.
    private func standBy() {
        feeder.stop()
        feeder.enqueueStill(nil)
        let url = player?.current?.thumbnail ?? player?.now?.thumbnail
        guard let u = url.flatMap(URL.init(string:)) else { return }
        Task { [feeder] in
            guard let (data, _) = try? await URLSession.shared.data(from: u), let img = UIImage(data: data)?.cgImage,
                  self.store?.pipActive != true else { return }
            feeder.enqueueStill(img)
        }
    }

    func playbackChanged() {
        syncTimebase()
        controller?.invalidatePlaybackState()
    }

    var possible: Bool { controller?.isPictureInPicturePossible ?? false }

    /// For the simulator check (`notifyutil -p studio.chladni.video.pip`): start or stop PiP by hand.
    func toggleByHand() {
        guard let c = controller else {
            // No PiP here (the iPhone simulator reports none): run everything but the floating
            // window, so the frame path and its CPU cost can be measured.
            print("VIDEO_PIP unsupported here: simulating (supported=\(AVPictureInPictureController.isPictureInPictureSupported()))")
            fflush(stdout)
            if store?.pipActive == true { stopped() } else { started() }
            return
        }
        if c.isPictureInPictureActive { c.stopPictureInPicture() } else { c.startPictureInPicture() }
    }

    // The scrubber in the PiP window follows a timebase that runs at the playback rate.
    private func setUpTimebase() {
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        guard let tb else { return }
        timebase = tb
        SampleBufferView.shared.display.controlTimebase = tb
        syncTimebase()
    }

    private func syncTimebase() {
        guard let tb = timebase, let p = player else { return }
        CMTimebaseSetTime(tb, time: CMTime(seconds: p.position, preferredTimescale: 600))
        CMTimebaseSetRate(tb, rate: p.paused ? 0 : 1)
    }

    /// Keeps the PiP scrubber honest across seeks and stalls.
    private func startClock() {
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.syncTimebase()
                if let self, self.store?.pipActive == true {
                    print("VIDEO_PIP frames=\(self.feeder.frames) layer=\(SampleBufferView.shared.display.status.rawValue)")
                    fflush(stdout)
                }
            }
        }
    }

    fileprivate func started() {
        store?.pipActive = true
        engine?.setVideoPiP(true)
        feeder.start()
        print("VIDEO_PIP started")
        fflush(stdout)
    }

    fileprivate func stopped() {
        store?.pipActive = false
        // Hide the picture first when the app is still in the background (mpv then has no video to
        // reopen on the GPU), then hand mpv its own output back.
        store?.reapply()
        engine?.setVideoPiP(false)
        if enabled { standBy() } else { feeder.stop(); clock?.cancel() }
        print("VIDEO_PIP stopped")
        fflush(stdout)
    }
}

extension VideoPiP: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        MainActor.assumeIsolated { started() }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        MainActor.assumeIsolated { stopped() }
    }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated {
            print("VIDEO_PIP failed \(error.localizedDescription)")
            stopped()
        }
    }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated { openNowPlaying?() }
        completion(true)
    }
}

extension VideoPiP: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        MainActor.assumeIsolated {
            guard let p = player, p.paused == playing else { return }
            p.togglePause()
        }
    }
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        MainActor.assumeIsolated {
            let d = player?.duration ?? 0
            guard d > 0, player?.now?.live != true else {
                return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
            }
            return CMTimeRange(start: .zero, duration: CMTime(seconds: d, preferredTimescale: 600))
        }
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { player?.paused ?? true }
    }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated {
            if let p = player { p.seek(max(0, p.position + skipInterval.seconds)) }
        }
        completionHandler()
    }
}

/// Pulls mpv's frames on its own queue and enqueues every new one while PiP is up; in the app it
/// only holds a still.
final class PipFeeder: @unchecked Sendable {
    var engine: VideoEngine?
    var layer: AVSampleBufferDisplayLayer?
    private let queue = DispatchQueue(label: "spotless.pip", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var lastPts: Double?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var format: CMVideoFormatDescription?
    /// PiP frames are at most this wide: the floating window never needs more.
    static let maxWidth: UInt32 = 960
    /// Frames enqueued since start, for the CPU measurement log.
    private(set) var frames = 0

    func start() {
        queue.async { [self] in
            timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            lastPts = nil
        }
    }

    /// One still frame (`nil`: black 16:9), for PiP to open on.
    func enqueueStill(_ image: CGImage?) {
        queue.async { [self] in
            guard let layer else { return }
            let (w, h) = image.map { ($0.width, $0.height) } ?? (160, 90)
            var data = Data([UInt8](repeating: 0, count: w * h * 4).enumerated().map { $0.offset % 4 == 3 ? 255 : 0 })
            if let image {
                data.withUnsafeMutableBytes { buf in
                    let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                    ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
            }
            guard let sb = sampleBuffer(PipFrameData(pts: 0, width: w, height: h, bgra: data)) else { return }
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sb)
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            lastPts = nil
        }
    }

    private func tick() {
        guard let engine, let layer else { return }
        guard let f = engine.pipFrame(maxWidth: Self.maxWidth, unlessAt: lastPts) else { return }
        lastPts = f.pts
        guard let sb = sampleBuffer(f) else { return }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sb)
        frames += 1
    }

    private func sampleBuffer(_ f: PipFrameData) -> CMSampleBuffer? {
        if pool == nil || poolSize != (f.width, f.height) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: f.width,
                kCVPixelBufferHeightKey as String: f.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &p)
            pool = p
            poolSize = (f.width, f.height)
            format = nil
        }
        guard let pool else { return nil }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let dst = CVPixelBufferGetBaseAddress(pb) {
            let dstStride = CVPixelBufferGetBytesPerRow(pb)
            let row = f.width * 4
            f.bgra.withUnsafeBytes { src in
                guard let s = src.baseAddress, src.count >= row * f.height else { return }
                if dstStride == row {
                    memcpy(dst, s, row * f.height)
                } else {
                    for y in 0..<f.height { memcpy(dst + y * dstStride, s + y * row, row) }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        if format == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &format)
        }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: f.pts, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return nil }
        // Shown the moment it is enqueued: mpv has already timed it against the sound.
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}
