//
//  WKWebViewSSOSpike.swift
//
//  버려질 코드다. 하나만 확인한다:
//
//    "위젯이 자체 로그인 창을 띄워 claude.ai 세션을 직접 확보할 수 있는가?"
//
//  증명할 것 세 가지:
//    1. WKWebView 에서 claude.ai 로그인이 완주되는가 — 특히 Google SSO.
//       Google 은 임베디드 웹뷰를 `disallowed_useragent` 로 거부하는 경우가 있다.
//       (반례: Claude.app 자체가 Electron 이고 그 안에서 SSO 가 된다.)
//    2. 로그인 후 WKHTTPCookieStore 에서 sessionKey 를 꺼낼 수 있는가.
//    3. 그 쿠키로 /api/organizations/{org}/usage 가 Cloudflare 를 통과하는가.
//       cf_clearance 는 UA·지문에 묶여 있어 이 부분이 실패할 수 있다.
//
//  자격증명은 사람이 창에 직접 입력한다. 이 프로그램은 값을 출력하지 않는다 —
//  sessionKey 는 지문(sha256 앞 16자)만, 페이지 본문은 마커 존재 여부만 본다.
//
//  UA 는 환경변수로 고른다:  SPIKE_UA = default | chrome | electron
//

import AppKit
import CryptoKit
import WebKit

// MARK: - 출력

enum Log {
    static func section(_ title: String) {
        print("\n\u{001B}[1m── \(title) ──\u{001B}[0m")
    }
    static func line(_ message: String) { print("   \(message)") }
    static func ok(_ message: String) { print("   \u{001B}[32m✔\u{001B}[0m \(message)") }
    static func bad(_ message: String) { print("   \u{001B}[31m✘\u{001B}[0m \(message)") }
    static func info(_ message: String) { print("   · \(message)") }
}

// MARK: - UA

enum UserAgentChoice {
    /// WKWebView 기본값(Safari 계열)을 쓰려면 nil.
    static var custom: String? {
        switch ProcessInfo.processInfo.environment["SPIKE_UA"] ?? "default" {
        case "chrome":
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                 + "(KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36"
        case "electron":
            // Claude.app 이 쓰는 형태. SSO 가 된다고 알려진 조합에 가장 가깝다.
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                 + "(KHTML, like Gecko) Claude/0.13.0 Chrome/132.0.6834.210 "
                 + "Electron/34.5.8 Safari/537.36"
        default:
            return nil
        }
    }

    static var label: String {
        custom.map { String($0.prefix(70)) + "…" } ?? "WKWebView 기본값 (Safari 계열)"
    }
}

// MARK: - Google 차단 마커

/// Google 이 임베디드 웹뷰를 막을 때 페이지에 나타나는 표시.
let googleBlockMarkers = [
    "disallowed_useragent",
    "browser or app may not be secure",
    "브라우저 또는 앱은 안전하지 않을 수 있습니다",
    "이 브라우저 또는 앱은 안전하지",
    "Try using a different browser",
]

// MARK: - 앱

