//
//  ClaudeCookieJar.swift
//  ClaudeUsageWidgetApp
//
//  claude.ai 에 붙을 때 필요한 쿠키 모음.
//
//  쿠키는 우리 웹뷰의 WKHTTPCookieStore 에서 오거나, 시스템 기본 브라우저의 쿠키
//  저장소에서 온다(`BrowserCookieStore`). 어느 쪽이든 `[HTTPCookie]` 로 들어오므로
//  조립 규칙은 한 곳에만 있다. 이 로직은 WebKit 과 무관한 순수 로직이라 따로 검증한다.
//

import Foundation

struct ClaudeCookieJar: Sendable {
    /// 브라우저가 보내듯 합친 `name=value; …` 헤더.
    let cookieHeader: String
    /// 마지막으로 활성화된 조직 UUID(있으면).
    let lastActiveOrg: String?
    /// 로그인 세션 쿠키가 있는지.
    let hasSession: Bool
    /// 세션 쿠키의 지문. 로그인하지 않았으면 nil.
    ///
    /// 계정 캐시를 언제 버릴지 판단하는 데만 쓴다. 이 값을 jar 가 직접 주기 때문에 원시
    /// 세션 키가 코드 여러 곳을 돌아다니지 않는다.
    let sessionFingerprint: String?

    /// 이 쿠키를 보낼 때 함께 쓸 User-Agent.
    ///
    /// `cf_clearance` 는 UA 에 묶여 있다. 쿠키를 꺼낸 곳과 다른 UA 로 보내면 같은 쿠키인데도
    /// Cloudflare 챌린지를 받을 수 있어서, 출처에 맞는 UA 를 쿠키와 함께 들고 다닌다.
    let userAgent: String

    /// 앱 안의 로그인 창(WKWebView)이 쓰는 UA.
    static let webViewUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// 로그인의 증거가 되는 쿠키 이름.
    ///
    /// 로그인 화면만 열어도 Cloudflare·분석 쿠키가 여러 개 생기므로, 쿠키가 있다는 것만으로는
    /// 로그인 여부를 알 수 없다.
    static let sessionCookieNames: Set<String> = ["sessionKey", "sessionKeyLC"]

    init(cookieHeader: String, lastActiveOrg: String?, hasSession: Bool,
         sessionFingerprint: String? = nil,
         userAgent: String = ClaudeCookieJar.webViewUserAgent) {
        self.cookieHeader = cookieHeader
        self.lastActiveOrg = lastActiveOrg
        self.hasSession = hasSession
        self.sessionFingerprint = sessionFingerprint
        self.userAgent = userAgent
    }

    /// 웹뷰의 쿠키 저장소에서 받은 쿠키로 조립한다.
    ///
    /// 저장소에는 SSO 왕복에서 생긴 Google·hCaptcha 쿠키도 함께 들어 있다. 그걸 claude.ai
    /// 요청에 실어 보내면 남의 도메인 자격증명을 흘리는 셈이므로 도메인으로 걸러낸다.
    init(cookies: [HTTPCookie], userAgent: String = ClaudeCookieJar.webViewUserAgent) {
        self.userAgent = userAgent
        let claude = cookies.filter { $0.domain.hasSuffix("claude.ai") }
        cookieHeader = claude.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        lastActiveOrg = claude.first { $0.name == "lastActiveOrg" }?.value

        let session = claude.first { Self.sessionCookieNames.contains($0.name) }
        hasSession = session != nil
        sessionFingerprint = session.map { AccountIdentity.fingerprint(sessionKey: $0.value) }
    }
}
