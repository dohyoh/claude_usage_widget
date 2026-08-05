//
//  AccountIdentityTests.swift
//  ClaudeUsageWidgetAppTests
//
//  실측 사용량을 어느 계정으로 가져왔는지 기억해 둬야, 로컬 추정(Claude Code 로그)과
//  계정이 어긋났을 때 사용자에게 알릴 수 있다.
//
//  계정 정보를 매번 조회하지 않으려면 캐시가 필요하고, 캐시를 언제 버려야 하는지는
//  "로그인이 바뀌었는가"로 판단한다. 세션 쿠키 원본은 저장하지 않고 지문만 쓴다.
//

import Foundation
import Testing

struct AccountIdentityTests {
    @Test("세션 키 지문은 sha256 앞 16자이고 키마다 다르다")
    func fingerprintsSessionKey() {
        // 기대값은 코드와 독립적으로 계산했다:
        //   printf '%s' '<키>' | shasum -a 256 | cut -c1-16
        #expect(AccountIdentity.fingerprint(sessionKey: "sk-ant-sid01-EXAMPLE-SESSION-KEY")
                == "6f5cc43e4293b697")
        #expect(AccountIdentity.fingerprint(sessionKey: "sk-ant-sid01-ANOTHER-SESSION-KEY")
                == "5fc9af1048a85990")
    }

    /// 임시 파일 경로. 사용자의 실제 캐시 파일을 건드리지 않는다.
    private static func temporaryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-widget-account-\(UUID().uuidString).json")
    }

    @Test("캐시를 파일에 쓰고 그대로 읽어온다")
    func roundTripsCacheThroughFile() throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // 초 단위 시각을 쓴다 — iso8601 로 직렬화하면 소수 초가 잘려 왕복이 어긋난다.
        let cache = AccountCache(email: "someone@example.com",
                                 organizationUuid: "org-team",
                                 organizationName: "Team",
                                 sessionFingerprint: "6f5cc43e4293b697",
                                 checkedAt: Date(timeIntervalSince1970: 1_785_000_000))

        #expect(UsageSharedStore.save(cache, to: url))
        #expect(UsageSharedStore.loadAccount(from: url) == cache)
    }

    @Test("캐시 파일이 없거나 깨져 있으면 없는 것으로 본다")
    func treatsUnreadableCacheAsAbsent() throws {
        // 캐시는 언제든 버려도 되는 값이다. 못 읽으면 다시 조회하면 되므로 던지지 않는다.
        #expect(UsageSharedStore.loadAccount(from: Self.temporaryURL()) == nil)

        let corrupt = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: corrupt) }
        try Data("{ 파일이 반쯤 쓰였다".utf8).write(to: corrupt)

        #expect(UsageSharedStore.loadAccount(from: corrupt) == nil)
    }

    /// 이미 한 번 조회해 둔 상태.
    private static let cached = AccountCache(email: "someone@example.com",
                                            organizationUuid: "org-team",
                                            organizationName: "Team",
                                            sessionFingerprint: "6f5cc43e4293b697",
                                            checkedAt: Date(timeIntervalSince1970: 1_785_000_000))

    @Test("캐시가 없으면 계정을 다시 조회한다")
    func refreshesWhenCacheIsMissing() {
        #expect(AccountIdentity.needsRefresh(cache: nil,
                                             sessionFingerprint: "6f5cc43e4293b697",
                                             selectedOrganization: nil))
    }

    @Test("세션 지문이 달라지면 로그인이 바뀐 것이므로 다시 조회한다")
    func refreshesWhenSessionChanged() {
        // 데스크톱 앱에서 다른 계정으로 로그인하면 세션 쿠키가 교체된다. 캐시된 이메일을
        // 그대로 쓰면 이전 계정 이름 아래에 새 계정 숫자를 보여주게 된다.
        #expect(AccountIdentity.needsRefresh(cache: Self.cached,
                                             sessionFingerprint: "5fc9af1048a85990",
                                             selectedOrganization: nil))
    }

    @Test("고른 조직을 바꾸면 그 조직 기준으로 다시 조회한다")
    func refreshesWhenSelectedOrganizationChanged() {
        #expect(AccountIdentity.needsRefresh(cache: Self.cached,
                                             sessionFingerprint: "6f5cc43e4293b697",
                                             selectedOrganization: "org-personal"))
    }

    @Test("자동 선택이면 캐시된 조직을 불일치로 보지 않는다")
    func doesNotRefreshWhenOrganizationIsChosenAutomatically() {
        // selectedOrganization 이 nil 은 "사용자가 지정하지 않음"이고, 캐시의 조직은 자동
        // 선택이 고른 결과다. 이 둘을 불일치로 보면 조회마다 계정을 다시 물어본다.
        #expect(AccountIdentity.needsRefresh(cache: Self.cached,
                                             sessionFingerprint: "6f5cc43e4293b697",
                                             selectedOrganization: nil) == false)
    }

    @Test("세션과 조직이 그대로면 캐시를 그대로 쓴다")
    func keepsCacheWhenNothingChanged() {
        #expect(AccountIdentity.needsRefresh(cache: Self.cached,
                                             sessionFingerprint: "6f5cc43e4293b697",
                                             selectedOrganization: "org-team") == false)
    }
}
