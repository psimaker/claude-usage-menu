import XCTest
import Security
@testable import ClaudeUsageMenu

// MARK: - OAuthUsageResponse decoding

final class OAuthUsageResponseTests: XCTestCase {

    func testDecodesFullResponse() throws {
        let json = """
        {
          "five_hour":   { "utilization": 35.0, "resets_at": "2026-03-19T19:00:00.367134+00:00" },
          "seven_day":   { "utilization": 71.0, "resets_at": "2026-03-20T11:00:00.367161+00:00" },
          "seven_day_sonnet": { "utilization": 27.0, "resets_at": "2026-03-20T12:00:00.367175+00:00" },
          "seven_day_oauth_apps": null,
          "seven_day_opus": null,
          "seven_day_cowork": null,
          "iguana_necktie": null,
          "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertEqual(response.fiveHour?.utilization, 35.0)
        XCTAssertEqual(response.sevenDay?.utilization, 71.0)
        XCTAssertEqual(response.sevenDaySonnet?.utilization, 27.0)
    }

    func testDecodesNullSonnet() throws {
        let json = """
        {
          "five_hour":   { "utilization": 10.0, "resets_at": "2026-03-19T19:00:00+00:00" },
          "seven_day":   { "utilization": 20.0, "resets_at": "2026-03-20T11:00:00+00:00" },
          "seven_day_sonnet": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertNil(response.sevenDaySonnet)
        XCTAssertEqual(response.fiveHour?.utilization, 10.0)
    }

    func testDecodesSonnetWithNullResetsAt() throws {
        // Regression: the live API returns a present seven_day_sonnet object whose
        // resets_at is null when there is no active Sonnet window (utilization 0).
        // A non-optional resetsAt made the WHOLE response decode throw → blank stats.
        let json = """
        {
          "five_hour":   { "utilization": 5.0, "resets_at": "2026-06-04T20:50:00.287325+00:00" },
          "seven_day":   { "utilization": 10.0, "resets_at": "2026-06-10T18:00:00.287350+00:00" },
          "seven_day_sonnet": { "utilization": 0.0, "resets_at": null }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertEqual(response.fiveHour?.utilization, 5.0)
        XCTAssertEqual(response.sevenDay?.utilization, 10.0)
        XCTAssertEqual(response.sevenDaySonnet?.utilization, 0.0)
        XCTAssertNil(response.sevenDaySonnet?.resetsAt)
        XCTAssertNil(response.sevenDaySonnet?.resetsAtDate)
    }

    func testDecodesAllNulls() throws {
        let json = """
        {
          "five_hour": null,
          "seven_day": null,
          "seven_day_sonnet": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertNil(response.fiveHour)
        XCTAssertNil(response.sevenDay)
        XCTAssertNil(response.sevenDaySonnet)
    }

    func testResetsAtDateParsesWithFractionalSeconds() throws {
        let json = """
        {
          "five_hour": { "utilization": 35.0, "resets_at": "2026-03-19T19:00:00.367134+00:00" },
          "seven_day": null, "seven_day_sonnet": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)
        XCTAssertNotNil(response.fiveHour?.resetsAtDate, "resetsAt date should parse successfully")
    }

    func testUtilizationConvertsToInt() throws {
        let json = """
        {
          "five_hour":   { "utilization": 34.7, "resets_at": "2026-03-19T19:00:00+00:00" },
          "seven_day":   { "utilization": 71.2, "resets_at": "2026-03-20T11:00:00+00:00" },
          "seven_day_sonnet": { "utilization": 26.9, "resets_at": "2026-03-20T12:00:00+00:00" }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        // Int() truncates (floors), matching how snapshot builds utilization
        XCTAssertEqual(Int(response.fiveHour!.utilization), 34)
        XCTAssertEqual(Int(response.sevenDay!.utilization), 71)
        XCTAssertEqual(Int(response.sevenDaySonnet!.utilization), 26)
    }
}

// MARK: - Extra usage (decode + display mapping)

final class ExtraUsageTests: XCTestCase {

    func testDecodesEnabledExtraUsage() throws {
        let json = """
        {
          "five_hour": { "utilization": 5.0, "resets_at": "2026-06-12T19:00:00+00:00" },
          "seven_day": { "utilization": 10.0, "resets_at": "2026-06-15T11:00:00+00:00" },
          "extra_usage": { "is_enabled": true, "monthly_limit": 200000,
                           "used_credits": 12345, "utilization": 6.2, "currency": "USD" }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertEqual(response.extraUsage?.isEnabled, true)
        XCTAssertEqual(response.extraUsage?.monthlyLimit, 200_000)
        XCTAssertEqual(response.extraUsage?.usedCredits, 12_345)
    }

    func testMapsCentsToDollars() {
        let extra = OAuthUsageResponse.ExtraUsage(
            isEnabled: true, monthlyLimit: 200_000, usedCredits: 12_345,
            utilization: 6.2, currency: "USD")

        let snapshot = extraUsageSnapshot(from: extra)

        XCTAssertEqual(snapshot?.usedDollars ?? 0, 123.45, accuracy: 0.001)
        XCTAssertEqual(snapshot?.limitDollars ?? 0, 2000.0, accuracy: 0.001)
        XCTAssertEqual(snapshot?.utilization, 6)
        XCTAssertEqual(snapshot?.currencyCode, "USD")
    }

    func testDisabledMapsToNil() {
        // The live API returns this exact shape for accounts without extra usage.
        let extra = OAuthUsageResponse.ExtraUsage(
            isEnabled: false, monthlyLimit: nil, usedCredits: nil,
            utilization: nil, currency: nil)
        XCTAssertNil(extraUsageSnapshot(from: extra))
        XCTAssertNil(extraUsageSnapshot(from: nil))
    }

    func testEnabledWithoutAmountsMapsToNil() {
        let extra = OAuthUsageResponse.ExtraUsage(
            isEnabled: true, monthlyLimit: nil, usedCredits: 100,
            utilization: nil, currency: nil)
        XCTAssertNil(extraUsageSnapshot(from: extra))
    }

    func testUtilizationFallsBackToComputedPercent() {
        let extra = OAuthUsageResponse.ExtraUsage(
            isEnabled: true, monthlyLimit: 200_000, usedCredits: 50_000,
            utilization: nil, currency: nil)

        let snapshot = extraUsageSnapshot(from: extra)

        XCTAssertEqual(snapshot?.utilization, 25)
        XCTAssertEqual(snapshot?.currencyCode, "USD", "missing currency defaults to USD")
    }

    func testCurrencyFormatting() {
        XCTAssertEqual(formatCurrencyAmount(0, code: "USD"), "$0.00")
        XCTAssertEqual(formatCurrencyAmount(123.45, code: "USD"), "$123.45")
        XCTAssertEqual(formatCurrencyAmount(2000, code: "USD"), "$2,000.00")
        XCTAssertEqual(formatCurrencyAmount(12.5, code: "EUR"), "EUR 12.50")
    }
}

// MARK: - displayPlanName

final class DisplayPlanNameTests: XCTestCase {

    func testCapitalizesKnownPlans() {
        XCTAssertEqual(displayPlanName("max"), "Max")
        XCTAssertEqual(displayPlanName("pro"), "Pro")
        XCTAssertEqual(displayPlanName("enterprise"), "Enterprise")
    }

    func testNormalizesWhitespaceAndCase() {
        XCTAssertEqual(displayPlanName(" MAX "), "Max")
    }

    func testAbsentOrEmptyReturnsNil() {
        XCTAssertNil(displayPlanName(nil))
        XCTAssertNil(displayPlanName(""))
        XCTAssertNil(displayPlanName("   "))
    }
}

// MARK: - oauthTokenFromSecurityCLIOutput

final class SecurityCLIOutputParsingTests: XCTestCase {

    /// Shape of the real credential JSON (extra keys must be tolerated).
    private let sampleJSON = """
    {"claudeAiOauth":{"accessToken":"test-token-123","refreshToken":"r","expiresAt":1700000000000,\
    "scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default"}}
    """

    func testParsesPlainJSON() {
        let token = oauthTokenFromSecurityCLIOutput(Data(sampleJSON.utf8))
        XCTAssertEqual(token?.accessToken, "test-token-123")
        XCTAssertEqual(token?.expiresAt?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 1)
        XCTAssertEqual(token?.subscriptionType, "max")
    }

    func testTrimsTrailingNewline() {
        // `security find-generic-password -w` terminates its output with \n.
        let token = oauthTokenFromSecurityCLIOutput(Data((sampleJSON + "\n").utf8))
        XCTAssertEqual(token?.accessToken, "test-token-123")
    }

    func testTrimsCRLF() {
        let token = oauthTokenFromSecurityCLIOutput(Data((sampleJSON + "\r\n").utf8))
        XCTAssertEqual(token?.accessToken, "test-token-123")
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(oauthTokenFromSecurityCLIOutput(Data("not json".utf8)))
        XCTAssertNil(oauthTokenFromSecurityCLIOutput(Data()))
        XCTAssertNil(oauthTokenFromSecurityCLIOutput(Data("\n".utf8)))
    }
}

// MARK: - formatTimeRemaining

final class FormatTimeRemainingTests: XCTestCase {

    func testPastDateReturnsNow() {
        let past = Date().addingTimeInterval(-60)
        XCTAssertEqual(formatTimeRemaining(until: past), "now")
    }

    func testFortyFiveMinutesRemaining() {
        let now = Date()
        XCTAssertEqual(formatTimeRemaining(until: now.addingTimeInterval(45 * 60), from: now), "45m")
    }

    func testTwoHoursThirtyMinutes() {
        let now = Date()
        XCTAssertEqual(formatTimeRemaining(until: now.addingTimeInterval(2 * 3600 + 30 * 60), from: now), "2h 30m")
    }

    func testExactlyOneHour() {
        let now = Date()
        XCTAssertEqual(formatTimeRemaining(until: now.addingTimeInterval(3600), from: now), "1h 0m")
    }

    func testDaysAndHours() {
        let now = Date()
        XCTAssertEqual(
            formatTimeRemaining(until: now.addingTimeInterval(2 * 86_400 + 3 * 3600 + 10 * 60), from: now),
            "2d 3h"
        )
    }
}

// MARK: - parseISO8601Date (robust to missing fractional seconds)

final class ParseISO8601DateTests: XCTestCase {

    func testParsesWithFractionalSeconds() {
        XCTAssertNotNil(parseISO8601Date("2026-03-19T19:00:00.367134+00:00"))
    }

    func testParsesWithoutFractionalSeconds() {
        // Regression: ISO8601DateFormatter with .withFractionalSeconds REJECTS
        // timestamps that lack them, silently blanking the reset countdown.
        XCTAssertNotNil(parseISO8601Date("2026-03-19T19:00:00+00:00"))
    }

    func testParsesZuluWithoutFractionalSeconds() {
        XCTAssertNotNil(parseISO8601Date("2026-03-19T19:00:00Z"))
    }

    func testBadInputReturnsNil() {
        XCTAssertNil(parseISO8601Date("not a date"))
        XCTAssertNil(parseISO8601Date(""))
    }

    func testResetsAtDateDecodesWithoutFractionalSeconds() throws {
        let json = """
        {
          "five_hour": { "utilization": 5.0, "resets_at": "2026-03-19T19:00:00+00:00" },
          "seven_day": null, "seven_day_sonnet": null
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)
        XCTAssertNotNil(response.fiveHour?.resetsAtDate, "non-fractional resets_at must parse to a Date")
    }
}

// MARK: - oauthExpiryDate

final class OAuthExpiryDateTests: XCTestCase {

    func testMillisecondsTimestamp() {
        let date = oauthExpiryDate(fromRawExpiresAt: 1_700_000_000_000)
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 1)
    }

    func testSecondsTimestamp() {
        let date = oauthExpiryDate(fromRawExpiresAt: 1_700_000_000)
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 1)
    }

    func testZeroReturnsNil() {
        XCTAssertNil(oauthExpiryDate(fromRawExpiresAt: 0))
    }
}

// MARK: - usageLevel

final class UsageLevelTests: XCTestCase {

