import XCTest
@testable import AIUsage

final class ProviderTests: XCTestCase {
    func testClaudeRetriesOnceAfter401AndPersistsRotation() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oauth = ClaudeOAuth(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiresAt: (now.timeIntervalSince1970 + 3_600) * 1_000,
            subscriptionType: "pro",
            rateLimitTier: "max_20x",
            scopes: ["user:profile"]
        )
        let keychain = MemoryKeychain(currentUser: [
            "Claude Code-credentials":
                encodedJSON(ClaudeCredentialsDocument(claudeAiOauth: oauth))
        ])
        let http = MockHTTPClient([
            httpResponse(401),
            httpResponse(json: """
            {
              "access_token": "new-access",
              "refresh_token": "new-refresh",
              "expires_in": 3600
            }
            """),
            httpResponse(json: """
            {"five_hour": {"utilization": 31, "resets_at": 1800003600}}
            """)
        ])
        let date = FixedDateProvider(value: now)
        let store = ClaudeAuthStore(
            environment: MockEnvironment(),
            files: MemoryFiles(),
            keychain: keychain,
            dateProvider: date
        )
        let provider = ClaudeProvider(
            authStore: store,
            client: ClaudeUsageClient(http: http),
            dateProvider: date
        )

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.sessionWindow?.usedPercent, 31)
        let requests = await http.capturedRequests()
        // The first read of a session also takes the hourly reset grants.
        XCTAssertEqual(requests.map(\.url), [
            ClaudeAuthStore.usageWithResetGrantsURL,
            ClaudeAuthStore.refreshURL,
            ClaudeAuthStore.usageWithResetGrantsURL
        ])
        XCTAssertEqual(
            requests[0].headers["User-Agent"],
            ClaudeUsageClient.userAgent
        )
        let saved = try XCTUnwrap(keychain.currentValue(service: "Claude Code-credentials"))
        let savedDocument = try XCTUnwrap(
            ProviderParsing.decodeWithHexFallback(saved, as: ClaudeCredentialsDocument.self)
        )
        XCTAssertEqual(savedDocument.claudeAiOauth?.accessToken, "new-access")
        XCTAssertEqual(savedDocument.claudeAiOauth?.refreshToken, "new-refresh")
    }

    func testClaudeCooldownSkipsSecondRequestAfter429() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oauth = ClaudeOAuth(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: (now.timeIntervalSince1970 + 3_600) * 1_000,
            subscriptionType: nil,
            rateLimitTier: nil,
            scopes: ["user:profile"]
        )
        let keychain = MemoryKeychain(currentUser: [
            "Claude Code-credentials":
                encodedJSON(ClaudeCredentialsDocument(claudeAiOauth: oauth))
        ])
        let http = MockHTTPClient([
            httpResponse(429, headers: ["Retry-After": "120"])
        ])
        let date = FixedDateProvider(value: now)
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: MockEnvironment(),
                files: MemoryFiles(),
                keychain: keychain,
                dateProvider: date
            ),
            client: ClaudeUsageClient(http: http),
            dateProvider: date
        )

        for _ in 0..<2 {
            do {
                _ = try await provider.fetch()
                XCTFail("Expected rate limit")
            } catch let failure as ProviderFailure {
                XCTAssertEqual(failure.kind, .rateLimited)
                // A short Retry-After still waits the five-minute minimum,
                // because Anthropic keeps its own penalty for longer.
                XCTAssertEqual(
                    failure.retryAt,
                    now.addingTimeInterval(300)
                )
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        let requestCount = await http.capturedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testClaudeShowsOtherConfigDirectoryAccounts() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func credentials(_ token: String) -> String {
            encodedJSON(ClaudeCredentialsDocument(claudeAiOauth: ClaudeOAuth(
                accessToken: token,
                refreshToken: nil,
                expiresAt: (now.timeIntervalSince1970 + 3_600) * 1_000,
                subscriptionType: nil,
                rateLimitTier: nil,
                scopes: ["user:profile"]
            )))
        }
        func profile(_ account: String, _ org: String) -> String {
            """
            {"oauthAccount": {"accountUuid": "\(account)", "organizationUuid": "o",
             "emailAddress": "me@example.com", "organizationName": "\(org)"}}
            """
        }
        let team = "/Users/me/.claude-team"
        let duplicate = "/Users/me/.claude-copy"
        let teamService = "Claude Code-credentials-\(ProviderParsing.shortSHA256(team))"
        let keychain = MemoryKeychain(currentUser: [
            "Claude Code-credentials": credentials("personal"),
            teamService: credentials("team")
        ])
        let files = MemoryFiles([
            "~/.claude.json": profile("a", "me@example.com's Organization"),
            "\(team)/.claude.json": profile("b", "Acme"),
            "\(duplicate)/.claude.json": profile("a", "me@example.com's Organization")
        ])
        let http = MockHTTPClient([
            httpResponse(json: #"{"five_hour": {"utilization": 10}}"#),
            httpResponse(json: #"{"five_hour": {"utilization": 70}}"#)
        ])
        let date = FixedDateProvider(value: now)
        @Sendable func store(_ directory: String?) -> ClaudeAuthStore {
            ClaudeAuthStore(
                environment: MockEnvironment(),
                files: files,
                keychain: keychain,
                dateProvider: date,
                configDirectory: directory
            )
        }
        let client = ClaudeUsageClient(http: http)
        let provider = ClaudeProvider(
            authStore: store(nil),
            client: client,
            dateProvider: date,
            accountDirectories: { [duplicate, team] },
            makeAccountProvider: {
                ClaudeProvider(authStore: store($0), client: client, dateProvider: date)
            }
        )

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.accountName, "me@example.com")
        XCTAssertEqual(snapshot.sessionWindow?.usedPercent, 10)
        // The copy of the default login is skipped; the team login has its own card.
        XCTAssertEqual(snapshot.otherAccounts.map(\.name), ["Acme"])
        XCTAssertEqual(snapshot.otherAccounts.first?.snapshot?.sessionWindow?.usedPercent, 70)
        let tokens = await http.capturedRequests().map { $0.headers["Authorization"] }
        XCTAssertEqual(tokens, ["Bearer personal", "Bearer team"])
    }

    func testCodexProactiveRefreshUsesExactSourceAndFormEncoding() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let auth = CodexAuth(
            tokens: CodexTokens(
                accessToken: jwt(expiration: now.timeIntervalSince1970 + 60),
                refreshToken: "refresh +&",
                idToken: "old-id",
                accountID: "account-1"
            ),
            lastRefresh: nil,
            apiKey: nil
        )
        let files = MemoryFiles([
            "~/.config/codex/auth.json": encodedJSON(auth)
        ])
        let http = MockHTTPClient([
            httpResponse(json: """
            {
              "access_token": "new-access",
              "refresh_token": "new-refresh",
              "id_token": "new-id"
            }
            """),
            httpResponse(json: """
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 9,
                  "limit_window_seconds": 18000
                }
              }
            }
            """)
        ])
        let date = FixedDateProvider(value: now)
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: MockEnvironment(),
                files: files,
                keychain: MemoryKeychain(),
                dateProvider: date
            ),
            client: CodexUsageClient(http: http),
            dateProvider: date
        )

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.planName, "Pro 200")
        XCTAssertEqual(snapshot.sessionWindow?.usedPercent, 9)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map(\.url), [
            CodexUsageClient.refreshURL,
            CodexUsageClient.usageURL
        ])
        let form = String(data: requests[0].body ?? Data(), encoding: .utf8)
        XCTAssertTrue(form?.contains("refresh_token=refresh%20%2B%26") == true)
        XCTAssertEqual(requests[1].headers["ChatGPT-Account-Id"], "account-1")

        let saved = try XCTUnwrap(files.value(at: "~/.config/codex/auth.json"))
        let savedAuth = try XCTUnwrap(CodexAuthStore.parseAuth(saved))
        XCTAssertEqual(savedAuth.tokens?.accessToken, "new-access")
        XCTAssertEqual(savedAuth.tokens?.refreshToken, "new-refresh")
    }
}
