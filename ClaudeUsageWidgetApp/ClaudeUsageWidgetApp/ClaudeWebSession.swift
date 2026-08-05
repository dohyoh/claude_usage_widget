//
//  ClaudeWebSession.swift
//  ClaudeUsageWidgetApp
//
//  우리 웹뷰가 들고 있는 claude.ai 세션.
//
//  세션은 WKWebsiteDataStore(persistent)에 있고, 앱은 세션 값을 따로 저장하지 않는다.
//  저장소가 WebKit 이라서 로그인 창과 사용량 조회가 같은 쿠키·같은 지문을 공유하고,
//  그래서 Cloudflare 관점에서 브라우저와 구분되지 않는다. (cf_clearance 는 UA·지문에
//  묶여 있어, 쿠키만 뽑아 다른 클라이언트로 옮기면 챌린지를 받을 수 있다.)
//
//  이 앱은 키체인을 쓰지 않는다. Claude 데스크톱 앱도 필요하지 않다.
//

import Foundation
import WebKit

@MainActor
enum ClaudeWebSession {
    /// 로그인 창과 조회가 함께 쓰는 저장소. 프로세스를 다시 띄워도 세션이 남는다.
    static let dataStore: WKWebsiteDataStore = .default()

    /// 지금 저장소에 있는 claude.ai 쿠키로 조립한 jar.
    ///
    /// 로그인하지 않았어도 Cloudflare·분석 쿠키는 있으므로, 로그인 여부는 `hasSession`으로
    /// 판단해야 한다.
    static func currentJar() async -> ClaudeCookieJar {
        let cookies = await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        return ClaudeCookieJar(cookies: cookies)
    }

    /// 로그아웃 — 웹 저장소를 비운다. 다음 조회는 재로그인을 요구한다.
    static func signOut() async {
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                 modifiedSince: .distantPast) { continuation.resume() }
        }
    }
}
