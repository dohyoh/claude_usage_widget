//
//  UsageMonitor.swift
//  ClaudeUsageWidgetApp
//
//  메뉴바 앱 쪽 상태. 샌드박스가 꺼져 있어 ~/.claude 를 직접 읽을 수 있고,
//  읽은 결과를 스냅샷 파일로 내려 위젯이 싸게 읽어가도록 한다.
//

import Foundation
import Observation
import WidgetKit

@Observable
final class UsageMonitor {
    /// 화면에 그릴 최신 집계.
    private(set) var snapshot: UsageSnapshot = .empty
    /// 사용자가 조정하는 추정 한도.
    var config: UsageConfig {
        didSet {
            guard config != oldValue else { return }
            UsageSharedStore.save(config)
            // 쿠키 원본이 바뀌면 다른 세션으로 보게 되므로 주기를 기다리지 않고 바로 조회한다.
            let sourceChanged = config.cookieSource != oldValue.cookieSource
            refresh()
            if sourceChanged { maybeFetchServer(force: true) }
            reloadWidget(force: true)
        }
    }

    /// 메뉴바는 초 단위로 갱신해도 부담이 없다. 증분 파싱이라 대부분 무동작이다.
    private let refreshInterval: TimeInterval = 5
    /// 위젯 타임라인 갱신은 시스템 예산이 있으므로 최소 간격을 둔다.
    private let widgetReloadInterval: TimeInterval = 60
    // claude.ai 실측 조회 주기는 설정값(config.serverRefreshInterval)을 따른다.

    private let reader = ClaudeUsageReader()
    private var timer: Timer?
    /// 브라우저 로그인을 지켜보는 작업. 다시 로그인을 누르면 이전 것을 버린다.
    private var signInWatch: Task<Void, Never>?
    /// 브라우저 로그인을 얼마나, 얼마 간격으로 지켜볼지.
    private static let signInWatchDuration: TimeInterval = 5 * 60
    private static let signInWatchInterval: TimeInterval = 3
    private var lastWidgetReload: Date = .distantPast
    private var lastPublishedSignature: Int?

    /// 마지막으로 가져온 서버 실측값. 5초 로컬 갱신 때마다 스냅샷에 다시 얹는다.
    private var lastServerUsage: ServerUsage?
    private var lastServerFetch: Date = .distantPast
    private var serverFetchInFlight = false
    /// 실측을 가져온 계정. 매 조회마다 다시 확인하지 않고 파일에 캐시한다.
    private(set) var serverAccount: AccountCache?
    /// Claude Code 가 로그인해 둔 계정 — 로컬 추정이 누구의 활동인지 알려준다.
    ///
    /// 5초 갱신마다 읽으면 50KB 넘는 파일을 계속 파싱하게 되므로 시작할 때와 수동
    /// 새로고침에서만 읽는다. Claude Code 계정이 바뀌는 일은 드물다.
    private(set) var localAccount: ClaudeCodeAccount?

    /// 마지막 조회에서 세션을 실제로 쓴 소스의 이름. 설정의 상태 표시에 쓴다.
    private(set) var serverSourceName: String?

    init() {
        self.config = UsageSharedStore.loadConfig()
        self.serverAccount = UsageSharedStore.loadAccount()
        self.localAccount = ClaudeCodeAccount.read()
        start()
    }

    /// 이 로그인이 볼 수 있는 조직 — 설정의 조직 선택이 쓴다.
    private(set) var availableOrganizations: [OrganizationSummary] = []

    /// 실측 계정과 로컬 로그의 계정이 같은지. 다르면 패널의 두 숫자가 다른 계정을 가리킨다.
    var accountMatch: AccountMatch {
        AccountMatch.evaluate(server: serverAccount, local: localAccount)
    }

    /// 로그인·계정 선택을 시작한다. 쿠키를 읽을 수 있는 브라우저가 기본이면 **늘 거기서** 한다.
    ///
    /// 평소 쓰는 브라우저에서 계정을 고르는 것이 자연스럽고, 이미 claude.ai 에 로그인해 둔
    /// 브라우저라면 고를 것도 없이 그 세션을 바로 쓸 수 있다. 그래서 세 가지를 한 번에 한다:
    ///
    ///   1. 쿠키 원본을 기본 브라우저로 고정한다 — 브라우저에서 고른 계정이 실제로 쓰이도록.
    ///   2. 곧바로 한 번 조회한다 — 브라우저에 이미 세션이 있으면 여기서 끝난다.
    ///   3. 브라우저를 열고, 거기서 로그인이 끝나는지 잠깐 지켜본다(`watchForBrowserSignIn`).
    ///
    /// 쿠키를 읽을 수 없는 브라우저(Safari)가 기본이면 앱 안의 로그인 창 말고는 길이 없다.
    func signIn() {
        guard let source = BrowserCookieSource.defaultBrowser()?.source, source.isSupported else {
            ClaudeLoginWindowController.shared.present { [weak self] signedIn in
                guard signedIn else { return }
                self?.refreshAll()
            }
            return
        }

        config.cookieSourceID = CookieSourceSelection.defaultBrowser
        refreshAll()
        ClaudeLogin.openInDefaultBrowser()
        watchForBrowserSignIn(source: source)
    }

