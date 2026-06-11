import Foundation
import Security
import os

/// Release-visible diagnostic channel. View with:
/// `log stream --predicate 'subsystem == "com.claude.usage-menu"'` or in Console.app.
/// Lets a periodic "Keychain"/"stale" event be explained from the exact OSStatus /
/// HTTP code without shipping a debug build.
private let diag = Logger(subsystem: "com.claude.usage-menu", category: "usage")

// MARK: - OAuth Keychain

private struct KeychainCredentials: Decodable {
    let claudeAiOauth: OAuthData

    struct OAuthData: Decodable {
        let accessToken: String
        let expiresAt: Double
    }
}

/// A token read from the Claude Code Keychain entry, with its expiry (if known).
struct OAuthToken {
    let accessToken: String
    let expiresAt: Date?
}

/// Interprets the Keychain `expires_at` value, which Claude Code stores as a
/// Unix timestamp. Older builds used seconds, current ones use milliseconds —
/// disambiguate by magnitude so both keep working.
func oauthExpiryDate(fromRawExpiresAt raw: Double) -> Date? {
    guard raw > 0 else { return nil }
    let seconds = raw > 1_000_000_000_000 ? raw / 1000 : raw   // > ~year 33000 in s ⇒ it's ms
    return Date(timeIntervalSince1970: seconds)
}

/// Parses `security find-generic-password -w` output — the credential JSON plus
/// a trailing newline — into a token. Returns nil on any malformed payload so
/// the caller can fall back to the direct framework read.
func oauthTokenFromSecurityCLIOutput(_ data: Data) -> OAuthToken? {
    var trimmed = data
    while let last = trimmed.last, last == 0x0A || last == 0x0D { trimmed.removeLast() }
    guard !trimmed.isEmpty,
          let creds = try? JSONDecoder().decode(KeychainCredentials.self, from: trimmed) else {
        return nil
    }
    return OAuthToken(
        accessToken: creds.claudeAiOauth.accessToken,
        expiresAt: oauthExpiryDate(fromRawExpiresAt: creds.claudeAiOauth.expiresAt)
    )
}

/// Reads the credential by spawning `/usr/bin/security find-generic-password -w`.
///
/// Claude Code writes the keychain item through that same `security` binary, so
/// `/usr/bin/security` stays on the item's ACL across Claude Code's ~8h token
/// rotation — unlike this app's "Always Allow" grant, which every rotation wipes
/// (the cause of the periodic "Keychain" interruption). Reading through the same
/// binary therefore succeeds silently, every time, with no access prompt.
/// (Approach validated against steipete/CodexBar's security-CLI reader.)
///
/// Returns nil on any failure (launch error, non-zero exit, timeout, bad JSON);
/// the caller then falls back to the direct framework read. The bounded wait
/// guards the one pathological case — `security` blocking on a SecurityAgent
/// prompt because the binary is unexpectedly NOT trusted for the item — so a
/// background poll can never hang on an unshowable dialog.
private func readOAuthTokenViaSecurityCLI(timeout: TimeInterval = 2.0) -> OAuthToken? {
    let binary = "/usr/bin/security"
    guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = Pipe()   // swallow; the exit code is diagnostic enough

    do {
        try process.run()
    } catch {
        diag.notice("security CLI launch failed: \(error.localizedDescription, privacy: .public)")
        return nil
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
        process.terminate()
        let killDeadline = Date().addingTimeInterval(0.3)
        while process.isRunning && Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        diag.notice("security CLI read timed out — falling back to framework read")
        return nil
    }

    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        // e.g. 44 = item not found; the framework fallback turns that into the
        // proper "not signed in" error, so no classification is needed here.
        diag.notice("security CLI exited \(process.terminationStatus)")
        return nil
    }
    return oauthTokenFromSecurityCLIOutput(data)
}

