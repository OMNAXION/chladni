// Friendly error sentences: the iOS port of the desktop's `ui/src/lib/neterr.ts` (lane magic-d1,
// MAGIC-GAPS #21). Spotify never shows an exception ("Couldn't start radio. Try again."), but the raw
// text still matters for a bug report, so it goes to the unified log and the diagnostics file
// (`Caches/Encore/audio.log`). Keep the wording and the patterns in step with `neterr.ts`:
// `FriendlyErrorTests` replays `neterr.check.ts`.
//
// The one call for everyone: `friendlyError(error, "Couldn't start radio")`. A store action that
// failed goes through `CoreActions.run`, which also reverts the optimistic UI and toasts.
import Foundation
import os

let errorLog = Logger(subsystem: "studio.chladni.ios", category: "error")

enum FriendlyError {
    /// Plain-language wording for each failure family (`DEFAULT_ERROR_WORDS` on the desktop).
    struct Words: Equatable {
        var unreachable = "Can't reach YouTube Music. Check your connection."
        var rateLimited = "YouTube is busy right now. Try again in a moment."
        var signIn = "Sign in to do that."
        var forbidden = "YouTube didn't allow that."
        var notFound = "That isn't available any more."
        /// The fallback when nothing better fits. A caller's own `context` beats it.
        var generic = "Something went wrong. Try again."
    }
    static let words = Words()

