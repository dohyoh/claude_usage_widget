//
//  OrganizationChoiceTests.swift
//  ClaudeUsageWidgetAppTests
//
//  조직 선택은 claude.ai 조회와 분리된 결정 로직이다. 조직 목록·사용자가 고른 조직·
//  쿠키의 마지막 활성 조직을 넣으면 어느 조직의 사용량을 볼지가 정해진다.
//
//  네트워크가 끼지 않으므로 규칙을 여기서 전부 고정한다.
//

// 테스트 타깃은 Shared/ 를 직접 컴파일한다. 호스트 앱을 띄우지 않으므로
// `@testable import` 없이 같은 모듈로 접근하고, 앱 시작 부수효과(타이머·키체인)도 없다.
import Testing

struct OrganizationChoiceTests {
    /// claude.ai `/api/organizations` 응답을 흉내낸 목록.
    ///
    /// 첫 조직에 `chat` 권한이 없어 "목록의 첫 조직"과 "chat 권한이 있는 조직"이
    /// 서로 다른 값이 된다 — 규칙을 헷갈리지 않게 하려는 배치다.
    private static let organizations = [
        OrganizationSummary(uuid: "org-api", name: "API only", capabilities: ["api"]),
        OrganizationSummary(uuid: "org-team", name: "Team", capabilities: ["chat", "claude_pro"]),
        OrganizationSummary(uuid: "org-personal", name: "Personal", capabilities: ["chat"]),
    ]

    @Test("사용자가 고른 조직이 목록에 있으면 그것을 쓴다")
    func picksPreferredOrganization() {
        let result = OrganizationChoice.select(from: Self.organizations,
                                               preferred: "org-personal",
                                               lastActive: "org-team")

        #expect(result.organization?.uuid == "org-personal")
        #expect(result.fellBackFromMissingSelection == false)
    }

    @Test("고른 조직이 없으면 쿠키의 마지막 활성 조직을 쓴다")
    func fallsBackToLastActiveOrganization() {
        let result = OrganizationChoice.select(from: Self.organizations,
                                              preferred: nil,
                                              lastActive: "org-team")

        #expect(result.organization?.uuid == "org-team")
        #expect(result.fellBackFromMissingSelection == false)
    }

    @Test("고른 조직도 마지막 활성 조직도 없으면 chat 권한이 있는 첫 조직을 쓴다")
    func picksFirstChatCapableOrganization() {
        let result = OrganizationChoice.select(from: Self.organizations,
                                              preferred: nil,
                                              lastActive: nil)

        // 목록의 첫 조직(org-api)은 chat 권한이 없다. 사용량 한도를 갖는 건 구독 조직뿐이므로
        // "첫 조직"이 아니라 "chat 권한이 있는 첫 조직"을 골라야 한다.
        #expect(result.organization?.uuid == "org-team")
        #expect(result.fellBackFromMissingSelection == false)
    }

    @Test("chat 권한을 가진 조직이 하나도 없으면 목록의 첫 조직을 쓴다")
    func picksFirstOrganizationWhenNoneSupportChat() {
        // 권한 구성이 예상과 다를 수 있다. 그때 아무것도 못 고르고 멈추기보다 첫 조직으로
        // 조회를 시도해 본다 — 실패하면 호출자가 오류로 처리한다.
        let noChat = [
            OrganizationSummary(uuid: "org-api", name: "API only", capabilities: ["api"]),
            OrganizationSummary(uuid: "org-blank", name: nil, capabilities: []),
        ]

        let result = OrganizationChoice.select(from: noChat, preferred: nil, lastActive: nil)

        #expect(result.organization?.uuid == "org-api")
        #expect(result.fellBackFromMissingSelection == false)
    }

    @Test("고른 조직이 목록에서 사라지면 자동 선택으로 되돌리고 그 사실을 알린다")
    func reportsFallbackWhenSelectionIsMissing() {
        // 조직에서 탈퇴하거나 계정이 바뀌면 저장된 선택이 무효가 된다. 조용히 다른 조직
        // 숫자를 보여주면 사용자는 잘못된 계정의 사용량을 자기 것으로 읽는다.
        let result = OrganizationChoice.select(from: Self.organizations,
                                              preferred: "org-left-behind",
                                              lastActive: nil)

        #expect(result.organization?.uuid == "org-team")
        #expect(result.fellBackFromMissingSelection == true)
    }
}
