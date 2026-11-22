// Device sync on the iPhone: the wording and logic (pure), the store's linking flow on the mock
// core, and the `sync-changed` event.
import XCTest
@testable import Encore

final class DeviceSyncTextTests: XCTestCase {
    func testErrorsInPlainWords() {
        XCTAssertEqual(PairingError.from("wrong_code:2").message, "That code didn't match. 2 tries left.")
        XCTAssertEqual(PairingError.from("wrong_code:1").message, "That code didn't match. 1 try left.")
        XCTAssertEqual(PairingError.from("wrong_code:0").kind, .lastTry)
        XCTAssertEqual(PairingError.from("wrong_code:0").message,
                       "That code didn't match, and that was the last try. Show a new code on your other device.")
        XCTAssertEqual(PairingError.from("wrong_code").message, "That code didn't match.")
        XCTAssertEqual(PairingError.from("not_pairing").message, "This code has expired. Show a new code on your other device.")
        XCTAssertEqual(PairingError.from("bad_code").message, "Enter all 6 digits.")
        for raw in ["no_host", "connect timeout", "timeout", "closed", "Connection refused (os error 61)", "Host is down (os error 64)",
                    "Network is unreachable (os error 51)", "Operation timed out (os error 60)"] {
            XCTAssertEqual(PairingError.from(raw), .unreachable, raw)
            XCTAssertEqual(PairingError.from(raw).message, "Your devices can't see each other. Make sure both are on the same Wi-Fi.")
        }
        XCTAssertEqual(PairingError.from("No route to host (os error 65)"), .localNetwork)
        XCTAssertEqual(PairingError.localNetwork.message,
                       "Chladni can't reach your local network. Allow it in Settings › Chladni › Local Network.")
        XCTAssertEqual(PairingError.from("bad_key").message, "Couldn't link your devices. Try again.")
    }

    func testRelativeTime() {
        XCTAssertEqual(DeviceSyncText.ago(0), "just now")
        XCTAssertEqual(DeviceSyncText.ago(59), "just now")
        XCTAssertEqual(DeviceSyncText.ago(60), "1 min ago")
        XCTAssertEqual(DeviceSyncText.ago(150), "2 min ago")
        XCTAssertEqual(DeviceSyncText.ago(3600), "1 h ago")
        XCTAssertEqual(DeviceSyncText.ago(86399), "23 h ago")
        XCTAssertEqual(DeviceSyncText.ago(86400), "1 day ago")
        XCTAssertEqual(DeviceSyncText.ago(3 * 86400 + 5), "3 days ago")
        XCTAssertEqual(DeviceSyncText.ago(-20), "just now", "a clock a little ahead")
    }

    func testCountdownAndCode() {
        XCTAssertEqual(DeviceSyncText.countdown(300), "5:00")
        XCTAssertEqual(DeviceSyncText.countdown(299), "4:59")
        XCTAssertEqual(DeviceSyncText.countdown(298.4), "4:59", "rounds up: never shows 0:00 while time is left")
        XCTAssertEqual(DeviceSyncText.countdown(9), "0:09")
        XCTAssertEqual(DeviceSyncText.countdown(-3), "0:00")
        XCTAssertEqual(DeviceSyncText.code("482913"), "482 913")
        XCTAssertEqual(DeviceSyncText.code("48"), "48")
    }