    func testBelowWarningIsNormal() {
        XCTAssertEqual(usageLevel(percent: 50, warning: 80, critical: 90), .normal)
    }

    func testAtWarningIsWarning() {
        XCTAssertEqual(usageLevel(percent: 80, warning: 80, critical: 90), .warning)
    }

    func testBetweenIsWarning() {
        XCTAssertEqual(usageLevel(percent: 85, warning: 80, critical: 90), .warning)
    }

    func testAtCriticalIsCritical() {
        XCTAssertEqual(usageLevel(percent: 90, warning: 80, critical: 90), .critical)
    }

    func testAboveCriticalIsCritical() {
        XCTAssertEqual(usageLevel(percent: 100, warning: 80, critical: 90), .critical)
    }
}

// MARK: - displayPercent

final class DisplayPercentTests: XCTestCase {

    func testInRangeUnchanged() {
        XCTAssertEqual(displayPercent(0), 0)
        XCTAssertEqual(displayPercent(73), 73)
        XCTAssertEqual(displayPercent(100), 100)
    }

    func testOverHundredClampsToHundred() {
        XCTAssertEqual(displayPercent(105), 100)
        XCTAssertEqual(displayPercent(9999), 100)
    }

    func testNegativeClampsToZero() {
        XCTAssertEqual(displayPercent(-1), 0)
    }
}

// MARK: - resetCaption

final class ResetCaptionTests: XCTestCase {