    private static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Constant patterns: a typo is a programmer error caught by the tests.
        try! NSRegularExpression(pattern: p, options: o)
    }
    private static func test(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// What a dead connection looks like by the time it reaches here (reqwest, rustypipe, the
    /// loopback proxy, mpv and the orchestrator's own `Unreachable`).
    private static let unreachable = re(
        #"(?:\b(?:http|json): )?(?:error sending request|request or response body error|error trying to connect|dns error|failed to lookup address|connection (?:refused|reset|closed)|network is unreachable|no route to host|operation timed out|could not reach YouTube)"#,
        .caseInsensitive)
    /// Things only a program says (case-sensitive, like the desktop's).
    private static let technical = re(
        #"(?:\b[A-Z][a-zA-Z]*Error\b|\bError:|\berror:|\bexception\b|\bpanicked\b|::|=>|\{|\}|\[object |\bundefined\b|\bnull\b|\bNaN\b|\bhttps?://|\bstatus(?: code)? \d{3}\b|\bHTTP \d{3}\b|\b[45]\d\d\b|\bjson\b|\bserde\b|\binvalid type\b|\bmissing field\b|\bunknown variant\b|\bexpected\b.*\bat line\b|\bstructuredClone\b|\bfailed to (?:execute|parse|deserialize|decode)\b|\bcommand \w+ not found\b|\bPOST\b|\bGET\b)"#)
    private static let rateLimited = re(#"\b429\b|too many requests|rate.?limit"#, .caseInsensitive)
    private static let needsSignIn = re(#"\b401\b|sign.?in required|login required|not signed in|unauthori[sz]ed"#, .caseInsensitive)
    private static let forbidden = re(#"\b403\b|forbidden|permission denied"#, .caseInsensitive)
    private static let notFound = re(#"\b404\b|not found|no longer available|unavailable"#, .caseInsensitive)
    private static let startsLikeSentence = re(#"^[A-Z“"'‘]"#)
    private static let endsLikeSentence = re(#"[.!?…)”"']$"#)

    /// Is this error the network rather than the request?
    static func isUnreachable(_ raw: String) -> Bool { test(unreachable, raw) }

    /// Already a sentence for a person: short, starts with a capital, ends in a full stop, no code.
    static func looksFriendly(_ msg: String) -> Bool {
        let m = msg.trimmingCharacters(in: .whitespacesAndNewlines)
        return !m.isEmpty && m.count <= 140 && test(startsLikeSentence, m) && test(endsLikeSentence, m) && !test(technical, m)
    }

    /// Any thrown value as text: the core's own message, a string, or "Type: description".
    static func raw(_ e: Any) -> String {
        switch e {
        case let f as CoreFailure: return f.message
        case let s as String: return s
        case let s as Substring: return String(s)
        case let err as Error: return "\(String(describing: type(of: err))): \(String(describing: err))"
        default: return String(describing: e)
        }
    }

    /// The sentence to show for `e`. A message that is already friendly passes through (the core's
    /// own "This album has no radio." is), a known failure family gets its sentence, and anything
    /// else becomes `context` ("Couldn't start radio.") plus "Try again.", or the generic sentence.
    static func message(_ e: Any, context: String? = nil, words: Words = words) -> String {
        let raw = raw(e)
        if isUnreachable(raw) { return words.unreachable }
        // Only words someone wrote pass through (the core's message, a string): a Swift error's
        // "Type: description" can look like a sentence without being one.
        if isText(e), looksFriendly(raw) { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        if test(rateLimited, raw) { return words.rateLimited }
        if test(needsSignIn, raw) { return words.signIn }
        if test(forbidden, raw) { return words.forbidden }
        if test(notFound, raw) && context == nil { return words.notFound }
        if var c = context?.trimmingCharacters(in: .whitespaces), !c.isEmpty {
            if c.hasSuffix(".") || c.hasSuffix("!") { c.removeLast() }
            return "\(c). Try again."
        }
        return words.generic
    }

    private static func isText(_ e: Any) -> Bool { e is String || e is Substring || e is CoreFailure }

    /// A cancelled task (a page closed mid-load) is not a failure anyone should hear about.
    static func isCancellation(_ e: Error) -> Bool {
        e is CancellationError || (e as? URLError)?.code == .cancelled
    }
}

/// The friendly sentence for `error`, with the raw text logged when it was rewritten (the
/// desktop's `toast.fail(e, context)` minus the toast). Use it for every error a person sees.
func friendlyError(_ error: Any, _ context: String? = nil) -> String {
    let raw = FriendlyError.raw(error)
    let out = FriendlyError.message(error, context: context)
    if out != raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        errorLog.error("\(context ?? "error", privacy: .public): \(raw, privacy: .public)")
        AudioTraceFile.append("ERROR \(context ?? "error"): \(raw)")
    }
    return out
}

// MARK: store actions

/// Test-only failure injection, honoured by the mock core alone (the real core ignores it): unit
/// tests set `failing`, UI tests pass `-fail like,addToPlaylist` (or `*` for everything).
enum CoreFaults {
    nonisolated(unsafe) static var failing: Set<String> = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-fail"), a.indices.contains(i + 1) else { return [] }
        return Set(a[i + 1].split(separator: ",").map(String.init))
    }()

    static func check(_ action: String, _ core: CoreClient) throws {
        guard core is MockCoreClient, failing.contains(action) || failing.contains("*") else { return }
        throw CoreFailure(message: "http: HTTP status server error (500 Internal Server Error) for \(action)")
    }
}

/// How a store runs one user action on the core. On failure the optimistic UI is reverted, the
/// raw error is logged and a friendly sentence is reported (`AppModel` toasts it with the error
/// buzz). Never a silent `try?` for something a person did.
@MainActor
final class CoreActions {
    let core: CoreClient
    /// Where failure sentences go; `AppModel` points it at its toast.
    var report: (String) -> Void = { _ in }
    /// The latest action, for tests to await.
    private(set) var last: Task<Bool, Never>?

    init(core: CoreClient) { self.core = core }

    /// Runs `op`; returns the error (nil on success). No revert, no report.
    func attempt(_ action: String, _ op: () async throws -> Void) async -> Error? {
        do { try CoreFaults.check(action, core); try await op(); return nil } catch { return error }
    }

    /// Runs `op` in the background; on failure `revert()`, then report `friendlyError(e, context)`.
    @discardableResult
    func run(_ action: String, _ context: String, revert: (@MainActor () -> Void)? = nil,
             _ op: @escaping @MainActor () async throws -> Void) -> Task<Bool, Never> {
        let t = Task { @MainActor in await self.perform(action, context, revert: revert, op) }
        last = t
        return t
    }

    /// The same, awaited in place: true on success.
    func perform(_ action: String, _ context: String, revert: (@MainActor () -> Void)? = nil,
                 _ op: @MainActor () async throws -> Void) async -> Bool {
        guard let e = await attempt(action, op) else { return true }
        revert?()
        if FriendlyError.isCancellation(e) { return false }
        report(friendlyError(e, context))
        return false
    }
}