    func testStatusLines() {
        var s = SyncStatus.unlinked
        XCTAssertEqual(DeviceSyncText.title(s), "Not linked")
        s.paired = true
        s.peers = [SyncPeer(id: "a", name: "MacBook Pro", platform: "mac", lastSeen: 0, lan: true)]
        XCTAssertEqual(DeviceSyncText.title(s), "Linked with MacBook Pro")
        XCTAssertEqual(DeviceSyncText.statusLine(s, now: 1000), "Waiting for connection", "never synced yet")
        s.lastSync = 880
        XCTAssertEqual(DeviceSyncText.statusLine(s, now: 1000), "Synced 2 min ago")
        s.syncing = true
        XCTAssertEqual(DeviceSyncText.statusLine(s, now: 1000), "Syncing…")
        s.syncing = false
        s.lastError = "relay: timeout"
        XCTAssertEqual(DeviceSyncText.statusLine(s, now: 1000), "Waiting for connection")
        XCTAssertNil(DeviceSyncText.pending(0))
        XCTAssertEqual(DeviceSyncText.pending(1), "1 change waiting to sync")
        XCTAssertEqual(DeviceSyncText.pending(12), "12 changes waiting to sync")
        XCTAssertEqual(DeviceSyncText.names(["A"]), "A")
        XCTAssertEqual(DeviceSyncText.names(["A", "B"]), "A and B")
        XCTAssertEqual(DeviceSyncText.names(["A", "B", "C", "D"]), "A, B and 2 more")
        XCTAssertEqual(DeviceSyncText.unlinkTitle(s.peers), "Unlink MacBook Pro?")
        XCTAssertEqual(DeviceSyncText.unlinkTitle([]), "Unlink this device?")
        XCTAssertEqual(DeviceSyncText.menuTitle(paired: false), "Link your Mac")
        XCTAssertEqual(DeviceSyncText.menuTitle(paired: true), "Linked devices")
    }

    func testCodeEntry() {
        XCTAssertEqual(CodeEntry.read("48").digits, "48")
        XCTAssertEqual(CodeEntry.read("482 913").digits, "482913", "a pasted code with its space")
        XCTAssertEqual(CodeEntry.read("4829135").digits, "482913", "at most six")
        XCTAssertEqual(CodeEntry.read("a4b8").digits, "48")
        XCTAssertNil(CodeEntry.read("482913").qr)
        let link = "Link: chladni://pair?v=1&code=123456&addr=10.0.0.2%3A47615&dev=x&name=Mac thanks"
        let r = CodeEntry.read(link)
        XCTAssertEqual(r.qr, "chladni://pair?v=1&code=123456&addr=10.0.0.2%3A47615&dev=x&name=Mac")
        XCTAssertEqual(r.digits, "123456")
        XCTAssertEqual(CodeEntry.pairLink(in: "encore://pair?v=1&code=111111"), "chladni://pair?v=1&code=111111")
        XCTAssertNil(CodeEntry.pairLink(in: "chladni://track/abc"))
    }

    func testSyncChangedEvent() throws {
        var s = SyncStatus.unlinked
        s.paired = true
        s.pending = 4
        struct P: Encodable { var status: SyncStatus; var entities: [String] }
        let json = try JSONEncoder().encode(P(status: s, entities: ["liked_songs"]))
        guard case .syncChanged(let got) = CoreEvent.decode(name: "sync-changed", json: json) else { return XCTFail("not decoded") }
        XCTAssertEqual(got, s)
        // The core's own JSON (docs/SYNC.md §7), nulls and all.
        let core = #"{"status":{"paired":false,"deviceId":"d","deviceName":"iPhone","platform":"ios","pairId":null,"peers":[],"pending":0,"lastSync":null,"lastError":null,"relay":{"enabled":true,"ok":null},"lanPort":null,"pairing":{"code":"123456","qr":"chladni://pair?v=1","expiresAt":1700000300},"syncing":false,"active":true},"entities":[]}"#
        guard case .syncChanged(let c) = CoreEvent.decode(name: "sync-changed", json: Data(core.utf8)) else { return XCTFail("core JSON") }
        XCTAssertEqual(c.pairing?.code, "123456")
    }
}

@MainActor
final class DeviceSyncStoreTests: XCTestCase {
    var mock: MockCoreClient!
    var app: AppModel!

    override func setUp() async throws {
        mock = MockCoreClient(bundle: Bundle(for: AppModel.self))
        app = AppModel(core: mock)
        app.devices.discoveryTries = 0
        await app.devices.refresh()
    }

    private func settle(_ ms: Int = 150) async { try? await Task.sleep(for: .milliseconds(ms)) }

