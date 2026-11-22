// stream: instant. A main-thread watchdog for the e2e runs (`-e2e YES`) and Debug: a background
// thread pings the main queue every 20 ms and records every ping that took over 50 ms to answer,
// a stall in which taps and swipes queue up or get dropped. The probe reports the count and the
// worst one; each stall is logged (`HANG <ms>`, also in Caches/Encore/audio.log) to line it up
// with a Time Profiler trace and the playback trace.
import Foundation
import os

final class HangWatch: @unchecked Sendable {
    static let shared = HangWatch()
    private let lock = NSLock()
    private var stalls: [Double] = []
    private var started = false
    private let log = Logger(subsystem: "studio.chladni.ios", category: "hang")

    /// Stalls over 50 ms since launch: (count, worst ms).
    var summary: (count: Int, worstMs: Int) {
        lock.lock(); defer { lock.unlock() }
        return (stalls.count, Int(stalls.max() ?? 0))
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        let t = Thread { [self] in loop() }
        t.qualityOfService = .userInteractive
        t.name = "hang-watch"
        t.start()
    }

    private func loop() {
        while true {
            let sent = DispatchTime.now().uptimeNanoseconds
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { answered.signal() }
            answered.wait()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e6
            if ms > 50 {
                lock.lock(); stalls.append(ms); lock.unlock()
                log.error("HANG \(Int(ms), privacy: .public) ms")
                print("HANG \(Int(ms)) ms")
                AudioTraceFile.append("HANG \(Int(ms)) ms") // next to the playback trace, on device
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}
