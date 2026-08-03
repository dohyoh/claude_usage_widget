//
//  UsageModels.swift
//  Shared between ClaudeUsageWidgetApp (menu bar) and ClaudeUsageWidgetExtension.
//

import Foundation

/// 하나의 API 요청에서 소비된 토큰과 그 비용.
struct TokenCounts: Codable, Hashable, Sendable {
    var input: Int = 0
    var output: Int = 0
    var cacheCreation: Int = 0
    var cacheRead: Int = 0
    /// 캐시 쓰기는 TTL에 따라 단가가 다르므로 나눠 센다.
    var cacheCreation1h: Int = 0
    var cacheCreation5m: Int = 0
    /// 모델별 단가를 적용해 누적한 USD 비용.
    var costUSD: Double = 0

    /// 캐시 읽기를 제외한 합계.
    var billable: Int { input + output + cacheCreation }

    /// 로그에 기록된 모든 토큰의 합계.
    var total: Int { input + output + cacheCreation + cacheRead }

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input + rhs.input,
                    output: lhs.output + rhs.output,
                    cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
                    cacheRead: lhs.cacheRead + rhs.cacheRead,
                    cacheCreation1h: lhs.cacheCreation1h + rhs.cacheCreation1h,
                    cacheCreation5m: lhs.cacheCreation5m + rhs.cacheCreation5m,
                    costUSD: lhs.costUSD + rhs.costUSD)
    }

    static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs = lhs + rhs
    }

    /// 선택한 측정 방식에 해당하는 값.
    func value(for metric: UsageMetric) -> Double {
        switch metric {
        case .billableTokens: return Double(billable)
        case .totalTokens: return Double(total)
        case .costUSD: return costUSD
        }
    }
}

/// 한도 소진율을 무엇으로 재는가.
///
/// Claude는 실제 한도 산정식을 공개하지 않는다. 세 방식 중 하나를 고르고
/// 설정에서 캘리브레이션하면 실제 표시와 맞출 수 있다.
enum UsageMetric: String, Codable, CaseIterable, Sendable {
    /// 입력 + 출력 + 캐시 쓰기. 캐시 읽기를 제외한다.
    case billableTokens
    /// 캐시 읽기까지 포함한 모든 토큰.
    case totalTokens
    /// 모델별 단가를 적용한 USD 비용. 캐시 읽기의 낮은 단가가 반영된다.
    case costUSD

    var title: String {
        switch self {
        case .billableTokens: return "토큰 (캐시 읽기 제외)"
        case .totalTokens: return "토큰 (전체)"
        case .costUSD: return "비용 환산 (USD)"
        }
    }

    var detail: String {
        switch self {
        case .billableTokens: return "입력 + 출력 + 캐시 쓰기"
        case .totalTokens: return "캐시 읽기까지 모두 합산"
        case .costUSD: return "모델별 단가 적용 · 캐시 읽기는 입력의 1/10"
        }
    }

    /// 한도 입력 칸에 붙는 단위.
    var unit: String { self == .costUSD ? "USD" : "토큰" }

    /// 화면에 값을 표시하는 방법.
    func format(_ value: Double) -> String {
        switch self {
        case .costUSD:
            return String(format: "$%.2f", value)
        case .billableTokens, .totalTokens:
            return Int(value).abbreviatedTokenString
        }
    }

    /// 이 방식의 기본 추정 한도. 어디까지나 출발점이며 캘리브레이션이 필요하다.
    var defaultSessionLimit: Double {
        switch self {
        case .billableTokens: return 2_000_000
        case .totalTokens: return 70_000_000
        case .costUSD: return 60
        }
    }

    var defaultWeeklyLimit: Double {
        switch self {
        case .billableTokens: return 30_000_000
        case .totalTokens: return 1_000_000_000
        case .costUSD: return 900
        }
    }
}

/// 5시간 롤링 한도 창(window) 한 개.
struct SessionBlock: Codable, Hashable, Sendable {
    /// 창의 시작 시각 — 창을 여는 첫 요청 시각을 정시로 내림한 값.
    var startedAt: Date
    /// 창 안에서 마지막으로 관측된 요청 시각.
    var lastActivityAt: Date
    var tokens: TokenCounts
    var requestCount: Int
    /// 모델 ID별 billable 토큰.
    var tokensByModel: [String: Int]

    var endsAt: Date { startedAt.addingTimeInterval(ClaudeUsageLimits.sessionWindow) }
    func isActive(at now: Date) -> Bool { now < endsAt }
    func remainingTime(at now: Date) -> TimeInterval { max(0, endsAt.timeIntervalSince(now)) }

    /// 5시간 창에서 지금까지 지나간 비율(0...1) — 경과 시간 바에 쓴다.
    func elapsedRatio(at now: Date) -> Double {
        min(1, max(0, now.timeIntervalSince(startedAt) / ClaudeUsageLimits.sessionWindow))
    }
}

