//
//  UsageSharedStore.swift
//  Shared between ClaudeUsageWidgetApp (menu bar) and ClaudeUsageWidgetExtension.
//
//  메뉴바 앱과 위젯이 주고받는 파일 두 개를 관리한다.
//  App Group 대신 파일을 쓰는 이유는 README의 "App Group 대신 파일 공유" 절 참고.
//

import Foundation

/// 사용자가 조정하는 표시 설정.
///
/// 사용량 숫자는 전부 claude.ai 실측에서 오므로 여기에 한도나 측정 방식이 없다. 남은 것은
/// «어떻게 보여줄지»(메뉴바)와 «어디서 얼마나 자주 가져올지»(조직·주기)뿐이다.
///
/// 필드를 지워도 낡은 설정 파일은 그대로 읽힌다 — 합성 `Decodable` 이 `CodingKeys` 에 없는
/// 키를 무시하므로, 사용자가 고른 메뉴바 디자인·색·조직은 보존되고 다음 저장에서 죽은 키가
/// 사라진다.
struct UsageConfig: Codable, Hashable, Sendable {
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

    /// claude.ai 세션을 어디서 가져올지.
    ///
    /// `"auto"`(앱 세션 → 기본 브라우저), `"app"`, `"default-browser"`, 또는 특정 브라우저
    /// id(`"chrome"` …). 해석은 메뉴바 앱 쪽 `ClaudeSessionSource` 가 하고, 위젯은 쓰지 않는다.
    /// 이전 버전 설정 파일에 키가 없어도 되도록 Optional 로 둔다.
    var cookieSourceID: String?

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

    /// 실측 조회 주기. 0 이하이면 자동 갱신을 하지 않는다(시작 시 1회 + 수동 새로고침).
    var serverRefreshInterval: TimeInterval {
        guard let seconds = serverRefreshSeconds else { return 60 }
        return TimeInterval(max(0, seconds))
    }

    /// 자동 갱신 없이 수동으로만 조회하는 모드인지.
    var serverRefreshIsManual: Bool { serverRefreshInterval <= 0 }

    /// 쿠키 원본 선택값. 설정이 없으면 자동.
    var cookieSource: String { cookieSourceID ?? "auto" }
}

enum UsageSharedStore {
    /// 메뉴바 앱이 주기적으로 덮어쓰는 스냅샷. 위젯은 이걸 읽는 쪽이 훨씬 싸다.
    static var snapshotURL: URL {
        ClaudeUsageReader.defaultClaudeHome.appendingPathComponent(".usage-widget-snapshot.json")
    }

    /// 표시 설정. 샌드박스 때문에 UserDefaults 를 공유할 수 없어 파일로 둔다.
    static var configURL: URL {
        ClaudeUsageReader.defaultClaudeHome.appendingPathComponent(".usage-widget-config.json")
    }

    // MARK: - Snapshot

    static func loadSnapshot() -> UsageSnapshot? {
        loadSnapshot(from: snapshotURL)
    }

    /// 지정한 파일에서 스냅샷을 읽는다. 못 읽거나 형식이 어긋나면 nil.
    ///
    /// 경로를 받는 형태로 열어 둬 테스트가 실제 사용자 파일을 건드리지 않고, 프로덕션과
    /// **같은 디코더 구성**(iso8601 날짜)으로 하위 호환을 검증할 수 있다.
    static func loadSnapshot(from url: URL) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(UsageSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: UsageSnapshot) -> Bool {
        save(snapshot, to: snapshotURL)
    }

    @discardableResult
    static func save(_ snapshot: UsageSnapshot, to url: URL) -> Bool {
        guard let data = try? encoder.encode(snapshot) else { return false }
        return writeAtomically(data, to: url)
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

    // MARK: - Account

    /// 실측을 가져온 계정 캐시. 설정과 수명주기가 달라 파일을 따로 둔다.
    static var accountURL: URL {
        ClaudeUsageReader.defaultClaudeHome.appendingPathComponent(".usage-widget-account.json")
    }

    static func loadAccount() -> AccountCache? {
        loadAccount(from: accountURL)
    }

    /// 지정한 파일에서 계정 캐시를 읽는다. 파일이 없거나 형식이 어긋나면 nil.
    ///
    /// 설정과 달리 기본값이 없다 — 캐시가 없으면 "아직 모른다"이고, 그때는 다시 조회한다.
    static func loadAccount(from url: URL) -> AccountCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(AccountCache.self, from: data)
    }

    @discardableResult
    static func save(_ account: AccountCache) -> Bool {
        save(account, to: accountURL)
    }

    @discardableResult
    static func save(_ account: AccountCache, to url: URL) -> Bool {
        guard let data = try? encoder.encode(account) else { return false }
        return writeAtomically(data, to: url)
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