/// Reads the Claude Code OAuth token from the Keychain.
///
/// Primary path is the `security`-CLI read (see above), which survives Claude
/// Code's token rotation without prompts. Only when that fails does the direct
/// `SecItemCopyMatching` read below run, with the original interaction rules:
///
/// `allowInteraction` decides whether macOS may present the access-confirmation
/// dialog. Background polls pass `false`: Claude Code's ~8h token rotation resets
/// the item's ACL, and a *blocking* interactive read fired from the timer's
/// background Task — while this `LSUIElement` accessory app is inactive — both (a)
/// often fails to surface the SecurityAgent dialog and (b) stalls the single-flight
/// guard, wedging every later refresh into a no-op. With interaction suppressed the
/// read instead returns `errSecInteractionNotAllowed` immediately, which we map to
/// an actionable "Keychain" state. The interactive read then happens only on an
/// explicit user action, with the app activated, so the dialog reliably appears.
func readOAuthToken(allowInteraction: Bool) throws -> OAuthToken {
    if let token = readOAuthTokenViaSecurityCLI() {
        return token
    }

    // `SecKeychainSetUserInteractionAllowed` is a process-global toggle that the
    // legacy file-based keychain (where this generic-password credential lives)
    // honors for the ACL-confirmation dialog — unlike the modern
    // `kSecUseAuthenticationUI` options, which only govern access-control UI.
    // Set it explicitly each read rather than trusting the ambient default, and
    // restore it to allowed afterwards so a later interactive read can prompt.
    // Deprecated alongside the whole SecKeychain family, but with no non-deprecated
    // replacement for this toggle — keep it; the deprecation warning is expected.
    SecKeychainSetUserInteractionAllowed(allowInteraction)
    defer { if !allowInteraction { SecKeychainSetUserInteractionAllowed(true) } }

    var result: AnyObject?
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else {
        throw NSError(domain: "Keychain", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "Claude Code credentials not found in Keychain. Make sure Claude Code is installed and logged in."])
    }
    let creds = try JSONDecoder().decode(KeychainCredentials.self, from: data)
    return OAuthToken(
        accessToken: creds.claudeAiOauth.accessToken,
        expiresAt: oauthExpiryDate(fromRawExpiresAt: creds.claudeAiOauth.expiresAt)
    )
}

// MARK: - Keychain status classification (pure, testable)

/// Why a Keychain read failed. Distinguishing these matters: a denied/cancelled
/// access prompt (or an ACL that Claude Code's token rotation reset) is NOT a
/// sign-out — Claude Code is still logged in and one "Always Allow" click fixes
/// it — so it must not be surfaced like a missing credential.
enum KeychainAccessIssue: Equatable {
    case notSignedIn          // the credential genuinely isn't there
    case accessDenied         // an access prompt was denied/dismissed
    case interactionRequired  // a non-interactive read hit a reset ACL (or a locked
                              // keychain): a grant/prompt is needed, available on
                              // the next user-activated interactive read
    case other
}

func classifyKeychainStatus(_ status: OSStatus) -> KeychainAccessIssue {
    switch status {
    case errSecItemNotFound:
        return .notSignedIn
    case errSecUserCanceled, errSecAuthFailed:
        return .accessDenied
    case errSecInteractionNotAllowed:
        return .interactionRequired
    default:
        return .other
    }
}

// MARK: - ISO8601 parsing (robust to missing fractional seconds)

private let iso8601WithFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let iso8601NoFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// Parses an ISO-8601 timestamp whether or not it carries fractional seconds.
/// `ISO8601DateFormatter` with `.withFractionalSeconds` rejects timestamps
/// without them (and vice-versa), so we try both forms.
func parseISO8601Date(_ string: String) -> Date? {
    iso8601WithFraction.date(from: string) ?? iso8601NoFraction.date(from: string)
}

// MARK: - API Response Model

struct OAuthUsageResponse: Decodable {
    let fiveHour: UsagePeriod?
    let sevenDay: UsagePeriod?
    let sevenDaySonnet: UsagePeriod?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
    }

    struct UsagePeriod: Decodable {
        let utilization: Double
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        var resetsAtDate: Date? {
            guard let resetsAt else { return nil }
            return parseISO8601Date(resetsAt)
        }
    }
}

// MARK: - Utilization helpers (pure, testable)