    func testFutureUsesResetsIn() {
        let now = Date()
        XCTAssertEqual(resetCaption(until: now.addingTimeInterval(45 * 60), from: now), "resets in 45m")
    }

    func testAtBoundaryReadsResettingNow() {
        let now = Date()
        XCTAssertEqual(resetCaption(until: now, from: now), "resetting now")
    }

    func testPastReadsResettingNow() {
        let now = Date()
        XCTAssertEqual(resetCaption(until: now.addingTimeInterval(-120), from: now), "resetting now")
    }
}

// MARK: - evaluateUsageAlert

final class EvaluateUsageAlertTests: XCTestCase {

    private func eval(_ usage: Int, _ gate: inout AlertGate, period: Date? = nil) -> UsageAlertLevel {
        evaluateUsageAlert(usage: usage, warningThreshold: 80, criticalThreshold: 90,
                           periodResetAt: period, gate: &gate)
    }

    func testBelowWarningNoAlert() {
        var gate = AlertGate()
        XCTAssertEqual(eval(50, &gate), .none)
    }

    func testWarningFiresOnceThenSuppressed() {
        var gate = AlertGate()
        XCTAssertEqual(eval(82, &gate), .warning)
        XCTAssertEqual(eval(85, &gate), .none)
    }

    func testCriticalFiresOnceAndReArmsAfterDip() {
        var gate = AlertGate()
        XCTAssertEqual(eval(95, &gate), .critical)
        XCTAssertEqual(eval(96, &gate), .none)
        // Dropping into the warning band re-arms critical but does not re-warn.
        XCTAssertEqual(eval(85, &gate), .none)
        // Re-crossing critical fires again.
        XCTAssertEqual(eval(95, &gate), .critical)
    }

