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
            // 서버 실측 토글이 켜졌으면 주기를 기다리지 않고 즉시 가져온다.
            let serverToggledOn = config.showsServerUsage && !oldValue.showsServerUsage
            // 주간 주기나 리셋 보정이 바뀌면 집계 범위가 달라진다.
            refresh()
            if serverToggledOn { maybeFetchServer(force: true) }
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
    private var lastWidgetReload: Date = .distantPast
    private var lastPublishedSignature: Int?

    /// 마지막으로 가져온 서버 실측값. 5초 로컬 갱신 때마다 스냅샷에 다시 얹는다.
    private var lastServerUsage: ServerUsage?
    private var lastServerFetch: Date = .distantPast
    private var serverFetchInFlight = false
    /// Safe Storage 복호화 키. 처음 한 번만 키체인에서 읽어 캐시하고 이후 조회에서 재사용한다.
    /// 메모리에만 두고 디스크에 쓰지 않는다.
    private var cachedDecryptionKey: Data?

    init() {
        self.config = UsageSharedStore.loadConfig()
        start()
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
    }

    /// 지금 즉시 다시 읽는다. 메뉴의 "새로 고침"이 호출한다.
    func refresh() {
        var fresh = reader.makeSnapshot(config: config)
        fresh.server = config.showsServerUsage ? lastServerUsage : nil
        snapshot = fresh
        UsageSharedStore.save(fresh)
        reloadWidget(force: false)
        maybeFetchServer(force: false)
    }

    /// 메뉴의 "새로 고침"에서 서버까지 강제로 다시 가져온다.
    func refreshAll() {
        maybeFetchServer(force: true)
        refresh()
    }

    // MARK: - 서버(claude.ai) 실측 조회

    /// 주기가 됐거나 강제일 때 백그라운드에서 실측 사용량을 가져온다.
    private func maybeFetchServer(force: Bool) {
        guard config.showsServerUsage else {
            // 껐으면 이전 값을 지우고 스냅샷에서도 뺀다.
            if lastServerUsage != nil {
                lastServerUsage = nil
                var updated = snapshot
                updated.server = nil
                snapshot = updated
                UsageSharedStore.save(updated)
            }
            return
        }
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
        let cached = cachedDecryptionKey
        Task { [weak self] in
            let result = await ClaudeServerUsage.fetch(cachedKey: cached)
            self?.applyServerUsage(result.usage, key: result.key)
        }
    }

    /// 조회 결과를 현재 스냅샷에 반영하고 저장·위젯 갱신한다. (MainActor)
    private func applyServerUsage(_ usage: ServerUsage, key: Data?) {
        serverFetchInFlight = false
        // 키체인에서 유효한 키를 읽었으면 캐시해 다음부터 Safe Storage를 건드리지 않는다.
        if let key { cachedDecryptionKey = key }
        lastServerUsage = usage
        guard config.showsServerUsage else { return }
        var updated = snapshot
        updated.server = usage
        snapshot = updated
        UsageSharedStore.save(updated)
        reloadWidget(force: false)
    }

    // MARK: - 메뉴바 표시

    /// 메뉴바 아이콘에 그릴 값 묶음 — 소진율·창에서 지난 시간·색 단계·숫자.
    var menuBarIconModel: MenuBarIconModel {
        MenuBarIconModel(usage: snapshot.effectiveSessionRatio(config: config),
                         elapsed: sessionElapsedRatio,
                         severity: sessionSeverity,
                         percent: sessionPercent)
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

    /// 5시간 창 소진율(%). 서버 실측이 있으면 그 값을 쓴다. 표시할 값이 없으면 nil.
    var sessionPercent: Int? {
        if let window = snapshot.usableServerUsage(config: config)?.fiveHour {
            return Int(window.utilizationPercent.rounded())
        }
        guard snapshot.activeBlock != nil else { return nil }
        let ratio = snapshot.sessionUtilization(config: config)
        guard ratio > 0 else { return nil }
        return Int((ratio * 100).rounded())
    }

    /// 5시간 창에서 지금까지 지나간 비율(0...1). 진행 중인 창이 없으면 nil.
    ///
    /// 서버 실측이 준 리셋 시각을 먼저 쓰고, 없으면 로그로 잡은 창의 경과를 쓴다.
    private var sessionElapsedRatio: Double? {
        let now = Date()
        if let window = snapshot.usableServerUsage(config: config)?.fiveHour,
           let ratio = window.elapsedRatio(at: now, window: ClaudeUsageLimits.sessionWindow) {
            return ratio
        }
        guard let block = snapshot.activeBlock, block.isActive(at: now) else { return nil }
        return block.elapsedRatio(at: now)
    }

    /// 5시간 창 소진율 텍스트. 소진율을 못 구하면 측정값 자체나 «—» 로 대체한다.
    private var sessionLabel: String {
        if let percent = sessionPercent { return "\(percent)%" }
        guard snapshot.activeBlock != nil else { return "—" }
        return config.metric.format(snapshot.sessionValue(for: config.metric))
    }

    /// 주간 소진율. 실측도 없고 로컬 집계도 비어 있으면 붙일 게 없다.
    private var weeklyLabel: String? {
        if let window = snapshot.usableServerUsage(config: config)?.sevenDay {
            return "주 \(Int(window.utilizationPercent.rounded()))%"
        }
        guard snapshot.weeklyTokens.total > 0 else { return nil }
        return "주 \(Int((snapshot.weeklyUtilization(config: config) * 100).rounded()))%"
    }

    /// 5시간 창 리셋까지 남은 시간. 서버가 준 `resets_at`을 먼저 쓰고, 없으면 창의 끝을 쓴다.
    private var remainingLabel: String? {
        let now = Date()
        if let remaining = snapshot.usableServerUsage(config: config)?.fiveHour?.remainingTime(at: now) {
            return remaining.compactDurationString
        }
        guard let block = snapshot.activeBlock, block.isActive(at: now) else { return nil }
        return block.remainingTime(at: now).compactDurationString
    }

    /// 메뉴바에 표시할 데이터가 있는지 — 아이콘 선택에 쓴다.
    var hasSessionData: Bool {
        snapshot.usableServerUsage(config: config)?.fiveHour != nil || snapshot.activeBlock != nil
    }

    /// 사용률에 따른 경고 단계. 색 결정에만 쓴다. 서버 실측 우선.
    var sessionSeverity: UsageSeverity {
        UsageSeverity(ratio: snapshot.effectiveSessionRatio(config: config))
    }

    var weeklySeverity: UsageSeverity {
        UsageSeverity(ratio: snapshot.effectiveWeeklyRatio(config: config))
    }

    /// 캘리브레이션 시 기준이 되는 현재 측정값.
    var currentSessionValue: Double { snapshot.sessionValue(for: config.metric) }

    /// 표시할 내용(로컬 사용량 또는 서버 %)이 바뀌었을 때만 위젯을 깨운다.
    private func reloadWidget(force: Bool) {
        var hasher = Hasher()
        hasher.combine(snapshot.activeBlock?.tokens.billable ?? 0)
        hasher.combine(Int((snapshot.server?.fiveHour?.utilizationPercent ?? -1).rounded()))
        hasher.combine(Int((snapshot.server?.sevenDay?.utilizationPercent ?? -1).rounded()))
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
