//
//  ClaudeCookieJar.swift
//  ClaudeUsageWidgetApp
//
//  claude.ai 에 붙을 때 필요한 쿠키 모음.
//
//  자체 로그인으로 바꾸면 쿠키는 데스크톱 앱의 SQLite 파일이 아니라 우리 웹뷰의
//  WKHTTPCookieStore 에서 온다. 조립 규칙 자체는 WebKit 과 무관한 순수 로직이라
//  여기에 둬서 따로 검증한다.
//

import Foundation

struct ClaudeCookieJar: Sendable {
    /// 브라우저가 보내듯 합친 `name=value; …` 헤더.
    let cookieHeader: String
    /// 마지막으로 활성화된 조직 UUID(있으면).
    let lastActiveOrg: String?
    /// 로그인 세션 쿠키가 있는지.
    let hasSession: Bool

    /// 로그인의 증거가 되는 쿠키 이름.
    ///
    /// 로그인 화면만 열어도 Cloudflare·분석 쿠키가 여러 개 생기므로, 쿠키가 있다는 것만으로는
    /// 로그인 여부를 알 수 없다.
    static let sessionCookieNames: Set<String> = ["sessionKey", "sessionKeyLC"]

    init(cookieHeader: String, lastActiveOrg: String?, hasSession: Bool) {
        self.cookieHeader = cookieHeader
        self.lastActiveOrg = lastActiveOrg
        self.hasSession = hasSession
    }

    /// 웹뷰의 쿠키 저장소에서 받은 쿠키로 조립한다.
    ///
    /// 저장소에는 SSO 왕복에서 생긴 Google·hCaptcha 쿠키도 함께 들어 있다. 그걸 claude.ai
    /// 요청에 실어 보내면 남의 도메인 자격증명을 흘리는 셈이므로 도메인으로 걸러낸다.
    init(cookies: [HTTPCookie]) {
        let claude = cookies.filter { $0.domain.hasSuffix("claude.ai") }
        cookieHeader = claude.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        lastActiveOrg = claude.first { $0.name == "lastActiveOrg" }?.value
        hasSession = claude.contains { Self.sessionCookieNames.contains($0.name) }
    }
}
