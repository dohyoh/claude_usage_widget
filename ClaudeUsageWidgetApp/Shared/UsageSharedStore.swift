//
//  UsageSharedStore.swift
//  Shared between ClaudeUsageWidgetApp (menu bar) and ClaudeUsageWidgetExtension.
//
//  메뉴바 앱과 위젯이 주고받는 파일 두 개를 관리한다.
//  App Group 대신 파일을 쓰는 이유는 README의 "App Group 대신 파일 공유" 절 참고.
//

import Foundation

/// 사용자가 조정하는 추정 한도. Claude는 남은 한도를 로컬에 남기지 않는다.
struct UsageConfig: Codable, Hashable, Sendable {
    /// 소진율을 무엇으로 재는가.
    var metric: UsageMetric = .costUSD
    /// `metric` 단위의 5시간 창 한도.
    var sessionLimit: Double = UsageMetric.costUSD.defaultSessionLimit
    /// `metric` 단위의 주간 한도.
    var weeklyLimit: Double = UsageMetric.costUSD.defaultWeeklyLimit

    /// 주간 한도가 리셋되는 요일. `Calendar` 기준(1=일요일 … 7=토요일).
    /// nil이면 고정 주기를 모른다는 뜻이고 최근 7일 롤링으로 집계한다.
    var weeklyResetWeekday: Int? = 3   // 화요일
    /// 주간 리셋 시각(로컬 시간).
    var weeklyResetHour: Int = 15
    var weeklyResetMinute: Int = 0

    /// Claude 앱에서 확인한 5시간 창 리셋 시각.
    ///
    /// 로컬 로그에 없는 데스크톱·웹 사용분 때문에 창 시작이 늦게 잡히는 것을 보정한다.
    /// 이 시각이 지나면 자동으로 무시하고 로그 기반 계산으로 돌아간다.
    var sessionResetAt: Date?

    /// Claude 데스크톱 앱 쿠키(Safe Storage 복호화)로 claude.ai 실측 사용량을 가져올지.
    ///
    /// nil이면 켜짐으로 본다 — 이전 버전 설정 파일에 이 키가 없어도 디코딩이 깨지지 않게
    /// Optional로 둔다. 실제 판단은 `showsServerUsage`를 쓴다.
    var serverUsageEnabled: Bool?

    /// 실측 사용량 조회 주기(초). nil이면 기본 60초, 0이면 자동 갱신 없이 시작 시 1회·수동만.
    /// 이전 버전 호환을 위해 Optional. 실제 값은 `serverRefreshInterval`을 쓴다.
    var serverRefreshSeconds: Int?

    /// 실측 사용량을 조회할 organization UUID. nil이면 자동으로 고른다.
    ///
    /// 한 로그인이 여러 조직에 속할 수 있고(개인 Pro + 팀 시트), 어느 조직을 보느냐에 따라
    /// 숫자가 달라진다. 자동 선택은 조직 목록의 순서에 의존해 엉뚱한 조직을 잡을 수 있으므로
    /// 사용자가 직접 지정할 수 있게 둔다. 실제 선택은 `OrganizationChoice.select`가 한다.
    ///
    /// 이전 버전 설정 파일에 이 키가 없어도 디코딩이 깨지지 않게 Optional로 둔다.
    var organizationUuid: String?

    /// 메뉴바 라벨에 주간 소진율을 함께 표시할지. nil = 꺼짐.
    ///
    /// 메뉴바는 폭이 곧 다른 앱의 자리라 기본은 5시간 창 하나만 둔다. 이전 버전 설정
    /// 파일에 키가 없어도 디코딩이 깨지지 않게 Optional로 두고, 판단은 `showsMenuBarWeekly`.
    var menuBarShowsWeekly: Bool?
    /// 메뉴바 라벨에 5시간 창 리셋까지 남은 시간을 함께 표시할지. nil = 꺼짐.
    var menuBarShowsRemaining: Bool?

