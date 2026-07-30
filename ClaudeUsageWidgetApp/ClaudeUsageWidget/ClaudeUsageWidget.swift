//
//  ClaudeUsageWidget.swift
//  ClaudeUsageWidget
//
//  Created by 송동훈 on 7/29/26.
//

import WidgetKit
import SwiftUI

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
    let config: UsageConfig
    /// 메뉴바 앱이 내려준 스냅샷을 그대로 썼는지 여부. 위젯 하단 표시에 쓴다.
    let usedSharedSnapshot: Bool
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: .sample, config: .default, usedSharedSnapshot: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        if context.isPreview {
            completion(UsageEntry(date: Date(), snapshot: .sample, config: .default, usedSharedSnapshot: true))
        } else {
            completion(currentEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = currentEntry()
        // WidgetKit은 요청한 간격을 그대로 지켜주지 않는다(실질 수 분~수십 분).
        // 초 단위 실시간은 메뉴바 앱이 담당하고, 위젯은 백업 표시로 쓴다.
        let next = Date().addingTimeInterval(5 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    /// 메뉴바 앱의 스냅샷이 신선하면 그대로 쓰고, 아니면 위젯이 직접 로그를 읽는다.
    ///
    /// 어느 쪽이든 **서버 실측값은 스냅샷 신선도와 분리해** 판단한다. 로컬 파싱으로
    /// 넘어갈 때 실측을 버리면, 깨어난 시점이 다른 두 위젯(알림센터·데스크톱)이 하나는
    /// 실측을, 하나는 로컬 추정을 보여줘 수치가 어긋난다.
    private func currentEntry() -> UsageEntry {
        let config = UsageSharedStore.loadConfig()
        let now = Date()
        let shared = UsageSharedStore.loadSnapshot()
        // 리셋이 지났거나 너무 오래된 조회만 걸러낸다.
        let server = shared?.server?.validated(at: now)

        if var shared, now.timeIntervalSince(shared.generatedAt) < UsageSharedStore.snapshotFreshness {
            shared.server = server
            return UsageEntry(date: now, snapshot: shared, config: config, usedSharedSnapshot: true)
        }

        var parsed = ClaudeUsageReader().makeSnapshot(now: now, config: config)
        parsed.server = server
        return UsageEntry(date: now, snapshot: parsed, config: config, usedSharedSnapshot: false)
    }
}

struct ClaudeUsageWidgetEntryView: View {
    var entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        // 크기 분기를 파라미터로 내려 준다. `widgetFamily` 는 위젯 밖에서 주입할 수 없어
        // (get-only) 본문을 별도 뷰로 두면 두 크기를 그대로 렌더해 검증할 수 있다.
        UsageWidgetContent(entry: entry, isCompact: family == .systemSmall)
    }
}

/// 위젯이 그리는 바 하나의 재료.
///
/// 실측(서버)과 로컬 추정 두 경로가 **같은 모양**으로 나와야 한다(README «두 경로가 같은
/// 모양이어야 합니다»). 그래서 경로별로 값만 채우고, 그리기와 배치는 한 곳에서 한다.
struct UsageBarSpec: Identifiable {
    let title: String
    /// 소진율(0...1+).
    let ratio: Double
    /// 바 아래 한 줄 — 리셋까지 남은 시간.
    let detail: String
    /// 오른쪽 위 백분율.
    let trailing: String
    /// 창에서 지나간 시간의 비율. 리셋 시점을 모르면 nil.
    var elapsedRatio: Double?

    var id: String { title }
}

/// 위젯 본문. 크기에 따라 밀도와 배치만 달라지고, 보여주는 항목은 같다.
struct UsageWidgetContent: View {
    let entry: UsageEntry
    /// 작은 위젯 — 폭·높이가 모두 좁아 한 열로 촘촘하게 그린다.
    let isCompact: Bool

    private var snapshot: UsageSnapshot { entry.snapshot }

    private var config: UsageConfig { entry.config }

    /// 표시에 쓸 서버 실측값. 없으면 로컬 추정 경로로 간다.
    private var server: ServerUsage? { snapshot.usableServerUsage(config: config) }

    /// 줄 사이 간격. 작은 위젯은 155pt 안에 헤더 + 바 두 개 + 배지를 넣어야 해서 좁힌다.
    private var spacing: CGFloat { isCompact ? 4 : 6 }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            header

            if let reason = snapshot.failureReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                if server == nil, snapshot.activeBlock == nil {
                    Text("진행 중인 5시간 창 없음")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                bars
                Spacer(minLength: 0)
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkle")
                .foregroundStyle(.tint)
            Text("Claude")
                .font(.caption)
                .fontWeight(.semibold)
            Spacer(minLength: 0)
            if !isCompact {
                Text(entry.date, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 바 배치

    @ViewBuilder private var bars: some View {
        let specs = self.specs
        if isCompact || specs.count < 2 {
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(specs) { bar($0) }
            }
        } else {
            // 중간 크기는 폭이 남고 높이가 모자라다. 5시간 창을 왼쪽, 주간 계열을 오른쪽에
            // 두면 Opus 한도까지 세 개가 잘리지 않고 들어간다.
            HStack(alignment: .top, spacing: 14) {
                bar(specs[0])
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(specs.dropFirst()) { bar($0) }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func bar(_ spec: UsageBarSpec) -> some View {
        UsageBar(title: spec.title,
                 ratio: spec.ratio,
                 detail: spec.detail,
                 trailing: spec.trailing,
                 elapsedRatio: spec.elapsedRatio,
                 compact: isCompact)
    }

    /// 지금 그릴 바 목록. 서버 실측이 있으면 그쪽을 쓴다.
    private var specs: [UsageBarSpec] {
        if let server { return serverSpecs(server) }
        return estimateSpecs
    }

    // MARK: - 서버 실측 (스냅샷에 있으면 우선)

    private func serverSpecs(_ server: ServerUsage) -> [UsageBarSpec] {
        var specs: [UsageBarSpec] = []
        if let five = server.fiveHour {
            specs.append(spec(title: "5시간 창", window: five,
                              length: ClaudeUsageLimits.sessionWindow))
        }
        // 주간은 크기와 무관하게 함께 보여준다 — 5시간 창만으로는 주간 한도에
        // 얼마나 다가섰는지 알 수 없다.
        if let week = server.sevenDay {
            specs.append(spec(title: "주간", window: week,
                              length: ClaudeUsageLimits.weeklyWindow))
        }
        // Opus 전용 한도는 자리가 남는 크기에서만.
        if !isCompact, let opus = server.sevenDayOpus {
            specs.append(spec(title: "주간 · Opus", window: opus,
                              length: ClaudeUsageLimits.weeklyWindow))
        }
        return specs
    }

    /// 각 바 아래에 남은 시간을 적는다. 주간은 며칠 단위라 "5d 3h" 형태로 나온다.
    private func spec(title: String, window: ServerUsageWindow, length: TimeInterval) -> UsageBarSpec {
        let remaining = window.remainingTime(at: entry.date)
        return UsageBarSpec(title: title,
                            ratio: window.ratio,
                            detail: remaining.map { "\($0.compactRemainingString) 남음" } ?? "claude.ai 실측",
                            trailing: "\(Int(window.utilizationPercent.rounded()))%",
                            elapsedRatio: window.elapsedRatio(at: entry.date, window: length))
    }

    // MARK: - 로컬 추정 (서버 없을 때)

    // 바 아래 한 줄은 실측 경로와 같이 **리셋까지 남은 시간**을 쓴다. 위젯은 두 경로를
    // 번갈아 그리므로(스냅샷이 낡으면 추정으로 내려간다) 여기서 금액·토큰을 쓰면 같은
    // 위젯이 깨어난 시점에 따라 "$12.40 / $60" 과 "2h 14m 남음" 을 오간다. 금액·토큰
    // 상세는 메뉴바 패널이 담당하고, 위젯은 소진율(%)과 남은 시간만 보여준다.

    private var estimateSpecs: [UsageBarSpec] {
        var specs: [UsageBarSpec] = []
        if let block = snapshot.activeBlock {
            let ratio = snapshot.sessionUtilization(config: config)
            specs.append(UsageBarSpec(title: "5시간 창",
                                      ratio: ratio,
                                      detail: "\(block.remainingTime(at: entry.date).compactDurationString) 남음",
                                      trailing: percent(ratio),
                                      elapsedRatio: block.elapsedRatio(at: entry.date)))
        }
        let weekly = snapshot.weeklyUtilization(config: config)
        specs.append(UsageBarSpec(title: config.weeklyTitle,
                                  ratio: weekly,
                                  detail: weeklyDetail,
                                  trailing: percent(weekly),
                                  elapsedRatio: config.weeklyElapsedRatio(now: entry.date)))
        return specs
    }

    /// 주간은 고정 주기를 알 때만 남은 시간이 나온다 — 롤링 집계에는 리셋 시점이 없다.
    private var weeklyDetail: String {
        guard let reset = config.nextWeeklyReset(now: entry.date) else { return "최근 7일 롤링" }
        return "\(max(0, reset.timeIntervalSince(entry.date)).compactRemainingString) 남음"
    }

    private func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    // MARK: - 하단 배지

    /// 지금 무엇을 근거로 그렸는지. 두 경로가 같은 자리에 같은 모양으로 쓴다.
    private var footer: some View {
        HStack(spacing: 3) {
            Image(systemName: server != nil ? "checkmark.seal" : "chart.bar")
            Text(server != nil ? "실측" : "추정")
            Spacer(minLength: 0)
            // 시간 바의 색을 한 번 설명해 준다. 작은 위젯에는 자리가 없다.
            if !isCompact, specs.contains(where: { $0.elapsedRatio != nil }) {
                UsageElapsedLegend()
            }
            if !entry.usedSharedSnapshot {
                // 메뉴바 앱이 갱신을 멈춘 상태(꺼짐) — 값이 느리게 따라온다는 신호.
                Image(systemName: "bolt.slash")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

struct ClaudeUsageWidget: Widget {
    let kind: String = "ClaudeUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageTimelineProvider()) { entry in
            ClaudeUsageWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Claude Code 사용량")
        .description("5시간 한도 창과 주간 토큰 사용량을 보여줍니다.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

extension UsageSnapshot {
    /// 위젯 갤러리 미리보기용 값.
    static var sample: UsageSnapshot {
        let start = Date().addingTimeInterval(-2 * 60 * 60)
        return UsageSnapshot(generatedAt: Date(),
                             activeBlock: SessionBlock(startedAt: start,
                                                       lastActivityAt: Date(),
                                                       tokens: TokenCounts(input: 420_000,
                                                                           output: 68_000,
                                                                           cacheCreation: 310_000,
                                                                           cacheRead: 4_200_000,
                                                                           cacheCreation1h: 310_000,
                                                                           costUSD: 8.9),
                                                       requestCount: 143,
                                                       tokensByModel: ["claude-opus-5": 798_000]),
                             weeklyTokens: TokenCounts(input: 3_100_000,
                                                       output: 480_000,
                                                       cacheCreation: 2_200_000,
                                                       cacheRead: 31_000_000,
                                                       cacheCreation1h: 2_200_000,
                                                       costUSD: 66.0),
                             todayTokens: TokenCounts(input: 620_000,
                                                      output: 91_000,
                                                      cacheCreation: 410_000,
                                                      cacheRead: 6_100_000,
                                                      cacheCreation1h: 410_000,
                                                      costUSD: 13.2),
                             weeklyTokensByModel: ["claude-opus-5": 5_780_000],
                             scannedSessionCount: 12,
                             failureReason: nil,
                             server: ServerUsage(fetchedAt: Date(),
                                                 fiveHour: ServerUsageWindow(utilizationPercent: 62,
                                                                             resetsAt: Date().addingTimeInterval(3 * 60 * 60)),
                                                 sevenDay: ServerUsageWindow(utilizationPercent: 39,
                                                                             resetsAt: Date().addingTimeInterval(5 * 24 * 60 * 60)),
                                                 sevenDayOpus: nil,
                                                 organizationName: "My Org",
                                                 failureReason: nil))
    }
}

#Preview("Small", as: .systemSmall) {
    ClaudeUsageWidget()
} timeline: {
    UsageEntry(date: .now, snapshot: .sample, config: .default, usedSharedSnapshot: true)
}

#Preview("Medium", as: .systemMedium) {
    ClaudeUsageWidget()
} timeline: {
    UsageEntry(date: .now, snapshot: .sample, config: .default, usedSharedSnapshot: true)
}