/// Formats a future date as a human-readable countdown string.
func formatTimeRemaining(until date: Date, from now: Date = Date()) -> String {
    let interval = date.timeIntervalSince(now)
    if interval <= 0 { return "now" }
    let days = Int(interval) / 86_400
    let hours = (Int(interval) % 86_400) / 3600
    let minutes = (Int(interval) % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
}

/// Caption for a reset time. Avoids the ungrammatical "resets in now" when the
/// window is at or just past its reset boundary.
func resetCaption(until date: Date, from now: Date = Date()) -> String {
    date.timeIntervalSince(now) <= 0
        ? "resetting now"
        : "resets in \(formatTimeRemaining(until: date, from: now))"
}

// MARK: - Auth state

/// Whether the Claude Code credential is usable, surfaced in Settings so the
/// "Auth" row reflects reality instead of an always-green placeholder. Only the
/// definitive auth outcomes flip this — transient network/server errors leave it
/// untouched so a flaky connection doesn't masquerade as a sign-in problem.
enum AuthState: Equatable {
    case unknown
    case ok
    case signedOut
    case expired
}

// MARK: - UsageService

final class UsageService: ObservableObject {
    static let shared = UsageService()

    @Published private(set) var currentUsage: UsageSnapshot = .placeholder
    @Published private(set) var error: String?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var authState: AuthState = .unknown
    /// True when the last refresh failed because macOS gated the Keychain read
    /// (a denied/cancelled prompt, or an ACL revoked by Claude Code's token
    /// rotation). Distinct from a sign-out and recoverable with one click, so
    /// the menu bar surfaces it as an actionable "Keychain" state, not "stale".
    @Published private(set) var needsKeychainAccess: Bool = false

    private var refreshTimer: Timer?
    private let normalInterval: TimeInterval = 5 * 60    // 5 minutes
    private let backoffInterval: TimeInterval = 15 * 60  // 15 minutes after 429
    private var failureCount = 0

    /// Single-flight guard. Only ever touched on the main thread (all callers
    /// of `fetchUsage()` run on the main run loop), so no lock is needed.
    private var isFetching = false

    // Injectable for testing. Defaults to a session with a bounded end-to-end
    // (resource) timeout so a slow or stalled connection can't keep the fetch
    // pending indefinitely and wedge polling — `timeoutIntervalForRequest`
    // alone only bounds per-byte inactivity, not the whole request.
    var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // Token cache — guarded by `tokenLock` because it is read on the network
    // Task's background thread but cleared from the main thread on auth errors.
    private let tokenLock = NSLock()
    private var cachedToken: String?
    private var tokenExpiresAt: Date?

    private init() {}

    /// Returns a valid access token, re-reading the Keychain when the cache is
    /// empty or the token is within 60s of expiry (so a freshly refreshed
    /// Claude Code credential is picked up without an app restart).
    ///
    /// `allowInteraction` is forwarded to the Keychain read: background polls pass
    /// `false` so a reset ACL surfaces as a non-blocking "needs access" status
    /// instead of stalling on an unshowable prompt. `force` bypasses the cache so
    /// an explicit user refresh always re-reads the (possibly rotated) credential.
    private func accessToken(allowInteraction: Bool, force: Bool) throws -> String {
        if !force {
            tokenLock.lock()
            if let token = cachedToken {
                // Re-read only when we KNOW the token is within 60s of expiry.
                // Unknown expiry ⇒ keep serving the cached token (it is still
                // cleared on 401/403/429), so we don't hit the Keychain every poll.
                let nearExpiry = tokenExpiresAt.map { Date() >= $0.addingTimeInterval(-60) } ?? false
                if !nearExpiry {
                    tokenLock.unlock()
                    return token
                }
            }
            tokenLock.unlock()
        }

        // Read the Keychain outside the lock (it can block), then store.
        let creds = try readOAuthToken(allowInteraction: allowInteraction)
        tokenLock.lock()
        cachedToken = creds.accessToken
        tokenExpiresAt = creds.expiresAt
        tokenLock.unlock()
        return creds.accessToken
    }

    private func clearToken() {
        tokenLock.lock()
        cachedToken = nil
        tokenExpiresAt = nil
        tokenLock.unlock()
    }

    func startPolling() {
        fetchUsage()
    }

    func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func scheduleTimer(interval: TimeInterval) {
        refreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fetchUsage()
        }
        // Polling has no precision requirement — let the system coalesce the
        // wakeup with others to save energy in this always-running app.
        timer.tolerance = interval * 0.1
        refreshTimer = timer
    }

    /// `forceInteractive` marks an explicit user action (icon click / Refresh):
    /// the app has been activated, so we both allow the Keychain access dialog and
    /// bypass the token cache to re-read a rotated credential. Automatic polls pass
    /// `false`, keeping the Keychain read non-blocking and prompt-free.
    func fetchUsage(forceInteractive: Bool = false) {
        guard !isFetching else { return }   // main-thread single-flight
        isFetching = true
        isLoading = true

        Task {
            do {
                let token = try self.accessToken(allowInteraction: forceInteractive, force: forceInteractive)
                let response = try await self.fetchOAuthUsage(accessToken: token)

                let snapshot = UsageSnapshot(
                    fiveHourUtilization: Int(response.fiveHour?.utilization ?? 0),
                    sevenDayUtilization: Int(response.sevenDay?.utilization ?? 0),
                    sevenDaySonnetUtilization: response.sevenDaySonnet.map { Int($0.utilization) },
                    fiveHourResetAt: response.fiveHour?.resetsAtDate,
                    sevenDayResetAt: response.sevenDay?.resetsAtDate,
                    lastUpdated: Date(),
                    // A response with every period null carries no usable numbers;
                    // keep showing "—" rather than presenting a fabricated 0%.
                    hasData: response.fiveHour != nil || response.sevenDay != nil
                )

                await MainActor.run {
                    self.currentUsage = snapshot
                    self.error = nil
                    self.needsKeychainAccess = false
                    self.authState = .ok
                    self.failureCount = 0
                    self.isLoading = false
                    self.isFetching = false
                    self.scheduleTimer(interval: self.normalInterval)
                }
            } catch let error as NSError {
                await MainActor.run {
                    self.handleFailure(error)
                    self.isLoading = false
                    self.isFetching = false
                }
            }
        }
    }

    /// Maps a failure to a user-facing message and the next poll interval.
    /// Runs on the main thread (called inside `MainActor.run`).
    private func handleFailure(_ error: NSError) {
        let isOAuthHTTP = error.domain == "OAuthUsage"

        // Diagnostic ground truth for the periodic "Keychain"/"stale" event: the
        // exact failure domain+code plus where the cached token's expiry sits
        // relative to now (the ~8h rotation boundary). Captured in release builds.
        tokenLock.lock()
        let exp = tokenExpiresAt
        tokenLock.unlock()
        let expDesc = exp.map { "token exp in \(Int($0.timeIntervalSinceNow))s" } ?? "token exp unknown"
        diag.notice("fetch failed: \(error.domain, privacy: .public) code=\(error.code) — \(expDesc, privacy: .public)")

        if isOAuthHTTP && error.code == 429 {
            // A 429 is rate limiting, not an auth problem — the cached token is
            // fine. Don't clear it: a needless re-read can pop a Keychain prompt
            // (the ACL is reset on Claude Code's token rotation) for nothing.
            needsKeychainAccess = false
            self.error = "Rate limited — retrying in 15 min"
            scheduleTimer(interval: backoffInterval)
            return
        }

        if isOAuthHTTP && (error.code == 401 || error.code == 403) {
            // Token expired/revoked: drop the cache so the next poll re-reads
            // the (refreshed) Keychain credential.
            clearToken()
            needsKeychainAccess = false
            authState = .expired
            self.error = "Sign-in expired — re-reading Claude Code credentials"
            scheduleTimer(interval: normalInterval)
            return
        }

        if error.domain == "Keychain" {
            switch classifyKeychainStatus(OSStatus(error.code)) {
            case .notSignedIn:
                needsKeychainAccess = false
                authState = .signedOut
                failureCount += 1
                self.error = "Claude Code not signed in — open Claude Code and log in"
                scheduleTimer(interval: retryInterval())
            case .accessDenied, .interactionRequired:
                // Claude Code IS signed in; macOS just gated this read — the ACL
                // that Claude Code's ~8h token rotation resets, or a denied prompt.
                // Flag it as an actionable Keychain state (not a sign-out): a click
                // on the icon activates the app and re-reads interactively, so the
                // "Always Allow" dialog reliably appears. Back off to the normal
                // interval so background polls don't thrash while it's pending.
                needsKeychainAccess = true
                self.error = "Keychain access needed — click the icon, then “Always Allow”"
                scheduleTimer(interval: normalInterval)
            case .other:
                needsKeychainAccess = false
                failureCount += 1
                self.error = "Couldn't read Keychain (status \(error.code))"
                scheduleTimer(interval: retryInterval())
            }
            return
        }

        // Network / server errors leave authState unchanged: a flaky connection
        // is not a sign-in problem and shouldn't flip the Auth row red.
        needsKeychainAccess = false
        failureCount += 1
        self.error = friendlyMessage(for: error)
        scheduleTimer(interval: retryInterval())
    }

    /// Exponential backoff for transient failures, capped at the normal poll
    /// interval: 30s, 60s, 120s, 240s, then 5 min.
    private func retryInterval() -> TimeInterval {
        let delay = 30.0 * pow(2.0, Double(min(failureCount - 1, 4)))
        return min(delay, normalInterval)
    }

    private func friendlyMessage(for error: NSError) -> String {
        switch error.domain {
        case "Keychain":
            return "Claude Code not signed in — open Claude Code and log in"
        case NSURLErrorDomain:
            switch error.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "No internet connection — retrying…"
            case NSURLErrorTimedOut:
                return "Request timed out — retrying…"
            default:
                return "Network error — retrying…"
            }
        case "OAuthUsage" where error.code >= 500:
            return "Anthropic server error (\(error.code)) — retrying…"
        case "OAuthUsage":
            return "Couldn't load usage (HTTP \(error.code))"
        default:
            return "Couldn't load usage — retrying…"
        }
    }

    func fetchOAuthUsage(accessToken: String) async throws -> OAuthUsageResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData   // always fetch live numbers

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        #if DEBUG
        print("[UsageService] GET /api/oauth/usage → HTTP \(http.statusCode)")
        #endif

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw NSError(domain: "OAuthUsage", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body.prefix(200))"])
        }

        return try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
    }
}