    /// 메뉴바 아이콘 디자인(`MenuBarStyle`의 rawValue).
    ///
    /// 모르는 값이나 nil이면 기본 디자인으로 되돌린다. 이전 버전 설정 파일에 키가 없어도
    /// 디코딩이 깨지지 않게 문자열 Optional로 두고, 판단은 `menuBarDesign`을 쓴다.
    var menuBarStyle: String?

    /// 메뉴바 글자 색(`#RRGGBB`). nil이면 검정.
    ///
    /// 라벨을 직접 그리기 때문에 색을 고를 수 있다. 링·막대의 사용량 색은 경고 단계를
    /// 나타내므로 이 설정을 따르지 않는다. 이전 버전 설정 파일 호환을 위해 Optional 로
    /// 두고, 실제 값은 `menuBarTextColor` 를 쓴다.
    var menuBarTextColorHex: String?

    static let `default` = UsageConfig()

    /// 실제로 그릴 메뉴바 디자인.
    var menuBarDesign: MenuBarStyle {
        menuBarStyle.flatMap(MenuBarStyle.init(rawValue:)) ?? .default
    }

    /// 메뉴바에 주간 소진율을 붙일지. 설정이 없으면 꺼짐.
    var showsMenuBarWeekly: Bool { menuBarShowsWeekly ?? false }

    /// 메뉴바에 리셋까지 남은 시간을 붙일지. 설정이 없으면 꺼짐.
    var showsMenuBarRemaining: Bool { menuBarShowsRemaining ?? false }

    /// 서버 실측 사용량을 표시할지. 설정이 없으면 기본 켜짐.
    var showsServerUsage: Bool { serverUsageEnabled ?? true }

    /// 실측 조회 주기. 0 이하이면 자동 갱신을 하지 않는다(시작 시 1회 + 수동 새로고침).
    var serverRefreshInterval: TimeInterval {
        guard let seconds = serverRefreshSeconds else { return 60 }
        return TimeInterval(max(0, seconds))
    }

    /// 자동 갱신 없이 수동으로만 조회하는 모드인지.
    var serverRefreshIsManual: Bool { serverRefreshInterval <= 0 }

    /// 주간 집계를 시작할 시점. 고정 주기를 모르면 7일 전.
    func weeklyWindowStart(now: Date, calendar: Calendar = .current) -> Date {
        guard let weekday = weeklyResetWeekday else {
            return now.addingTimeInterval(-ClaudeUsageLimits.weeklyWindow)
        }
        var components = DateComponents()
        components.weekday = weekday
        components.hour = weeklyResetHour
        components.minute = weeklyResetMinute
        components.second = 0
        // now 이전의 가장 가까운 (요일, 시각) 지점.
        guard let previous = calendar.nextDate(after: now,
                                              matching: components,
                                              matchingPolicy: .nextTimePreservingSmallerComponents,
                                              direction: .backward) else {
            return now.addingTimeInterval(-ClaudeUsageLimits.weeklyWindow)
        }
        return previous
    }

    /// 다음 주간 리셋 시각. 고정 주기를 모르면 nil.
    func nextWeeklyReset(now: Date, calendar: Calendar = .current) -> Date? {
        guard weeklyResetWeekday != nil else { return nil }
        return weeklyWindowStart(now: now, calendar: calendar)
            .addingTimeInterval(ClaudeUsageLimits.weeklyWindow)
    }

    /// 주간 주기에서 지금까지 지나간 비율(0...1). 고정 주기를 모르면 nil — 롤링에는 리셋이 없다.
    func weeklyElapsedRatio(now: Date, calendar: Calendar = .current) -> Double? {
        guard weeklyResetWeekday != nil else { return nil }
        let start = weeklyWindowStart(now: now, calendar: calendar)
        return min(1, max(0, now.timeIntervalSince(start) / ClaudeUsageLimits.weeklyWindow))
    }

    /// 주간 막대에 붙일 짧은 제목. 고정 주기와 롤링을 구분한다.
    var weeklyTitle: String { weeklyResetWeekday == nil ? "최근 7일" : "이번 주기" }

    /// 요일 표시용 심볼(월/화/…).
    static func weekdaySymbol(_ weekday: Int, calendar: Calendar = .current) -> String {
        let symbols = calendar.shortWeekdaySymbols
        let index = weekday - 1
        guard symbols.indices.contains(index) else { return "?" }
        return symbols[index]
    }

