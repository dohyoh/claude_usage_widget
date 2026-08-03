//
//  OrganizationResponseTests.swift
//  ClaudeUsageWidgetAppTests
//
//  /api/organizations 응답을 조직 선택이 쓰는 형태로 옮긴다.
//
//  픽스처는 스파이크로 확인한 실제 응답 형태를 가명화한 것이다. 첫 조직에 chat 권한이
//  없고 두 번째에 있다 — 이게 실제 계정에서 관측된 배치이고, 기존 `orgs.first` 폴백이
//  엉뚱한 조직을 잡았을 상황이다.
//

import Foundation
import Testing

struct OrganizationResponseTests {
    /// 관심 없는 키를 일부러 섞어 둔다. 응답에 새 필드가 생겨도 깨지지 않아야 한다.
    private static let organizationsJSON = """
    [
      {"uuid":"84affcca-0000-0000-0000-000000000001",
       "name":"someone's Individual Org",
       "capabilities":["api","api_individual"],
       "settings":{"preview_feature_uses_parameters":null},
       "created_at":"2025-08-03T11:20:21.162155Z"},
      {"uuid":"44fee189-0000-0000-0000-000000000002",
       "name":"Example Team",
       "capabilities":["chat","raven"],
       "join_token":null}
    ]
    """

    @Test("조직 응답을 순서와 권한을 유지하며 옮긴다")
    func mapsOrganizationsPreservingOrderAndCapabilities() throws {
        let organizations = try #require(
            OrganizationSummary.list(fromJSON: Data(Self.organizationsJSON.utf8)))

        #expect(organizations.count == 2)
        #expect(organizations[0].uuid == "84affcca-0000-0000-0000-000000000001")
        #expect(organizations[0].name == "someone's Individual Org")
        #expect(organizations[0].capabilities == ["api", "api_individual"])
        #expect(organizations[1].uuid == "44fee189-0000-0000-0000-000000000002")
        #expect(organizations[1].capabilities == ["chat", "raven"])

        // 실제 관측된 배치에서 자동 선택이 chat 조직을 고르는지 함께 확인한다.
        let chosen = OrganizationChoice.select(from: organizations,
                                              preferred: nil,
                                              lastActive: nil)
        #expect(chosen.organization?.uuid == "44fee189-0000-0000-0000-000000000002")
    }

    @Test("capabilities 가 없는 조직이 섞여도 목록 전체를 버리지 않는다")
    func toleratesOrganizationWithoutCapabilities() throws {
        // 권한 필드가 빠진 조직 하나 때문에 목록 전체가 무효가 되면, 볼 수 있었던 조직까지
        // 함께 잃는다.
        let json = """
        [{"uuid":"org-unknown","name":"No capabilities field"},
         {"uuid":"org-team","name":"Example Team","capabilities":["chat"]}]
        """

        let organizations = try #require(OrganizationSummary.list(fromJSON: Data(json.utf8)))

        #expect(organizations.count == 2)
        #expect(organizations[0].capabilities.isEmpty)
        #expect(OrganizationChoice.select(from: organizations, preferred: nil, lastActive: nil)
                .organization?.uuid == "org-team")
    }
}