/// 서버(claude.ai)가 알려주는 한도 창 하나의 실측 소진율.
///
/// 로그 기반 추정과 달리 Claude 서버가 계산한 실제 백분율이라 한도 값을 몰라도 정확하다.
/// 다만 서버는 백분율과 리셋 시각만 주고 토큰 수·비용·모델별 분해는 주지 않는다.
struct ServerUsageWindow: Codable, Hashable, Sendable {
    /// 0...100 백분율. 서버가 계산한 실제 소진율.
    var utilizationPercent: Double
    /// 이 창이 리셋되는 정확한 시각.
    var resetsAt: Date?

    /// 진행 바에 넣기 좋은 0...1 비율.
    var ratio: Double { max(0, utilizationPercent / 100) }

    /// 이 창이 아직 리셋되지 않았는지. 리셋이 지났으면 백분율은 지난 창의 값이다.
    func isCurrent(at now: Date) -> Bool {
        guard let resetsAt else { return true }
        return now < resetsAt
    }

    /// 리셋까지 남은 시간. 서버가 리셋 시각을 주지 않았으면 nil.
    func remainingTime(at now: Date) -> TimeInterval? {
        guard let resetsAt else { return nil }
        return max(0, resetsAt.timeIntervalSince(now))
    }

    /// 창 전체 길이에서 지금까지 지나간 비율(0...1) — 경과 시간 바에 쓴다.
    ///
    /// 서버는 창의 시작 시각을 주지 않으므로 리셋 시각에서 역산한다.
    /// - Parameter window: 이 창의 전체 길이. 5시간 창이면 5시간, 주간이면 7일.
    func elapsedRatio(at now: Date, window: TimeInterval) -> Double? {
        guard let remaining = remainingTime(at: now), window > 0 else { return nil }
        return min(1, max(0, 1 - remaining / window))
    }
}

/// claude.ai `/api/organizations/{org}/usage` 응답에서 뽑은 실측 사용량.
///
/// 앱이 자체 로그인 창으로 확보한 세션으로 조회하므로, Claude Code·데스크톱·웹을 모두
/// 포함한 **그 계정 전체** 사용량이다.
struct ServerUsage: Codable, Hashable, Sendable {
    /// 이 값을 서버에서 가져온 시각. 신선도 판단에 쓴다.
    var fetchedAt: Date
    /// 5시간 한도 창.
    var fiveHour: ServerUsageWindow?
    /// 주간(7일) 전체 한도.
    var sevenDay: ServerUsageWindow?
    /// 주간 Opus 전용 한도(Max 요금제). 없으면 nil.
    var sevenDayOpus: ServerUsageWindow?
    /// 조회한 조직 이름 — 진단용.
    var organizationName: String?
    /// 조회 실패 시 사용자에게 보여줄 메시지. 성공이면 nil.
    var failureReason: String?
    /// 설정에서 고른 조직을 찾을 수 없어 다른 조직으로 조회했을 때의 알림.
    ///
    /// 조회 자체는 성공했으므로 `failureReason`이 아니다. 다만 사용자가 지정한 것과 다른
    /// 조직의 숫자이므로 조용히 넘기지 않는다. 이전 버전 스냅샷에 이 키가 없어도 디코딩이
    /// 깨지지 않게 Optional 로 둔다.
    var fallbackNotice: String?

    /// 표시 가능한 실측 데이터가 있는지.
    var isUsable: Bool { failureReason == nil && (fiveHour != nil || sevenDay != nil) }

    /// 아직 표시해도 되는 창만 남긴다. 남는 게 없으면 nil.
    ///
    /// 위젯 타임라인은 시스템이 정한 시점에만 깨어나므로 스냅샷이 수 분~수십 분 낡을 수 있다.
    /// 그때 서버 실측을 버리고 로컬 추정으로 돌아가면, 같은 데이터를 보는 두 위젯(알림센터·
    /// 데스크톱)이 깨어난 시점에 따라 **서로 다른 수치**를 보여준다. 그래서 스냅샷 신선도와
    /// 분리해 이 값 자체의 유효성만 따진다 — 리셋이 지난 창과 너무 오래된 조회만 버린다.
    func validated(at now: Date, maxAge: TimeInterval = 30 * 60) -> ServerUsage? {
        guard failureReason == nil, now.timeIntervalSince(fetchedAt) < maxAge else { return nil }
        var result = self
        if let window = fiveHour, !window.isCurrent(at: now) { result.fiveHour = nil }
        if let window = sevenDay, !window.isCurrent(at: now) { result.sevenDay = nil }
        if let window = sevenDayOpus, !window.isCurrent(at: now) { result.sevenDayOpus = nil }
        return result.isUsable ? result : nil
    }

