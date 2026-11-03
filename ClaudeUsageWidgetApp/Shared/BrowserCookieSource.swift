//
//  BrowserCookieSource.swift
//  ClaudeUsageWidgetApp
//
//  시스템 기본 브라우저에 있는 claude.ai 세션을 쓰기 위한 소스 정의.
//
//  앱 안의 로그인 창(`ClaudeLoginWindow`)은 평소 쓰는 브라우저와 별개의 창이라, 브라우저에
//  이미 로그인해 두었어도 거기서 한 번 더 로그인해야 한다. 기본 브라우저의 쿠키를 그대로
//  읽으면 그 과정이 통째로 사라진다 — 인증은 늘 쓰던 브라우저에서 한 번만 하면 된다.
//
//  지원 범위:
//  - Chromium 계열(Chrome·Edge·Brave·웨일·Arc·Vivaldi·Chromium)은 쿠키 DB 구조와 암호화
//    방식이 같다. 키체인의 "<브랜드> Safe Storage" 항목만 다르다.
//  - Firefox 계열은 cookies.sqlite 에 값이 평문으로 들어 있어 키가 필요 없다.
//  - Safari 는 쿠키가 TCC(전체 디스크 접근) 보호 영역의 binarycookies 형식이라 못 읽는다.
//
//  목록·경로·UA 조립은 AppKit 없이 결정되는 순수 로직이라 Shared 에 두고 따로 검증한다.
//  설치된 앱을 찾아보는 부분(기본 브라우저·버전)은 메뉴바 앱 타겟의 확장에 있다.
//

import Foundation

/// 쿠키를 읽어올 브라우저 하나.
struct BrowserCookieSource: Identifiable, Hashable, Sendable {
    enum Store: Hashable, Sendable {
        /// Chromium 방식: SQLite + 키체인의 Safe Storage 키로 AES 복호화.
        case chromium(keychainService: String, keychainAccount: String)
        /// Firefox 방식: cookies.sqlite 의 평문 값.
        case firefox
        /// 읽을 수 없는 브라우저. 이유를 그대로 사용자에게 보여준다.
        case unsupported(reason: String)
    }

    /// 설정 파일에 저장되는 안정적인 식별자.
    let id: String
    let displayName: String
    /// 기본 브라우저 판별과 버전 조회에 쓰는 번들 ID(소문자).
    let bundleIDs: [String]
    let store: Store
    /// 프로필을 찾기 시작할 디렉터리. 홈 기준 상대 경로.
    let userDataPath: String
    /// 프로필 디렉터리 안의 쿠키 파일 이름.
    let cookieFileName: String

    /// 쿠키를 실제로 읽을 수 있는지. 설정 목록에 띄울지 판단한다.
    var isSupported: Bool {
        if case .unsupported = store { return false }
        return true
    }

    /// 읽을 수 없는 브라우저의 사유.
    var unsupportedReason: String? {
        if case .unsupported(let reason) = store { return reason }
        return nil
    }
}

// MARK: - 목록

extension BrowserCookieSource {
    static let all: [BrowserCookieSource] = [
        BrowserCookieSource(id: "chrome", displayName: "Google Chrome",
                            bundleIDs: ["com.google.chrome", "com.google.chrome.canary"],
                            store: .chromium(keychainService: "Chrome Safe Storage",
                                             keychainAccount: "Chrome"),
                            userDataPath: "Library/Application Support/Google/Chrome",
                            cookieFileName: "Cookies"),
        BrowserCookieSource(id: "edge", displayName: "Microsoft Edge",
                            bundleIDs: ["com.microsoft.edgemac", "com.microsoft.edgemac.beta"],
                            store: .chromium(keychainService: "Microsoft Edge Safe Storage",
                                             keychainAccount: "Microsoft Edge"),
                            userDataPath: "Library/Application Support/Microsoft Edge",
                            cookieFileName: "Cookies"),
        BrowserCookieSource(id: "brave", displayName: "Brave",
                            bundleIDs: ["com.brave.browser", "com.brave.browser.beta"],
                            store: .chromium(keychainService: "Brave Safe Storage",
                                             keychainAccount: "Brave"),
                            userDataPath: "Library/Application Support/BraveSoftware/Brave-Browser",
                            cookieFileName: "Cookies"),
        BrowserCookieSource(id: "whale", displayName: "네이버 웨일",
                            bundleIDs: ["com.naver.whale"],
                            store: .chromium(keychainService: "Whale Safe Storage",
                                             keychainAccount: "Whale"),
                            userDataPath: "Library/Application Support/Naver/Whale",
                            cookieFileName: "Cookies"),
        BrowserCookieSource(id: "arc", displayName: "Arc",
                            bundleIDs: ["company.thebrowser.browser"],
                            store: .chromium(keychainService: "Arc Safe Storage",
                                             keychainAccount: "Arc"),
                            userDataPath: "Library/Application Support/Arc/User Data",
                            cookieFileName: "Cookies"),
        BrowserCookieSource(id: "vivaldi", displayName: "Vivaldi",
                            bundleIDs: ["com.vivaldi.vivaldi"],
                            store: .chromium(keychainService: "Vivaldi Safe Storage",
                                             keychainAccount: "Vivaldi"),
                            userDataPath: "Library/Application Support/Vivaldi",
                            cookieFileName: "Cookies"),
        BrowserCookieSource(id: "chromium", displayName: "Chromium",
                            bundleIDs: ["org.chromium.chromium"],
                            store: .chromium(keychainService: "Chromium Safe Storage",
                                             keychainAccount: "Chromium"),
                            userDataPath: "Library/Application Support/Chromium",
                            cookieFileName: "Cookies"),
        BrowserCookieSource(id: "firefox", displayName: "Firefox",
                            bundleIDs: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition"],
                            store: .firefox,
                            userDataPath: "Library/Application Support/Firefox/Profiles",
                            cookieFileName: "cookies.sqlite"),
        BrowserCookieSource(id: "safari", displayName: "Safari",
                            bundleIDs: ["com.apple.safari"],
                            store: .unsupported(reason: "Safari는 쿠키를 전체 디스크 접근 권한이 필요한 binarycookies 형식으로 저장해 읽을 수 없습니다. Chrome·Edge·Brave·웨일·Arc·Vivaldi·Firefox 중 하나를 기본 브라우저로 쓰거나, 쿠키 원본을 «앱 안의 로그인 창»으로 두세요."),
                            userDataPath: "Library/Containers/com.apple.Safari/Data/Library/Cookies",
                            cookieFileName: "Cookies.binarycookies"),
    ]

