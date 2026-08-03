//
//  ClaudeAccountResponse.swift
//  ClaudeUsageWidgetApp
//
//  `/api/account` 응답에서 계정 식별에 필요한 것만 뽑는다.
//
//  이메일이 있어야 "같은 팀 조직의 다른 멤버로 로그인했다" 를 잡을 수 있다. 그 경우
//  organizationUuid 는 일치하므로 조직만 비교하면 놓친다.
//
//  이 조회는 매번 하지 않는다. 로그인이나 조직이 바뀌었을 때만(AccountIdentity.needsRefresh)
//  한 번 부른다.
//

import Foundation

enum ClaudeAccountResponse {
    /// 응답에서 계정 이메일을 꺼낸다. 없거나 형식이 어긋나면 nil.
    ///
    /// 이메일을 못 얻어도 조직 단위 비교는 계속 되므로 실패를 오류로 올리지 않는다.
    static func email(fromJSON data: Data) -> String? {
        struct Response: Decodable {
            let email_address: String?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        guard let email = decoded.email_address, !email.isEmpty else { return nil }
        return email
    }
}
