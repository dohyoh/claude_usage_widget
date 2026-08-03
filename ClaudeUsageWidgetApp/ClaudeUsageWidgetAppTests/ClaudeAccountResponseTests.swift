//
//  ClaudeAccountResponseTests.swift
//  ClaudeUsageWidgetAppTests
//
//  /api/account 응답에서 계정 이메일을 꺼낸다.
//
//  이메일이 있어야 "같은 팀 조직의 다른 멤버로 로그인했다" 를 잡을 수 있다. 그 경우
//  organizationUuid 는 일치하므로 조직만 비교하면 놓친다.
//
//  픽스처는 스파이크로 확인한 실제 응답 형태다 — 최상위에 email_address 가 있다.
//

import Foundation
import Testing

struct ClaudeAccountResponseTests {
    @Test("계정 응답에서 이메일을 꺼낸다")
    func extractsEmailAddress() {
        // 관심 없는 키를 섞어 둔다. 응답에 새 필드가 생겨도 깨지지 않아야 한다.
        let json = """
        {"uuid":"11111111-2222-3333-4444-555555555555",
         "email_address":"someone@example.com",
         "full_name":"Someone",
         "has_claude_pro":true,
         "settings":{"theme":"dark"}}
        """

        #expect(ClaudeAccountResponse.email(fromJSON: Data(json.utf8)) == "someone@example.com")
    }

    @Test("이메일이 없거나 응답이 깨져 있으면 없는 것으로 본다")
    func treatsMissingEmailAsAbsent() {
        // 이메일을 못 얻어도 조직 단위 비교는 계속 되므로 던지지 않는다.
        #expect(ClaudeAccountResponse.email(fromJSON: Data(#"{"uuid":"x"}"#.utf8)) == nil)
        #expect(ClaudeAccountResponse.email(fromJSON: Data("{ 반쯤 쓰인 응답".utf8)) == nil)
    }
}
