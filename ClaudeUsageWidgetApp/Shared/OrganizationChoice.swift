//
//  OrganizationChoice.swift
//  ClaudeUsageWidgetApp
//
//  어느 조직의 사용량을 조회할지 고르는 결정 로직. claude.ai 조회와 분리해 둔다 —
//  규칙이 바뀌어도 네트워크 코드를 건드리지 않고, 규칙만 따로 검증할 수 있다.
//

import Foundation

/// `/api/organizations` 응답에서 선택에 필요한 만큼만 뽑은 조직.
struct OrganizationSummary: Equatable, Sendable {
    let uuid: String
    let name: String?
    /// 조직이 가진 권한. 사용량 한도를 갖는 구독 조직은 `chat`을 포함한다.
    let capabilities: [String]

    /// `/api/organizations` 응답을 파싱한다. 형식이 어긋나면 nil.
    ///
    /// 응답에는 우리가 쓰지 않는 필드가 많고 앞으로 더 생길 수 있다. 관심 있는 키만 꺼낸다.
    static func list(fromJSON data: Data) -> [OrganizationSummary]? {
        struct Response: Decodable {
            let uuid: String
            let name: String?
            // 권한 필드가 빠진 조직 하나 때문에 목록 전체를 잃지 않도록 Optional 로 둔다.
            let capabilities: [String]?
        }
        guard let decoded = try? JSONDecoder().decode([Response].self, from: data) else { return nil }
        return decoded.map {
            OrganizationSummary(uuid: $0.uuid, name: $0.name, capabilities: $0.capabilities ?? [])
        }
    }
}

enum OrganizationChoice {
    /// 선택 결과.
    struct Result: Equatable, Sendable {
        /// 조회에 쓸 조직. 고를 수 있는 조직이 없으면 nil.
        let organization: OrganizationSummary?
        /// 사용자가 고른 조직이 목록에 없어 자동 선택으로 되돌렸는지.
        ///
        /// 조직에서 탈퇴하거나 계정이 바뀌면 저장된 선택이 무효가 된다. 조용히
        /// 다른 조직 숫자를 보여주지 않도록 이 사실을 호출자에게 알린다.
        let fellBackFromMissingSelection: Bool
    }

    /// 조직 목록에서 조회할 조직을 고른다.
    ///
    /// - Parameters:
    ///   - organizations: `/api/organizations`가 돌려준 목록.
    ///   - preferred: 사용자가 설정에서 고른 조직 UUID. nil이면 자동으로 고른다.
    ///   - lastActive: 쿠키의 `lastActiveOrg`.
    static func select(from organizations: [OrganizationSummary],
                       preferred: String?,
                       lastActive: String?) -> Result {
        if let preferred, let match = organizations.first(where: { $0.uuid == preferred }) {
            return Result(organization: match, fellBackFromMissingSelection: false)
        }
        // 고른 조직이 지정돼 있는데 목록에 없다 — 탈퇴했거나 계정이 바뀐 것이다. 아래 자동
        // 선택으로 내려가되, 조용히 다른 조직 숫자를 보여주지 않도록 사실을 남긴다.
        let fellBack = preferred != nil

        if let lastActive, let match = organizations.first(where: { $0.uuid == lastActive }) {
            return Result(organization: match, fellBackFromMissingSelection: fellBack)
        }
        if let chat = organizations.first(where: { $0.capabilities.contains("chat") }) {
            return Result(organization: chat, fellBackFromMissingSelection: fellBack)
        }
        return Result(organization: organizations.first, fellBackFromMissingSelection: fellBack)
    }
}
