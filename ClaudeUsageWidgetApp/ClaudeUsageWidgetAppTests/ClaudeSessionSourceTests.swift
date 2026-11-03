//
//  ClaudeSessionSourceTests.swift
//  ClaudeUsageWidgetAppTests
//
//  쿠키 원본 선택값이 «어디서 세션을 찾을지»로 어떻게 풀리는지 고정한다.
//
//  기본 브라우저는 이 컴퓨터의 LaunchServices 설정에 달려 있어 테스트에서 정할 수 없다.
//  그래서 `candidates` 가 기본 브라우저를 파라미터로 받고, 여기서는 직접 넣어 확인한다.
//

import Foundation
import Testing

struct ClaudeSessionSourceTests {
    private static let chrome = DefaultBrowser(name: "Google Chrome",
                                               source: BrowserCookieSource.source(id: "chrome"))
    private static let safari = DefaultBrowser(name: "Safari",
                                               source: BrowserCookieSource.source(id: "safari"))

    @Test("앱 로그인 창을 고르면 브라우저는 보지 않는다")
    func appSelectionUsesOnlyWebView() {
        let (sources, problem) = ClaudeSessionSource.candidates(for: CookieSourceSelection.app,
                                                                defaultBrowser: Self.chrome)

        #expect(problem == nil)
        #expect(sources == [.appWebView])
    }

    @Test("자동은 앱 세션을 먼저 보고 기본 브라우저로 넘어간다")
    func autoPrefersWebViewThenFallsBackToBrowser() {
        // 이미 앱에 로그인해 둔 사용자의 계정이 브라우저 계정으로 조용히 바뀌면 안 된다.
        // 브라우저로는 앱 세션이 «재로그인이 필요하다»고 할 때만 넘어간다.
        let (sources, problem) = ClaudeSessionSource.candidates(for: CookieSourceSelection.auto,
                                                                defaultBrowser: Self.chrome)

        #expect(problem == nil)
        #expect(sources.count == 2)
        #expect(sources.first == .appWebView)
        #expect(sources.last?.signsInWithBrowser == true)
    }

    @Test("기본 브라우저를 읽을 수 없으면 자동은 앱 세션만 쓴다")
    func autoSkipsBrowsersItCannotRead() {
        // Safari 가 기본이어도 앱 세션으로는 계속 돌아가야 한다.
        let (sources, problem) = ClaudeSessionSource.candidates(for: CookieSourceSelection.auto,
                                                                defaultBrowser: Self.safari)

        #expect(problem == nil)
        #expect(sources == [.appWebView])
    }

    @Test("기본 브라우저를 골랐는데 읽을 수 없으면 사유를 준다")
    func defaultBrowserSelectionExplainsUnsupportedBrowser() {
        // 조용히 앱 세션으로 넘어가면 사용자는 왜 브라우저가 안 쓰이는지 알 수 없다.
        let (sources, problem) = ClaudeSessionSource.candidates(for: CookieSourceSelection.defaultBrowser,
                                                                defaultBrowser: Self.safari)

        #expect(sources.isEmpty)
        #expect(problem?.contains("Safari") == true)
    }

    @Test("기본 브라우저를 모르면 직접 고르라고 한다")
    func defaultBrowserSelectionNeedsAKnownBrowser() {
        let (sources, problem) = ClaudeSessionSource.candidates(for: CookieSourceSelection.defaultBrowser,
                                                                defaultBrowser: nil)

        #expect(sources.isEmpty)
        #expect(problem?.isEmpty == false)
    }

    @Test("모르는 선택값은 앱 로그인 창으로 되돌린다")
    func unknownSelectionFallsBackToWebView() {
        // 설정 파일에 남은 옛 값이나 지워진 브라우저 id 로도 조회가 멈추면 안 된다.
        let (sources, problem) = ClaudeSessionSource.candidates(for: "브라우저아님",
                                                                defaultBrowser: Self.chrome)

        #expect(problem == nil)
        #expect(sources == [.appWebView])
    }

    @Test("특정 브라우저를 고르면 기본 브라우저와 무관하게 그것만 본다")
    func explicitBrowserIgnoresTheDefault() {
        let (sources, problem) = ClaudeSessionSource.candidates(for: "firefox",
                                                                defaultBrowser: Self.chrome)

        #expect(problem == nil)
        #expect(sources == [.browser(BrowserCookieSource.source(id: "firefox")!)])
    }

    @Test("브라우저 소스만 브라우저로 로그인한다")
    func onlyBrowserSourcesSignInThroughABrowser() {
        // 로그인 버튼이 브라우저를 열지 앱 창을 열지는 이 값으로 갈린다.
        #expect(ClaudeSessionSource.appWebView.signsInWithBrowser == false)
        #expect(ClaudeSessionSource.browser(BrowserCookieSource.source(id: "chrome")!)
            .signsInWithBrowser == true)
    }
}

struct BrowserCookieSourceTests {
    @Test("id 로 브라우저를 찾는다")
    func findsSourceByIdentifier() {
        #expect(BrowserCookieSource.source(id: "chrome")?.displayName == "Google Chrome")
        #expect(BrowserCookieSource.source(id: "없는브라우저") == nil)
    }

    @Test("번들 ID 는 대소문자를 가리지 않는다")
    func matchesBundleIdentifierCaseInsensitively() {
        // LaunchServices 는 `com.google.Chrome` 처럼 대문자가 섞인 값을 돌려준다.
        #expect(BrowserCookieSource.source(bundleID: "com.google.Chrome")?.id == "chrome")
        #expect(BrowserCookieSource.source(bundleID: "com.apple.Safari")?.id == "safari")
    }

    @Test("읽을 수 없는 브라우저는 사유를 들고 있다")
    func unsupportedSourceCarriesReason() {
        let safari = BrowserCookieSource.source(id: "safari")

        #expect(safari?.isSupported == false)
        #expect(safari?.unsupportedReason?.isEmpty == false)
    }

    @Test("UA 는 쿠키를 꺼낸 브라우저를 따른다")
    func userAgentMatchesTheBrowserTheCookiesCameFrom() {
        // cf_clearance 는 UA 에 묶여 있다. 쿠키를 꺼낸 브라우저와 다른 UA 로 보내면
        // 같은 쿠키인데도 Cloudflare 챌린지를 받을 수 있다.
        let chrome = BrowserCookieSource.source(id: "chrome")?.userAgent(majorVersion: "140")
        let firefox = BrowserCookieSource.source(id: "firefox")?.userAgent(majorVersion: "142")

        #expect(chrome?.contains("Chrome/140.0.0.0") == true)
        #expect(firefox?.contains("Firefox/142.0") == true)
    }

    @Test("버전을 모르면 UA 를 포기하지 않고 최근 버전을 쓴다")
    func userAgentStillWorksWithoutAnInstalledVersion() {
        let chrome = BrowserCookieSource.source(id: "chrome")?.userAgent(majorVersion: nil)

        #expect(chrome?.contains("Chrome/") == true)
    }

    @Test("모든 브라우저가 서로 다른 id 를 쓴다")
    func identifiersAreUnique() {
        // id 는 설정 파일에 저장되므로 겹치면 엉뚱한 브라우저를 읽는다.
        let ids = BrowserCookieSource.all.map(\.id)

        #expect(Set(ids).count == ids.count)
    }
}