    /// 로그인이 기본 브라우저로 열리는지 — 설정 화면의 버튼 이름에 쓴다.
    var signsInWithBrowser: Bool {
        BrowserCookieSource.defaultBrowser()?.source?.isSupported ?? false
    }

    /// 브라우저에서 로그인이 끝나길 기다리는 중인지 — 설정 화면의 안내에 쓴다.
    private(set) var isWaitingForBrowserSignIn = false

    /// 브라우저에서 로그인이 끝나는지 잠깐 지켜본다.
    ///
    /// 브라우저는 로그인이 끝났다는 신호를 앱에 주지 않는다. 그래서 세션 쿠키의 지문이
    /// 생기거나 바뀔 때까지 짧은 간격으로 확인하고, 달라지면 곧바로 조회한다. 지문만 비교하니
    /// 세션 값 자체는 여기로 흘러나오지 않는다.
    ///
    /// 사용자가 로그인하지 않고 창을 닫아 버릴 수도 있으므로 영원히 돌지 않고 스스로 멈춘다.
    private func watchForBrowserSignIn(source: BrowserCookieSource) {
        signInWatch?.cancel()
        isWaitingForBrowserSignIn = true
        signInWatch = Task { @MainActor [weak self] in
            defer { self?.isWaitingForBrowserSignIn = false }
            let before = await Self.browserSessionFingerprint(source)
            let deadline = Date().addingTimeInterval(Self.signInWatchDuration)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(Self.signInWatchInterval))
                guard !Task.isCancelled else { return }
                let now = await Self.browserSessionFingerprint(source)
                guard let now, now != before else { continue }
                self?.refreshAll()
                return
            }
        }
    }

    /// 브라우저에 있는 세션 쿠키의 지문. 로그인하지 않았으면 nil.
    private static func browserSessionFingerprint(_ source: BrowserCookieSource) async -> String? {
        guard case .found(let jar) = await ClaudeSessionSource.browser(source).jar() else { return nil }
        return jar.sessionFingerprint
    }

    func start() {
        refresh()
        timer?.invalidate()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // 메뉴를 열어 둔 동안에도 계속 돌도록 common 모드에 넣는다.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        signInWatch?.cancel()
        signInWatch = nil
    }

    /// 지금 즉시 다시 읽는다. 메뉴의 "새로 고침"이 호출한다.
    func refresh() {
        // 창 경계는 실측이 알려준 리셋 시각에서 온다 — 로그만으로는 맞출 수 없다.
        var fresh = reader.makeSnapshot(bounds: lastServerUsage?.localWindowBounds ?? .unknown)
        fresh.server = lastServerUsage
        snapshot = fresh
        UsageSharedStore.save(fresh)
        reloadWidget(force: false)
        maybeFetchServer(force: false)
    }

    /// 메뉴의 "새로 고침"에서 서버까지 강제로 다시 가져온다.
    func refreshAll() {
        localAccount = ClaudeCodeAccount.read()
        maybeFetchServer(force: true)
        refresh()
    }

    /// 연동을 끊는다 — 웹 저장소를 비우고 계정 캐시를 지운다.
    ///
    /// 다음 조회는 재로그인을 요구한다. 다른 계정으로 갈아끼울 때 쓴다.
    func signOut() {
        Task { @MainActor [weak self] in
            await ClaudeWebSession.signOut()
            guard let self else { return }
            self.serverAccount = nil
            self.lastServerUsage = nil
            self.refresh()
        }
    }

    // MARK: - 서버(claude.ai) 실측 조회

    /// 주기가 됐거나 강제일 때 백그라운드에서 실측 사용량을 가져온다.
    private func maybeFetchServer(force: Bool) {
        guard !serverFetchInFlight else { return }
        let now = Date()
        if config.serverRefreshIsManual {
            // 수동 모드: 강제 새로고침이거나, 아직 한 번도 안 가져왔을 때(시작 시 1회)만.
            guard force || lastServerFetch == .distantPast else { return }
        } else {
            guard force || now.timeIntervalSince(lastServerFetch) >= config.serverRefreshInterval else { return }
        }
        serverFetchInFlight = true
        lastServerFetch = now
        let config = self.config
        let cached = serverAccount
        Task { [weak self] in
            let result = await ClaudeServerUsage.fetch(config: config, cachedAccount: cached)
            self?.applyServerUsage(result)
        }
    }

    /// 조회 결과를 현재 스냅샷에 반영하고 저장·위젯 갱신한다. (MainActor)
    private func applyServerUsage(_ result: ServerFetchResult) {
        serverFetchInFlight = false
        // 계정을 다시 확인했으면 캐시를 갈아 끼운다. 설정과 수명주기가 달라 파일이 따로 있다.
        if let account = result.account {
            serverAccount = account
            UsageSharedStore.save(account)
        }
        // 조직 목록은 조회에 성공했을 때만 갈아 끼운다. 일시적 실패로 설정의 선택지를
        // 비워 버리면 사용자가 고른 조직이 사라진 것처럼 보인다.
        if !result.organizations.isEmpty { availableOrganizations = result.organizations }
        serverSourceName = result.sourceName
        lastServerUsage = result.usage
        // 실측이 창 경계를 알려주므로 로컬 집계도 함께 다시 만든다 — 경계가 바뀌면
        // 그 창의 요청 수·토큰도 달라진다.
        refresh()
    }

    // MARK: - 메뉴바 표시

    /// 메뉴바 아이콘에 그릴 값 묶음 — 소진율·창에서 지난 시간·색 단계·숫자.
    var menuBarIconModel: MenuBarIconModel {
        MenuBarIconModel(usage: sessionWindow?.ratio ?? 0,
                         elapsed: sessionElapsedRatio,
                         severity: sessionSeverity,
                         percent: sessionPercent)
    }

    /// 표시에 쓸 5시간 창 실측. 실측이 없으면 메뉴바에 그릴 값도 없다.
    private var sessionWindow: ServerUsageWindow? {
        snapshot.usableServerUsage?.fiveHour
    }

    /// 지금 설정으로 그릴 메뉴바 라벨.
    var menuBarLabelSpec: MenuBarLabelSpec {
        menuBarLabelSpec(for: config.menuBarDesign)
    }

    /// 특정 디자인으로 그릴 메뉴바 라벨 — 설정 창의 미리보기가 디자인별로 쓴다.
    ///
    /// 사용량(5시간 창 소진율)은 아이콘 왼쪽에, 주간 소진율과 남은 시간은 오른쪽에 둔다.
    /// 숫자를 아이콘 안에 그리는 디자인에서는 같은 값이 두 번 나오지 않게 왼쪽을 비운다.
    func menuBarLabelSpec(for style: MenuBarStyle) -> MenuBarLabelSpec {
        MenuBarLabelSpec(style: style,
                         model: menuBarIconModel,
                         leading: style.drawsPercentInIcon ? "" : sessionLabel,
                         trailing: menuBarTrailingLines,
                         textColor: config.menuBarTextColor)
    }

    /// 아이콘 오른쪽에 둘 줄. 설정에서 켠 것만 넣는다 — 둘 다면 위아래로 쌓인다.
    ///
    /// 메뉴바 폭은 다른 앱과 나눠 쓰는 자리라 기본은 사용량 하나만 둔다.
    private var menuBarTrailingLines: [String] {
        var lines: [String] = []
        if config.showsMenuBarWeekly, let weekly = weeklyLabel { lines.append(weekly) }
        if config.showsMenuBarRemaining, let remaining = remainingLabel { lines.append(remaining) }
        return lines
    }

    /// 5시간 창 소진율(%). 실측이 없으면 nil.
    var sessionPercent: Int? {
        sessionWindow.map { Int($0.utilizationPercent.rounded()) }
    }

    /// 5시간 창에서 지금까지 지나간 비율(0...1). 리셋 시각을 모르면 nil.
    private var sessionElapsedRatio: Double? {
        sessionWindow?.elapsedRatio(at: Date(), window: ClaudeUsageLimits.sessionWindow)
    }

    /// 5시간 창 소진율 텍스트. 실측이 없으면 «—».
    private var sessionLabel: String {
        sessionPercent.map { "\($0)%" } ?? "—"
    }

    /// 주간 소진율. 실측이 없으면 붙일 게 없다.
    private var weeklyLabel: String? {
        snapshot.usableServerUsage?.sevenDay
            .map { "주 \(Int($0.utilizationPercent.rounded()))%" }
    }

    /// 5시간 창 리셋까지 남은 시간. 서버가 `resets_at`을 주지 않았으면 nil.
    private var remainingLabel: String? {
        sessionWindow?.remainingTime(at: Date())?.compactDurationString
    }

    /// 메뉴바에 표시할 데이터가 있는지 — 아이콘 선택에 쓴다.
    var hasSessionData: Bool { sessionWindow != nil }

    /// 사용률에 따른 경고 단계. 색 결정에만 쓴다.
    var sessionSeverity: UsageSeverity {
        UsageSeverity(ratio: sessionWindow?.ratio ?? 0)
    }

    /// 위젯이 그리는 값(실측 백분율과 실패 사유)이 바뀌었을 때만 위젯을 깨운다.
    ///
    /// 로컬 상세는 메뉴바 패널에만 나오므로 위젯 갱신 조건에 넣지 않는다.
    private func reloadWidget(force: Bool) {
        var hasher = Hasher()
        for window in [snapshot.server?.fiveHour,
                       snapshot.server?.sevenDay,
                       snapshot.server?.sevenDayOpus] {
            hasher.combine(Int((window?.utilizationPercent ?? -1).rounded()))
        }
        hasher.combine(snapshot.server?.failureReason)
        let signature = hasher.finalize()
        let changed = signature != lastPublishedSignature
        lastPublishedSignature = signature

        guard force || changed else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastWidgetReload) >= widgetReloadInterval else { return }
        lastWidgetReload = now
        WidgetCenter.shared.reloadAllTimelines()
    }
}