final class SpikeDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var statusLabel: NSTextField!
    /// 방문한 호스트 순서 — SSO 왕복이 어디서 끊겼는지 보려고 남긴다.
    private var visitedHosts: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.section("스파이크 시작")
        Log.info("UA: \(UserAgentChoice.label)")
        Log.info("번들 식별자: \(Bundle.main.bundleIdentifier ?? "없음 — WKWebsiteDataStore 가 불안정할 수 있다")")
        Log.info("창에서 로그인하십시오. Google SSO 를 쓰려면 «Continue with Google» 을 누릅니다.")
        Log.info("로그인이 끝나면 창 아래 «진단 실행» 을 누릅니다.")

        let configuration = WKWebViewConfiguration()
        // 지속 저장소. 설계상 여기에 세션을 맡기므로 그대로 쓴다.
        configuration.websiteDataStore = .default()

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.customUserAgent = UserAgentChoice.custom
        webView.allowsBackForwardNavigationGestures = true

        let button = NSButton(title: "진단 실행", target: self, action: #selector(runDiagnostics))
        button.bezelStyle = .rounded

        let reset = NSButton(title: "저장소 비우기", target: self, action: #selector(clearStore))
        reset.bezelStyle = .rounded

        statusLabel = NSTextField(labelWithString: "로그인을 기다리는 중…")
        statusLabel.lineBreakMode = .byTruncatingMiddle

        let bar = NSStackView(views: [button, reset, statusLabel])
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.spacing = 10

        let stack = NSStackView(views: [webView, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        bar.setContentHuggingPriority(.required, for: .vertical)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 820),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered,
                          defer: false)
        window.title = "WKWebView + claude.ai 로그인 스파이크"
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    // MARK: 내비게이션 추적

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let host = navigationAction.request.url?.host, visitedHosts.last != host {
            visitedHosts.append(host)
            Log.info("이동 → \(host)")
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url?.absoluteString ?? "?"
        statusLabel.stringValue = webView.title ?? url

        // Google 차단 마커만 확인한다. 페이지 본문은 출력하지 않는다 — 사용자의
        // 이메일 등이 들어 있을 수 있다.
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in
            guard let text = value as? String else { return }
            let lowered = text.lowercased()
            if let hit = googleBlockMarkers.first(where: { lowered.contains($0.lowercased()) }) {
                Log.bad("Google 이 임베디드 웹뷰를 거부했습니다 (마커: \"\(hit)\")")
                Log.info("→ SPIKE_UA=chrome 또는 electron 으로 다시 시도해 보십시오.")
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        Log.bad("내비게이션 실패: \(error.localizedDescription)")
    }

    // MARK: 저장소 비우기

    @objc private func clearStore() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
            Log.info("웹 저장소를 비웠습니다. 로그인부터 다시 시작합니다.")
            self.webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        }
    }

    // MARK: 진단

    @objc private func runDiagnostics() {
        Log.section("2. WKHTTPCookieStore 에서 세션 꺼내기")
        Log.info("방문 경로: \(visitedHosts.joined(separator: " → "))")

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let claude = cookies.filter { $0.domain.hasSuffix("claude.ai") }
            guard !claude.isEmpty else {
                Log.bad("claude.ai 쿠키가 없습니다. 로그인이 끝나지 않았습니다.")
                return
            }

            Log.info("claude.ai 쿠키 \(claude.count)개: "
                     + claude.map(\.name).sorted().joined(separator: ", "))

            let named = Dictionary(claude.map { ($0.name, $0.value) },
                                   uniquingKeysWith: { first, _ in first })

            guard let sessionKey = named["sessionKey"] else {
                Log.bad("sessionKey 가 없습니다 — 세션을 확보하지 못했습니다.")
                return
            }
            let digest = SHA256.hash(data: Data(sessionKey.utf8))
            let fingerprint = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
            Log.ok("sessionKey 확보 (지문 \(fingerprint), 길이 \(sessionKey.count))")

            if named["cf_clearance"] != nil {
                Log.ok("cf_clearance 있음 — Cloudflare 통과 가능성이 높습니다.")
            } else {
                Log.info("cf_clearance 없음 — 챌린지를 받을 수 있습니다.")
            }

            let header = claude.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            let lastActiveOrg = named["lastActiveOrg"]
            Log.info("lastActiveOrg: \(lastActiveOrg ?? "없음")")

            Task { await Self.probeAPI(cookieHeader: header, lastActiveOrg: lastActiveOrg) }
        }
    }

    /// 확보한 쿠키로 실제 사용량 엔드포인트를 때려 본다.
    private static func probeAPI(cookieHeader: String, lastActiveOrg: String?) async {
        Log.section("3. 사용량 API 호출 (Cloudflare 통과 여부)")

        func request(_ path: String) -> URLRequest {
            var req = URLRequest(url: URL(string: "https://claude.ai/api" + path)!)
            req.timeoutInterval = 25
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            req.setValue(UserAgentChoice.custom
                         ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
                         + " (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
            req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            req.setValue("https://claude.ai/", forHTTPHeaderField: "Referer")
            req.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
            return req
        }

        func fetch(_ path: String) async -> (Int, Data)? {
            do {
                let (data, response) = try await URLSession.shared.data(for: request(path))
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                return (code, data)
            } catch {
                Log.bad("\(path) → 요청 실패: \(error.localizedDescription)")
                return nil
            }
        }

        // 조직 목록
        var organizationUuid = lastActiveOrg
        if let (code, data) = await fetch("/organizations") {
            if code == 200,
               let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                Log.ok("/organizations → 200, 조직 \(orgs.count)개")
                for org in orgs {
                    let uuid = org["uuid"] as? String ?? "?"
                    let name = org["name"] as? String ?? "(이름 없음)"
                    let caps = (org["capabilities"] as? [String])?.joined(separator: ",") ?? "-"
                    Log.info("  \(uuid)  \(name)  [\(caps)]")
                    if organizationUuid == nil, caps.contains("chat") { organizationUuid = uuid }
                }
            } else {
                Log.bad("/organizations → \(code)")
                Log.info("  본문 앞부분: \(String(data: data.prefix(200), encoding: .utf8) ?? "?")")
            }
        }

        guard let organizationUuid else {
            Log.bad("조직을 못 찾아 사용량 조회를 건너뜁니다.")
            return
        }

        // 사용량 — 이게 통과하면 설계가 성립한다.
        if let (code, data) = await fetch("/organizations/\(organizationUuid)/usage") {
            if code == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                Log.ok("/organizations/{org}/usage → 200")
                for key in ["five_hour", "seven_day", "seven_day_opus"] {
                    guard let window = json[key] as? [String: Any] else { continue }
                    let util = window["utilization"] as? Double ?? -1
                    let resets = window["resets_at"] as? String ?? "-"
                    Log.info("  \(key): \(util)%  리셋 \(resets)")
                }
                Log.section("결론")
                Log.ok("세 항목 모두 통과 — 자체 로그인으로 실측 사용량을 가져올 수 있습니다.")
            } else {
                Log.bad("/organizations/{org}/usage → \(code)")
                Log.info("  본문 앞부분: \(String(data: data.prefix(300), encoding: .utf8) ?? "?")")
                Log.section("결론")
                Log.bad("쿠키는 얻었지만 사용량 API 가 거부했습니다. 3번 항목 실패.")
            }
        }
    }
}

let app = NSApplication.shared
let delegate = SpikeDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
