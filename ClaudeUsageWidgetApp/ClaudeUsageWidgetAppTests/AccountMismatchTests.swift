//
//  AccountMismatchTests.swift
//  ClaudeUsageWidgetAppTests
//
//  토큰 상세는 늘 Claude Code 로그를 세고, 소진율은 로그인 세션의 계정에서 온다. 두 계정이
//  다르면 패널의 두 숫자가 서로 다른 계정을 가리킨다 — 숫자 자체는 멀쩡해 보인다.
//
//  Claude Code 쪽 계정은 ~/.claude.json 에 있어 인증 없이 읽힌다.
//

import Foundation
import Testing

struct AccountMismatchTests {
    /// `~/.claude.json` 에서 계정 판별에 필요한 부분만 남긴 픽스처.
    ///
    /// 실제 파일은 50KB가 넘고 관심 없는 키가 대부분이라, 모르는 키를 무시하는지도 함께 본다.
    private static let claudeCodeConfigJSON = """
    {"numStartups":42,"hasCompletedOnboarding":true,
     "oauthAccount":{"accountUuid":"11111111-2222-3333-4444-555555555555",
                     "emailAddress":"someone@example.com",
                     "organizationUuid":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                     "organizationName":"Example Team",
                     "seatTier":"team_tier_1"}}
    """

    private static func temporaryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-config-\(UUID().uuidString).json")
    }

    @Test("~/.claude.json 에서 Claude Code 계정을 읽는다")
    func readsClaudeCodeAccount() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(Self.claudeCodeConfigJSON.utf8).write(to: url)

        let account = ClaudeCodeAccount.read(from: url)

        #expect(account?.email == "someone@example.com")
        #expect(account?.organizationUuid == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(account?.organizationName == "Example Team")
    }

    /// 위 픽스처와 같은 계정의 실측 캐시.
    private static func serverCache(email: String?,
                                   organizationUuid: String?) -> AccountCache {
        AccountCache(email: email,
                     organizationUuid: organizationUuid,
                     organizationName: "Example Team",
                     sessionFingerprint: "6f5cc43e4293b697",
                     checkedAt: Date(timeIntervalSince1970: 1_785_000_000))
    }

    private static let localAccount = ClaudeCodeAccount(
        email: "someone@example.com",
        organizationUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        organizationName: "Example Team")

    @Test("한쪽 계정을 모르면 비교하지 않는다")
    func cannotCompareWithoutBothSides() {
        #expect(AccountMatch.evaluate(server: nil, local: Self.localAccount) == .unknown)
        #expect(AccountMatch.evaluate(server: Self.serverCache(email: "someone@example.com",
                                                              organizationUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
                                      local: nil) == .unknown)
    }

    @Test("조직이 같아도 이메일이 다르면 서로 다른 계정이다")
    func detectsDifferentAccount() {
        // 같은 팀 조직의 다른 멤버라면 organizationUuid 는 일치한다. 조직만 비교하면
        // 이 경우를 놓치므로 이메일을 먼저 본다.
        let server = Self.serverCache(email: "someone.else@example.com",
                                     organizationUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

        #expect(AccountMatch.evaluate(server: server, local: Self.localAccount)
                == .differentAccount)
    }

    @Test("같은 계정이어도 조직이 다르면 다른 조직의 사용량이다")
    func detectsDifferentOrganization() {
        // 개인 Pro 와 팀 시트를 함께 가진 계정에서, 실측이 로컬 로그와 다른 조직을 볼 수 있다.
        let server = Self.serverCache(email: "someone@example.com",
                                     organizationUuid: "ffffffff-0000-0000-0000-000000000000")

        #expect(AccountMatch.evaluate(server: server, local: Self.localAccount)
                == .differentOrganization)
    }

    @Test("계정과 조직이 모두 같으면 경고할 것이 없다")
    func reportsMatchWhenBothSidesAgree() {
        // 이 확인이 없으면 판정 함수가 항상 불일치를 보고해도 위 테스트들은 통과한다.
        let server = Self.serverCache(email: "someone@example.com",
                                     organizationUuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

        #expect(AccountMatch.evaluate(server: server, local: Self.localAccount) == .same)
    }

    @Test("Claude Code 가 로그인돼 있지 않으면 계정을 알 수 없다")
    func returnsNothingWhenNotLoggedIn() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // 로그아웃 상태의 ~/.claude.json 에는 oauthAccount 가 없다.
        try Data(#"{"numStartups":42,"hasCompletedOnboarding":true}"#.utf8).write(to: url)

        #expect(ClaudeCodeAccount.read(from: url) == nil)
        #expect(ClaudeCodeAccount.read(from: Self.temporaryURL()) == nil)
    }
}
