//
//  ClaudeLoginWindow.swift
//  ClaudeUsageWidgetApp
//
//  claude.ai 로그인 창. 사용자가 직접 로그인하고, 세션은 WKWebsiteDataStore 에 남는다.
//
//  두 가지가 반드시 필요하다 — 스파이크에서 확인했다:
//
//    1. WKUIDelegate.createWebViewWith. Google 로그인은 window.open 팝업으로 진행된다.
//       이걸 구현하지 않으면 WKWebView 가 팝업 요청을 조용히 버리고, SSO 는 콜백을 못 받아
//       claude.ai 가 "로그인 중 오류" 를 낸다.
//    2. NSWindow.isReleasedWhenClosed = false. 창을 배열에 들고 있는 상태에서 close() 를
//       부르면 과다 해제로 죽는다.
//
//  로그인 완료는 세션 쿠키가 생겼는지로 판단한다. 로그인 화면만 열어도 Cloudflare·분석
//  쿠키는 생기므로 쿠키 존재만으로는 알 수 없다.
//

import AppKit
import WebKit

@MainActor
final class ClaudeLoginWindowController: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = ClaudeLoginWindowController()

    private var window: NSWindow?
    private var webView: WKWebView?
    /// Google 로그인 팝업. 배열에 들고 있어야 창이 사라지지 않는다.
    private var popupWindows: [NSWindow] = []
    private var onFinish: ((Bool) -> Void)?

    /// 로그인 창을 띄운다. 이미 열려 있으면 앞으로 가져온다.
    ///
    /// - Parameter onFinish: 창이 닫힐 때 호출된다. 세션을 확보했으면 true.
    func present(onFinish: @escaping (Bool) -> Void) {
        self.onFinish = onFinish

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let configuration = WKWebViewConfiguration()
        // 조회와 같은 저장소를 쓴다. 같은 쿠키·같은 지문이라 Cloudflare 가 구분하지 않는다.
        configuration.websiteDataStore = ClaudeWebSession.dataStore

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 980, height: 760),
                                configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView

        let window = NSWindow(contentRect: webView.frame,
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Claude 로그인"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
    }

    // MARK: 로그인 완료 판정

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 세션 쿠키가 생겼으면 로그인이 끝난 것이다.
        Task { @MainActor [weak self] in
            guard await ClaudeWebSession.currentJar().hasSession else { return }
            self?.finish(signedIn: true)
        }
    }

    private func finish(signedIn: Bool) {
        let callback = onFinish
        onFinish = nil
        // 내비게이션 콜백 안에서 창을 걷어내면 WebKit 이 쓰는 중인 웹뷰가 해제된다.
        DispatchQueue.main.async { [weak self] in
            self?.teardown()
            callback?(signedIn)
        }
    }

    private func teardown() {
        popupWindows.forEach { $0.close() }
        popupWindows.removeAll()
        window?.delegate = nil
        window?.close()
        window = nil
        webView = nil
    }

    // MARK: 팝업 — Google 로그인이 window.open 으로 띄운다

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 넘어온 configuration 을 그대로 써야 팝업이 부모와 쿠키를 공유한다.
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 660),
                              configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self

        let popupWindow = NSWindow(contentRect: popup.frame,
                                   styleMask: [.titled, .closable, .resizable],
                                   backing: .buffered,
                                   defer: false)
        popupWindow.title = "로그인"
        popupWindow.contentView = popup
        popupWindow.isReleasedWhenClosed = false
        popupWindow.center()
        popupWindow.makeKeyAndOrderFront(nil)
        popupWindows.append(popupWindow)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let index = popupWindows.firstIndex(where: { $0.contentView === webView }) else { return }
        let popupWindow = popupWindows.remove(at: index)
        // 이 콜백은 WebKit 이 아직 그 웹뷰를 쓰는 중에 온다. 다음 런루프로 미룬다.
        DispatchQueue.main.async { popupWindow.close() }
    }
}

// MARK: - 사용자가 창을 닫은 경우

extension ClaudeLoginWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // 로그인하지 않고 닫았다. 상태를 정리하고 실패로 알린다.
        let callback = onFinish
        onFinish = nil
        popupWindows.forEach { $0.close() }
        popupWindows.removeAll()
        window = nil
        webView = nil
        callback?(false)
    }
}
