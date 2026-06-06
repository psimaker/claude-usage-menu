import Foundation
import Security

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

func readOAuthToken() throws -> OAuthToken {
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

/// Returns utilization percentage (0–100) given token count and limit.
func calculateUtilization(tokens: Int, limit: Int) -> Int {
    guard limit > 0 else { return 0 }
    return min(100, tokens * 100 / limit)
}

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
    private func accessToken() throws -> String {
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

        // Read the Keychain outside the lock (it can block), then store.
        let creds = try readOAuthToken()
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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fetchUsage()
        }
    }

    func fetchUsage() {
        guard !isFetching else { return }   // main-thread single-flight
        isFetching = true
        isLoading = true

        Task {
            do {
                let token = try self.accessToken()
                let response = try await self.fetchOAuthUsage(accessToken: token)

                let snapshot = UsageSnapshot(
                    fiveHourUtilization: Int(response.fiveHour?.utilization ?? 0),
                    sevenDayUtilization: Int(response.sevenDay?.utilization ?? 0),
                    sevenDaySonnetUtilization: response.sevenDaySonnet.map { Int($0.utilization) },
                    fiveHourResetAt: response.fiveHour?.resetsAtDate,
                    sevenDayResetAt: response.sevenDay?.resetsAtDate,
                    lastUpdated: Date(),
                    hasData: true
                )

                await MainActor.run {
                    self.currentUsage = snapshot
                    self.error = nil
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

        if isOAuthHTTP && error.code == 429 {
            clearToken()   // a refreshed token may help next time
            self.error = "Rate limited — retrying in 15 min"
            scheduleTimer(interval: backoffInterval)
            return
        }

        if isOAuthHTTP && (error.code == 401 || error.code == 403) {
            // Token expired/revoked: drop the cache so the next poll re-reads
            // the (refreshed) Keychain credential.
            clearToken()
            authState = .expired
            self.error = "Sign-in expired — re-reading Claude Code credentials"
            scheduleTimer(interval: normalInterval)
            return
        }

        if error.domain == "Keychain" {
            authState = .signedOut
        }
        // Network / server errors leave authState unchanged: a flaky connection
        // is not a sign-in problem and shouldn't flip the Auth row red.

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
