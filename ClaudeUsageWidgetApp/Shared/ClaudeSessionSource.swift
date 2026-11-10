//
//  ClaudeSessionSource.swift
//  ClaudeUsageWidgetApp
//
//  claude.ai 세션을 어디서 가져올지 — 앱 안의 로그인 창이냐, 시스템 기본 브라우저냐.
//
//  앱 로그인 창은 쿠키·지문이 조회와 완전히 같다는 장점이 있지만, 평소 쓰는 브라우저와
//  별개라 로그인을 한 번 더 해야 한다. 브라우저 세션을 쓰면 그 과정이 사라지는 대신
//  쿠키를 다른 클라이언트로 옮기는 셈이라, UA 를 그 브라우저에 맞춰 보낸다
//  (`BrowserCookieSource.userAgent(majorVersion:)`).
//
//  «어느 순서로 시도할지»는 설정값만으로 결정되는 순수 로직이라 여기에 둔다. 실제로 세션을
//  꺼내는 일(WebKit·키체인)은 메뉴바 앱 타겟의 확장에 있다.
//

import Foundation

/// 설정에 저장되는 쿠키 원본 선택값. 특정 브라우저는 `BrowserCookieSource.id` 를 그대로 쓴다.
enum CookieSourceSelection {
    /// 앱 세션을 먼저 쓰고, 만료됐으면 기본 브라우저.
    static let auto = "auto"
    /// 앱 안의 로그인 창만.
    static let app = "app"
    /// 시스템 기본 브라우저만.
    static let defaultBrowser = "default-browser"

    /// 설정 화면에 보여줄 이름.
    static func title(for selection: String, browser: DefaultBrowser?) -> String {
        switch selection {
        case auto:
            return "자동 (앱 세션 → 기본 브라우저)"
        case app:
            return "앱 안의 로그인 창"
        case defaultBrowser:
            guard let browser else { return "기본 브라우저" }
            return "기본 브라우저 (\(browser.name))"
        default:
            return BrowserCookieSource.source(id: selection)?.displayName ?? selection
        }
    }
}

enum ClaudeSessionSource: Sendable, Equatable {
    /// 앱 안의 로그인 창이 만든 WKWebsiteDataStore 세션.
    case appWebView
    /// 브라우저의 쿠키 저장소.
    case browser(BrowserCookieSource)

    var displayName: String {
        switch self {
        case .appWebView: return "앱 로그인 창"
        case .browser(let source): return source.displayName
        }
    }

    /// 이 소스에서 로그인하려면 브라우저를 열어야 하는지.
    var signsInWithBrowser: Bool {
        if case .browser = self { return true }
        return false
    }
}

// MARK: - 후보 결정

extension ClaudeSessionSource {
    /// 이 선택값으로 차례로 시도할 소스들. 비어 있으면 `problem` 에 이유가 담긴다.
    ///
    /// 앞의 소스가 «재로그인이 필요하다»고 하거나 **세션을 꺼내지 못했을 때만** 다음
    /// 소스로 넘어간다(`ClaudeServerUsage.fetch` 참고). 일시적 실패에 소스를 바꾸면
    /// 사용자가 보는 계정이 네트워크 사정에 따라 왔다 갔다 한다.
    ///
    /// **브라우저를 고른 경우에도 앱 세션을 뒤에 둔다.** macOS 27 부터 OS 가 브라우저
    /// 프로필 폴더를 통째로 막을 수 있어(앱 데이터 보호), 브라우저 하나만 두면 사용자가
    /// 아무것도 못 보는 상태에서 빠져나올 길이 없다. 다른 계정의 숫자를 조용히 보여주지
    /// 않도록, 고른 소스가 아닌 쪽으로 넘어갔으면 조회 결과가 그 사실을 알린다
    /// (`ServerUsage.fallbackNotice`).
    ///
    /// - Parameter defaultBrowser: 시스템 기본 브라우저. 모르면 nil.
    static func candidates(for selection: String,
                           defaultBrowser browser: DefaultBrowser?) -> (sources: [ClaudeSessionSource],
                                                                        problem: String?) {
        switch selection {
        case CookieSourceSelection.app:
            return ([.appWebView], nil)

        case CookieSourceSelection.defaultBrowser:
            guard let browser else {
                return ([], "기본 브라우저를 확인할 수 없습니다. 쿠키 원본을 직접 고르세요.")
            }
            guard let source = browser.source else {
                return ([], "기본 브라우저(\(browser.name))의 쿠키는 읽을 수 없습니다. 지원하는 브라우저를 기본으로 두거나, 쿠키 원본을 «앱 안의 로그인 창»으로 바꾸세요.")
            }
            guard source.isSupported else { return ([], source.unsupportedReason) }
            return ([.browser(source), .appWebView], nil)

        case CookieSourceSelection.auto:
            // 이미 앱에 로그인해 둔 사용자의 계정이 조용히 바뀌지 않도록 앱 세션이 먼저다.
            // 그 세션이 만료되면(401) 기본 브라우저로 넘어가므로, 재로그인은 브라우저에서 된다.
            var sources: [ClaudeSessionSource] = [.appWebView]
            if let source = browser?.source, source.isSupported {
                sources.append(.browser(source))
            }
            return (sources, nil)

        default:
            // 설정 파일에 남은 옛 값이나 지워진 브라우저 id 로도 조회가 멈추면 안 된다.
            guard let source = BrowserCookieSource.source(id: selection) else {
                return ([.appWebView], nil)
            }
            guard source.isSupported else { return ([], source.unsupportedReason) }
            return ([.browser(source), .appWebView], nil)
        }
    }
}