    func testJoinWithACodeLinks() async {
        let d = app.devices
        d.open(.enterCode)
        d.typed("4829")
        XCTAssertEqual(d.digits, "4829")
        d.typed("482913") // the sixth digit joins by itself
        await settle(300)
        XCTAssertEqual(d.step, .success)
        XCTAssertTrue(d.paired)
        XCTAssertEqual(DeviceSyncText.title(d.status), "Linked with MacBook Pro")
    }

    func testWrongCodeSaysTriesLeft() async {
        let d = app.devices
        d.open(.enterCode)
        d.typed("000000")
        await settle(300)
        XCTAssertEqual(d.step, .enterCode)
        XCTAssertEqual(d.error?.message, "That code didn't match. 2 tries left.")
        XCTAssertEqual(d.digits, "", "cleared for the next try")
        d.typed("1")
        XCTAssertNil(d.error, "typing again clears the error")
    }

    func testUnreachableKeepsTheCode() async {
        let d = app.devices
        mock.withLock { mock.sync.joinError = "no_host" }
        d.open(.enterCode)
        d.typed("482913")
        await settle(300)
        XCTAssertEqual(d.error, .unreachable)
        XCTAssertEqual(d.digits, "482913")
    }

    func testPairLinkJoins() async {
        app.router.handle(URL(string: MockSyncState.qr)!, app: app)
        await settle(300)
        XCTAssertTrue(app.devices.sheetOpen)
        XCTAssertEqual(app.devices.step, .success)
    }

    func testShowCodeThenTheOtherDeviceJoins() async {
        let d = app.devices
        d.open(.showCode)
        await settle(300)
        XCTAssertEqual(d.shown?.code, MockSyncState.code)
        mock.mockSyncJoinedByPeer()
        await settle()
        XCTAssertEqual(d.step, .success)
    }

    func testShowCodeLastWrongTryEndsIt() async {
        let d = app.devices
        d.open(.showCode)
        await settle(300)
        mock.mockSyncCodeWithdrawn()
        await settle()
        XCTAssertEqual(d.step, .showCode)
        XCTAssertEqual(d.codeEnd, .tooManyTries)
    }

    func testCancelWithdrawsTheCode() async {
        let d = app.devices
        d.open(.showCode)
        await settle(300)
        d.go(.intro)
        await settle()
        XCTAssertNil(mock.withLock { mock.sync.status.pairing })
    }

    func testUnlinkAndSyncNow() async {
        mock.mockSyncLink(pending: 3, error: "relay: timeout")
        await app.devices.refresh()
        XCTAssertEqual(DeviceSyncText.pending(app.devices.status.pending), "3 changes waiting to sync")
        app.devices.syncNow()
        await settle()
        XCTAssertNil(app.devices.status.lastError)
        app.devices.unlink()
        await settle()
        XCTAssertFalse(app.devices.paired)
    }

    func testHintOnlyAfterThreeDaysAndOnce() {
        let suite = "sync-hint-\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        XCTAssertFalse(DeviceSyncStore(core: mock, prefs: prefs).showsHint, "first day")
        prefs.set(Date().timeIntervalSince1970 - 3 * 86400 - 60, forKey: "sync_first_use")
        let d = DeviceSyncStore(core: mock, prefs: prefs)
        XCTAssertTrue(d.showsHint)
        d.hintAppeared()
        XCTAssertTrue(d.showsHint, "stays for this session")
        XCTAssertFalse(DeviceSyncStore(core: mock, prefs: prefs).showsHint, "never again after a relaunch")
        d.dismissHint()
        XCTAssertFalse(d.showsHint)
    }

    func testWelcomeFollowsTheFirstRunImportOnce() async {
        let suite = "sync-welcome-\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let d = DeviceSyncStore(core: mock, prefs: prefs)
        d.importClosed()
        await settle(600)
        XCTAssertFalse(d.welcomeOpen, "only after the first-run offer")
        d.welcomePending = true
        d.importClosed()
        await settle(600)
        XCTAssertTrue(d.welcomeOpen)
        d.welcomeOpen = false
        d.welcomePending = true
        d.importClosed()
        await settle(600)
        XCTAssertFalse(d.welcomeOpen, "once")
    }
}
