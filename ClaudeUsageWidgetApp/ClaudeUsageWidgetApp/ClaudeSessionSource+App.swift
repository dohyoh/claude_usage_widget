//
//  ClaudeSessionSource+App.swift
//  ClaudeUsageWidgetApp
//
//  `ClaudeSessionSource` 중 이 컴퓨터를 들여다봐야 하는 부분 — 설치된 앱 찾기(기본 브라우저·
//  버전), 웹뷰·브라우저에서 실제로 쿠키 꺼내기, 복호화 키 캐시.
//
//  순수 결정 로직은 Shared 에 있고 거기서 검증한다. 여기는 AppKit·WebKit 에 닿는 부분만 둔다.
//

import Foundation
import AppKit

// MARK: - 설치된 앱 들여다보기

extension BrowserCookieSource {
    /// 시스템 기본 브라우저. 설정에서 바꾸면 다음 조회부터 바로 반영된다.
    static func defaultBrowser() -> DefaultBrowser? {
        guard let probe = URL(string: "https://claude.ai"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        let bundle = Bundle(url: appURL)
        let source = source(bundleID: bundle?.bundleIdentifier ?? "")
        // 아는 브라우저면 목록의 이름을, 모르는 브라우저면 번들이 알려주는 이름을 쓴다.
        // `FileManager.displayName` 은 확장자가 붙어 나올 수 있어 쓰지 않는다.
        let name = source?.displayName
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        return DefaultBrowser(name: name, source: source)
    }

    /// 설치된 이 브라우저의 UA. 버전은 앱 번들에서 읽는다.
    var userAgent: String { userAgent(majorVersion: installedMajorVersion) }

    private var installedMajorVersion: String? {
        for identifier in bundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
                  let version = Bundle(url: url)?
                      .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  let major = version.split(separator: ".").first
            else { continue }
            return String(major)
        }
        return nil
    }
}

extension ClaudeSessionSource {
    /// 이 컴퓨터의 기본 브라우저를 넣어 후보를 푼다.
    static func candidates(for selection: String) -> (sources: [ClaudeSessionSource], problem: String?) {
        candidates(for: selection, defaultBrowser: BrowserCookieSource.defaultBrowser())
    }
}

// MARK: - 세션 가져오기

extension ClaudeSessionSource {
    enum JarOutcome {
        case found(ClaudeCookieJar)
        case problem(SessionProblem)
    }

    /// 이 소스의 claude.ai 쿠키로 jar 를 만든다.
    ///
    /// 실패는 `SessionProblem` 으로 분류해 올린다. 여러 소스를 차례로 시도하므로, 모두
    /// 실패했을 때 어느 사유를 보여줄지 고르려면 문자열이 아니라 종류가 필요하다.
    func jar() async -> JarOutcome {
        switch self {
        case .appWebView:
            let jar = await ClaudeWebSession.currentJar()
            guard jar.hasSession else { return .problem(.needsSignIn(ServerFailure.needsSignIn.message)) }
            return .found(jar)

        case .browser(let source):
            let cached = await BrowserKeyCache.shared.key(for: source.id)
            do {
                let (cookies, key) = try BrowserCookieStore.cookies(from: source, cachedKey: cached)
                await BrowserKeyCache.shared.store(key, for: source.id)
                let jar = ClaudeCookieJar(cookies: cookies, userAgent: source.userAgent)
                guard jar.hasSession else {
                    return .problem(.needsSignIn("\(source.displayName)에 claude.ai 로그인 세션이 없습니다. «기본 브라우저로 로그인»을 눌러 로그인한 뒤 «지금 다시 조회»를 누르세요."))
                }
                return .found(jar)
            } catch let error as BrowserCookieStore.LoadError where error.isPermissionDenied {
                return .problem(.accessDenied(error.localizedDescription))
            } catch {
                return .problem(.unreadable("\(source.displayName) 쿠키를 읽을 수 없습니다: \(error.localizedDescription)"))
            }
        }
    }
}

/// 브라우저별 Safe Storage 복호화 키 캐시.
///
/// 키체인 접근 허용 창이 조회마다 뜨지 않도록 한 번 유도한 키를 들고 있는다. 메모리에만
/// 두고 디스크에 쓰지 않으므로 앱을 다시 띄우면 다시 한 번 키체인을 읽는다.
actor BrowserKeyCache {
    static let shared = BrowserKeyCache()

    private var keys: [String: Data] = [:]

    func key(for id: String) -> Data? { keys[id] }

    func store(_ key: Data?, for id: String) {
        guard let key else { return }
        keys[id] = key
    }
}

// MARK: - 로그인 열기

enum ClaudeLogin {
    static let url = URL(string: "https://claude.ai/login")!

    /// 시스템 기본 브라우저에서 claude.ai 로그인 페이지를 연다.
    ///
    /// `NSWorkspace.open` 은 LaunchServices 에 맡기므로 사용자가 기본으로 지정한 브라우저가
    /// 그대로 열린다 — 앱이 자기 창을 띄우지 않는다.
    static func openInDefaultBrowser() {
        NSWorkspace.shared.open(url)
    }
}

/// 시스템 설정의 개인정보 보호 패널로 보낸다.
enum PrivacySettings {
    /// 전체 디스크 접근 패널.
    ///
    /// macOS 27 의 앱 데이터 보호(`kTCCServiceSystemPolicyAppDataDetailed`)는 브라우저
    /// 프로필 폴더의 열거·열기를 막는다. «파일 및 폴더» 패널은 OS 가 한 번이라도 물어본
    /// 앱만 올라오는데 이 보호는 묻지 않고 막는 경우가 있어, 사용자가 직접 추가할 수 있는
    /// 전체 디스크 접근으로 보낸다.
    static let fullDiskAccess = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static func openFullDiskAccess() {
        NSWorkspace.shared.open(fullDiskAccess)
    }
}
