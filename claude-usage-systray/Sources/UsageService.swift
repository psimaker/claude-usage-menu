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

func readOAuthAccessToken() throws -> String {
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
                      userInfo: [NSLocalizedDescriptionKey: "Claude Code credentials not found in Keychain. Make sure Claude Code is installed and logged in. (status: \(status))"])
    }
    let creds = try JSONDecoder().decode(KeychainCredentials.self, from: data)
    return creds.claudeAiOauth.accessToken
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
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: resetsAt)
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
    let hours = Int(interval) / 3600
    let minutes = (Int(interval) % 3600) / 60
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
}

// MARK: - UsageService

final class UsageService: ObservableObject {
    static let shared = UsageService()

    @Published private(set) var currentUsage: UsageSnapshot = .placeholder
    @Published private(set) var error: String?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var weeklySessions: Int = 0
    @Published private(set) var weeklyMessages: Int = 0
    @Published private(set) var weeklyTokens: Int = 0

    private var refreshTimer: Timer?
    private let normalInterval: TimeInterval = 5 * 60   // 5 minutes
    private let backoffInterval: TimeInterval = 15 * 60 // 15 minutes after 429

    // Injectable for testing
    var urlSession: URLSession = .shared

    private var cachedToken: String?

    private init() {}

    private func accessToken() throws -> String {
        if let token = cachedToken { return token }
        let token = try readOAuthAccessToken()
        cachedToken = token
        return token
    }

    func startPolling() {
        fetchUsage()
        scheduleTimer(interval: normalInterval)
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
        DispatchQueue.main.async { self.isLoading = true }

        Task {
            do {
                let token = try accessToken()
                let response = try await fetchOAuthUsage(accessToken: token)

                let fiveHourUtil = Int(response.fiveHour?.utilization ?? 0)
                let sevenDayUtil = Int(response.sevenDay?.utilization ?? 0)
                let sonnetUtil: Int? = response.sevenDaySonnet.map { Int($0.utilization) }

                let fiveHourReset = response.fiveHour?.resetsAtDate
                let sevenDayReset = response.sevenDay?.resetsAtDate

                let snapshot = UsageSnapshot(
                    fiveHourUtilization: fiveHourUtil,
                    sevenDayUtilization: sevenDayUtil,
                    sevenDaySonnetUtilization: sonnetUtil,
                    fiveHourResetIn: fiveHourReset.map { formatTimeRemaining(until: $0) },
                    sevenDayResetIn: sevenDayReset.map { formatTimeRemaining(until: $0) },
                    lastUpdated: Date(),
                    weeklySessions: 0,
                    weeklyMessages: 0,
                    weeklyTokens: 0
                )

                await MainActor.run {
                    self.currentUsage = snapshot
                    self.error = nil
                    self.isLoading = false
                    self.scheduleTimer(interval: self.normalInterval)
                }
            } catch let error as NSError {
                let isRateLimit = error.code == 429
                await MainActor.run {
                    if isRateLimit {
                        // Clear token so next attempt re-reads a potentially refreshed token from Keychain
                        self.cachedToken = nil
                        self.error = "Rate limited — retrying in 15 min"
                        self.scheduleTimer(interval: self.backoffInterval)
                    } else {
                        self.error = error.localizedDescription
                        self.scheduleTimer(interval: self.normalInterval)
                    }
                    self.isLoading = false
                }
            }
        }
    }

    func fetchOAuthUsage(accessToken: String) async throws -> OAuthUsageResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        print("[UsageService] GET /api/oauth/usage")

        let (data, response) = try await urlSession.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? "<binary>"

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        print("[UsageService] HTTP \(http.statusCode) — \(body.prefix(300))")

        guard http.statusCode == 200 else {
            throw NSError(domain: "OAuthUsage", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
        }

        return try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
    }
}