    nonisolated static func failed(_ reason: String, at date: Date) -> ServerUsage {
        ServerUsage(fetchedAt: date, fiveHour: nil, sevenDay: nil,
                    sevenDayOpus: nil, organizationName: nil, failureReason: reason)
    }
}

/// 위젯과 메뉴바가 함께 렌더링하는 단일 데이터 스냅샷.
struct UsageSnapshot: Codable, Hashable, Sendable {
    /// 스냅샷을 만든 시각.
    var generatedAt: Date
    /// 현재 진행 중인 5시간 창. 최근 5시간 내 활동이 없으면 nil.
    var activeBlock: SessionBlock?
    /// 최근 7일 사용량.
    var weeklyTokens: TokenCounts
    /// 오늘(로컬 자정 기준) 사용량.
    var todayTokens: TokenCounts
    /// 최근 7일 모델별 billable 토큰.
    var weeklyTokensByModel: [String: Int]
    /// 파싱 대상 세션 파일 수 — 데이터 유무 진단용.
    var scannedSessionCount: Int
    /// 읽기 실패 시 사용자에게 보여줄 메시지.
    var failureReason: String?
    /// claude.ai에서 가져온 계정 전체 실측 사용량. 메뉴바 앱만 채운다(위젯은 샌드박스).
    /// 이전 버전 스냅샷과의 호환을 위해 Optional — 키가 없으면 nil로 디코딩된다.
    var server: ServerUsage?

    static let empty = UsageSnapshot(generatedAt: .distantPast,
                                     activeBlock: nil,
                                     weeklyTokens: TokenCounts(),
                                     todayTokens: TokenCounts(),
                                     weeklyTokensByModel: [:],
                                     scannedSessionCount: 0,
                                     failureReason: nil,
                                     server: nil)

    /// 진행 중인 창의 측정값.
    func sessionValue(for metric: UsageMetric) -> Double {
        activeBlock?.tokens.value(for: metric) ?? 0
    }

    /// 5시간 창 한도 소진율(0...1+). 한도는 추정치다.
    func sessionUtilization(config: UsageConfig) -> Double {
        guard config.sessionLimit > 0 else { return 0 }
        return sessionValue(for: config.metric) / config.sessionLimit
    }

    /// 주간 한도 소진율(0...1+). 한도는 추정치다.
    func weeklyUtilization(config: UsageConfig) -> Double {
        guard config.weeklyLimit > 0 else { return 0 }
        return weeklyTokens.value(for: config.metric) / config.weeklyLimit
    }

    // MARK: - 서버 실측 우선 표시

    /// 표시에 쓸 서버 실측값. 설정에서 껐거나 실패했으면 nil.
    func usableServerUsage(config: UsageConfig) -> ServerUsage? {
        guard config.showsServerUsage, let server, server.isUsable else { return nil }
        return server
    }

    /// 5시간 창 소진율. 서버 실측이 있으면 그 값(0...1), 없으면 로그 기반 추정.
    func effectiveSessionRatio(config: UsageConfig) -> Double {
        if let window = usableServerUsage(config: config)?.fiveHour { return window.ratio }
        return sessionUtilization(config: config)
    }

    /// 주간 소진율. 서버 실측 우선.
    func effectiveWeeklyRatio(config: UsageConfig) -> Double {
        if let window = usableServerUsage(config: config)?.sevenDay { return window.ratio }
        return weeklyUtilization(config: config)
    }
}

/// 한도 관련 상수. Claude는 남은 한도를 로컬에 기록하지 않으므로
/// 백분율 표시는 사용자가 조정하는 추정 한도에 의존한다.
enum ClaudeUsageLimits {
    /// 5시간 롤링 창 길이.
    static let sessionWindow: TimeInterval = 5 * 60 * 60

    /// 주간 집계 구간.
    static let weeklyWindow: TimeInterval = 7 * 24 * 60 * 60
}

extension Int {
    /// 1.2M / 340K 처럼 위젯 폭에 맞는 짧은 표기.
    var abbreviatedTokenString: String {
        switch self {
        case 1_000_000...:
            return String(format: "%.1fM", Double(self) / 1_000_000)
        case 1_000...:
            return String(format: "%.0fK", Double(self) / 1_000)
        default:
            return "\(self)"
        }
    }
}

extension TimeInterval {
    /// "3d 5h" / "2h 14m" / "43m" — 며칠 단위로 남는 주간 한도에도 쓸 수 있는 표기.
    var compactRemainingString: String {
        let total = Int(self.rounded())
        let days = total / 86_400
        guard days > 0 else { return compactDurationString }
        return "\(days)d \((total % 86_400) / 3600)h"
    }

    /// "2h 14m" / "43m" 형태의 남은 시간 표기.
    var compactDurationString: String {
        let total = Int(self.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