    static func source(id: String) -> BrowserCookieSource? {
        all.first { $0.id == id }
    }

    /// 번들 ID 로 브라우저를 찾는다. 대소문자는 구분하지 않는다 — LaunchServices 가
    /// 돌려주는 값과 Info.plist 의 표기가 다를 수 있다(`com.google.Chrome`).
    static func source(bundleID: String) -> BrowserCookieSource? {
        let lowered = bundleID.lowercased()
        return all.first { $0.bundleIDs.contains(lowered) }
    }
}

// MARK: - 쿠키 파일 찾기

extension BrowserCookieSource {
    /// 실제로 존재하는 쿠키 파일들. 최근에 쓴 프로필이 앞에 온다.
    ///
    /// 쿠키가 루트 바로 아래 있기도 하고 프로필 디렉터리(`Default`, `Profile 1`, Firefox의
    /// `xxxx.default-release`) 아래 있기도 해서 두 자리를 모두 본다. 어느 프로필로
    /// claude.ai 에 로그인했는지는 알 수 없으므로 세션이 나올 때까지 차례로 시도한다.
    var cookieFiles: [URL] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(userDataPath, isDirectory: true)
        var found: [URL] = []

        let direct = root.appendingPathComponent(cookieFileName, isDirectory: false)
        if fm.fileExists(atPath: direct.path) { found.append(direct) }

        let children = (try? fm.contentsOfDirectory(at: root,
                                                    includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let candidate = child.appendingPathComponent(cookieFileName, isDirectory: false)
            if fm.fileExists(atPath: candidate.path) { found.append(candidate) }
        }

        return found.sorted { Self.modified($0) > Self.modified($1) }
    }

    /// 이 브라우저의 쿠키 저장소가 이 컴퓨터에 있는지.
    var isPresent: Bool { !cookieFiles.isEmpty }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
}

// MARK: - User-Agent

extension BrowserCookieSource {
    /// 이 브라우저의 쿠키와 함께 보낼 User-Agent.
    ///
    /// `cf_clearance` 는 UA 에 묶여 있다. 브라우저에서 꺼낸 쿠키를 웹뷰의 Safari UA 로 보내면
    /// 같은 쿠키인데도 Cloudflare 챌린지를 받을 수 있어서, 쿠키를 꺼낸 브라우저의 UA 를
    /// 흉내 낸다.
    ///
    /// - Parameter majorVersion: 설치된 앱의 메이저 버전. 모르면 최근 버전을 쓴다.
    func userAgent(majorVersion: String?) -> String {
        switch store {
        case .firefox:
            let version = majorVersion ?? "133"
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:\(version).0) "
                + "Gecko/20100101 Firefox/\(version).0"
        case .chromium, .unsupported:
            let version = majorVersion ?? "131"
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/\(version).0.0.0 Safari/537.36"
        }
    }
}

/// LaunchServices 가 `https` 링크를 넘기는 앱 — 시스템 기본 브라우저.
struct DefaultBrowser: Sendable {
    /// 사용자에게 보여줄 이름.
    let name: String
    /// 쿠키를 읽을 수 있는 소스. 목록에 없는 브라우저면 nil.
    let source: BrowserCookieSource?
}