    func testDropBelowWarningReArmsBoth() {
        var gate = AlertGate()
        XCTAssertEqual(eval(95, &gate), .critical)
        XCTAssertEqual(eval(10, &gate), .none)
        XCTAssertEqual(eval(82, &gate), .warning)
    }

    func testNewPeriodReArms() {
        let p1 = Date(timeIntervalSince1970: 1_000_000)
        let p2 = Date(timeIntervalSince1970: 2_000_000)
        var gate = AlertGate()
        XCTAssertEqual(eval(95, &gate, period: p1), .critical)
        XCTAssertEqual(eval(95, &gate, period: p1), .none)
        XCTAssertEqual(eval(95, &gate, period: p2), .critical)
    }

    func testGateSurvivesEncodeDecodeAndDoesNotRefire() throws {
        let period = Date(timeIntervalSince1970: 1_000_000)
        var gate = AlertGate()
        XCTAssertEqual(eval(95, &gate, period: period), .critical)

        let data = try JSONEncoder().encode(gate)
        var restored = try JSONDecoder().decode(AlertGate.self, from: data)
        XCTAssertEqual(gate, restored)
        // Restored gate must not re-fire for the same period (restart mid-period).
        XCTAssertEqual(eval(95, &restored, period: period), .none)
    }
}

// MARK: - Effective thresholds (normalize inverted slider values)

final class EffectiveThresholdTests: XCTestCase {

    func testNormalOrderUnchanged() {
        var settings = AppSettings()
        settings.warningThreshold = 80
        settings.criticalThreshold = 90
        XCTAssertEqual(settings.effectiveWarningThreshold, 80)
        XCTAssertEqual(settings.effectiveCriticalThreshold, 90)
    }

    func testInvertedOrderNormalized() {
        // User set critical below warning; color and alert logic must still agree.
        var settings = AppSettings()
        settings.warningThreshold = 95
        settings.criticalThreshold = 60
        XCTAssertEqual(settings.effectiveWarningThreshold, 60)
        XCTAssertEqual(settings.effectiveCriticalThreshold, 95)
    }
}

// MARK: - classifyKeychainStatus

final class KeychainStatusTests: XCTestCase {

    func testItemNotFoundIsNotSignedIn() {
        XCTAssertEqual(classifyKeychainStatus(errSecItemNotFound), .notSignedIn)
    }

    func testUserCanceledIsAccessDenied() {
        // Regression: a dismissed/denied access prompt — or an ACL revoked by
        // Claude Code's token rotation — used to be reported as "not signed in",
        // misdirecting the user to re-login instead of approving the prompt.
        XCTAssertEqual(classifyKeychainStatus(errSecUserCanceled), .accessDenied)
    }

    func testAuthFailedIsAccessDenied() {
        XCTAssertEqual(classifyKeychainStatus(errSecAuthFailed), .accessDenied)
    }

    func testInteractionNotAllowedIsInteractionRequired() {
        // A non-interactive background read against an ACL reset by Claude Code's
        // ~8h token rotation returns this; it must surface as the actionable
        // "Keychain" state (recoverable on the next user-activated interactive
        // read), never as a sign-out.
        XCTAssertEqual(classifyKeychainStatus(errSecInteractionNotAllowed), .interactionRequired)
    }

    func testSuccessAndUnknownAreOther() {
        XCTAssertEqual(classifyKeychainStatus(errSecSuccess), .other)
        XCTAssertEqual(classifyKeychainStatus(-99_999), .other)
    }
}