    /// 알고 있는 리셋 시각에서 유도한 현재 5시간 창의 시작 시점.
    ///
    /// - 리셋이 아직 오지 않았으면 그 5시간 전이 현재 창의 시작이다.
    /// - 리셋이 지났고 5시간 안이면 **그 시각이 새 창의 시작**이다.
    /// - 그보다 오래됐으면 정보가 낡았으므로 nil을 주고 로그 기반 추정으로 돌아간다.
    func sessionWindowStart(now: Date) -> Date? {
        guard let reset = sessionResetAt else { return nil }
        if reset > now {
            return reset.addingTimeInterval(-ClaudeUsageLimits.sessionWindow)
        }
        if now < reset.addingTimeInterval(ClaudeUsageLimits.sessionWindow) {
            return reset
        }
        return nil
    }

    /// 측정 방식을 바꾸면 한도 단위도 달라지므로 그 방식의 기본값으로 되돌린다.
    mutating func changeMetric(to newMetric: UsageMetric) {
        guard newMetric != metric else { return }
        metric = newMetric
        sessionLimit = newMetric.defaultSessionLimit
        weeklyLimit = newMetric.defaultWeeklyLimit
    }

    /// Claude가 표시하는 소진율에 맞춰 한도를 역산한다.
    ///
    /// 5시간 창을 기준으로 맞추고, 주간 한도는 기존 비율을 유지한다.
    /// - Parameters:
    ///   - observedPercent: Claude에서 본 값(0 초과).
    ///   - currentValue: 같은 시점 위젯의 측정값.
    mutating func calibrate(observedPercent: Double, currentValue: Double) {
        guard observedPercent > 0, currentValue > 0 else { return }
        let ratio = weeklyLimit / max(sessionLimit, .leastNonzeroMagnitude)
        sessionLimit = currentValue / (observedPercent / 100)
        weeklyLimit = sessionLimit * ratio
    }
}

enum UsageSharedStore {
    /// 메뉴바 앱이 주기적으로 덮어쓰는 스냅샷. 위젯은 이걸 읽는 쪽이 훨씬 싸다.
    static var snapshotURL: URL {
        ClaudeUsageReader.defaultClaudeHome.appendingPathComponent(".usage-widget-snapshot.json")
    }

    /// 한도 설정. 샌드박스 때문에 UserDefaults 를 공유할 수 없어 파일로 둔다.
    static var configURL: URL {
        ClaudeUsageReader.defaultClaudeHome.appendingPathComponent(".usage-widget-config.json")
    }

    /// 위젯이 스스로 로그를 파싱하지 않고 스냅샷을 믿어도 되는 최대 나이.
    static let snapshotFreshness: TimeInterval = 90

    // MARK: - Snapshot

    static func loadSnapshot() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? decoder.decode(UsageSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: UsageSnapshot) -> Bool {
        guard let data = try? encoder.encode(snapshot) else { return false }
        return writeAtomically(data, to: snapshotURL)
    }

    // MARK: - Config

    static func loadConfig() -> UsageConfig {
        loadConfig(from: configURL)
    }

    /// 지정한 파일에서 설정을 읽는다. 못 읽거나 형식이 어긋나면 기본값을 준다.
    ///
    /// 경로를 받는 형태로 열어 둬 테스트가 실제 사용자 파일을 건드리지 않고, 프로덕션과
    /// **같은 디코더 구성**(iso8601 날짜)으로 하위 호환을 검증할 수 있다.
    static func loadConfig(from url: URL) -> UsageConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? decoder.decode(UsageConfig.self, from: data)
        else { return .default }
        return config
    }

    @discardableResult
    static func save(_ config: UsageConfig) -> Bool {
        guard let data = try? encoder.encode(config) else { return false }
        return writeAtomically(data, to: configURL)
    }

    // MARK: - Helpers

    /// 위젯이 반쯤 쓰인 파일을 읽지 않도록 임시 파일에 쓰고 교체한다.
    private static func writeAtomically(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
