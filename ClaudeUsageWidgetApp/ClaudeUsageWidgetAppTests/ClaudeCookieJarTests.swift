//
//  ClaudeCookieJarTests.swift
//  ClaudeUsageWidgetAppTests
//
//  자체 로그인으로 바꾸면 쿠키는 SQLite 파일이 아니라 WKHTTPCookieStore 에서 온다.
//  그 조립 규칙은 WebKit 과 무관한 순수 로직이라 여기서 고정한다.
//

import Foundation
import Testing

struct ClaudeCookieJarTests {
    private static func cookie(_ name: String, _ value: String,
                              domain: String = ".claude.ai") -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
        ])!
    }

    @Test("claude.ai 쿠키로 헤더를 만들고 sessionKey 가 있으면 세션으로 본다")
    func buildsHeaderAndDetectsSession() {
        let jar = ClaudeCookieJar(cookies: [
            Self.cookie("sessionKey", "sk-ant-sid01-EXAMPLE"),
            Self.cookie("lastActiveOrg", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
        ])

        #expect(jar.hasSession)
        // 순서에 의존하지 않게 조각으로 비교한다.
        #expect(Set(jar.cookieHeader.components(separatedBy: "; "))
                == ["sessionKey=sk-ant-sid01-EXAMPLE",
                    "lastActiveOrg=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"])
    }

    @Test("로그인 전에도 추적 쿠키는 있다 — 세션 쿠키만이 로그인의 증거다")
    func doesNotMistakeTrackingCookiesForSession() {
        // 로그인 화면만 열어도 Cloudflare·분석 쿠키가 여러 개 생긴다. 그걸 세션으로 보면
        // 로그인하지 않은 사용자에게 조회를 시도하고 엉뚱한 오류를 보여준다.
        let jar = ClaudeCookieJar(cookies: [
            Self.cookie("cf_clearance", "abc"),
            Self.cookie("anthropic-device-id", "def"),
            Self.cookie("ajs_anonymous_id", "ghi"),
        ])

        #expect(jar.hasSession == false)
    }

    @Test("sessionKeyLC 도 로그인 세션으로 인정한다")
    func acceptsLowerCaseSessionCookie() {
        let jar = ClaudeCookieJar(cookies: [Self.cookie("sessionKeyLC", "sk-ant-sid01-EXAMPLE")])

        #expect(jar.hasSession)
    }

    @Test("lastActiveOrg 쿠키에서 조직을 꺼낸다")
    func extractsLastActiveOrganization() {
        let jar = ClaudeCookieJar(cookies: [
            Self.cookie("sessionKey", "sk-ant-sid01-EXAMPLE"),
            Self.cookie("lastActiveOrg", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
        ])

        #expect(jar.lastActiveOrg == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    @Test("claude.ai 가 아닌 도메인의 쿠키는 넣지 않는다")
    func dropsCookiesFromOtherDomains() {
        // 웹뷰의 저장소에는 SSO 왕복에서 생긴 Google·hCaptcha 쿠키도 함께 들어 있다.
        // 그걸 claude.ai 요청에 실어 보낼 이유가 없고, 남의 도메인 자격증명을 흘리는 셈이다.
        let jar = ClaudeCookieJar(cookies: [
            Self.cookie("sessionKey", "sk-ant-sid01-EXAMPLE"),
            Self.cookie("SID", "google-session", domain: ".google.com"),
            Self.cookie("hc_accessibility", "x", domain: ".hcaptcha.com"),
        ])

        #expect(jar.cookieHeader == "sessionKey=sk-ant-sid01-EXAMPLE")
    }

    @Test("세션 지문을 jar 가 직접 준다 — 원시 세션 키는 내보내지 않는다")
    func exposesSessionFingerprintWithoutLeakingKey() {
        // 계정 캐시 무효화 판단에 지문이 필요하다. 그걸 위해 세션 키 자체를 꺼내 쓰면
        // 자격증명이 코드 여러 곳을 돌아다닌다.
        //
        // 기대값은 AccountIdentityTests 와 같은 독립 계산이다:
        //   printf '%s' 'sk-ant-sid01-EXAMPLE-SESSION-KEY' | shasum -a 256 | cut -c1-16
        let signedIn = ClaudeCookieJar(cookies: [
            Self.cookie("sessionKey", "sk-ant-sid01-EXAMPLE-SESSION-KEY"),
        ])
        #expect(signedIn.sessionFingerprint == "6f5cc43e4293b697")

        let signedOut = ClaudeCookieJar(cookies: [Self.cookie("cf_clearance", "abc")])
        #expect(signedOut.sessionFingerprint == nil)
    }
}
