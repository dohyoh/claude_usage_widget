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

    private var snapshot: UsageSnapshot { entry.snapshot }

    private var config: UsageConfig { entry.config }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
            header

            if let reason = snapshot.failureReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else if let server = snapshot.usableServerUsage(config: config) {
                serverContent(server)
            } else if let block = snapshot.activeBlock {
                sessionBar(block)
                weeklyBar   // 서버 실측 경로와 같게, 작은 크기에서도 함께 보여준다
                Spacer(minLength: 0)
                estimateResetLine(block)
            } else {
                Spacer(minLength: 0)
                Text("진행 중인 5시간 창 없음")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                weeklyBar
                Spacer(minLength: 0)
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
            if family != .systemSmall {
                Text(entry.date, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 서버 실측 (스냅샷에 있으면 우선)

    @ViewBuilder private func serverContent(_ server: ServerUsage) -> some View {
        if let five = server.fiveHour {
            UsageBar(title: "5시간 창",
                     ratio: five.ratio,
                     detail: serverDetail(five),
                     trailing: "\(Int(five.utilizationPercent.rounded()))%")
        }
        // 주간은 크기와 무관하게 함께 보여준다 — 5시간 창만으로는 주간 한도에
        // 얼마나 다가섰는지 알 수 없다.
        if let week = server.sevenDay {
            UsageBar(title: "주간",
                     ratio: week.ratio,
                     detail: serverDetail(week),
                     trailing: "\(Int(week.utilizationPercent.rounded()))%")
        }
        // Opus 전용 한도는 자리가 남는 크기에서만.
        if family != .systemSmall, let opus = server.sevenDayOpus {
            UsageBar(title: "주간 · Opus",
                     ratio: opus.ratio,
                     detail: serverDetail(opus),
                     trailing: "\(Int(opus.utilizationPercent.rounded()))%")
        }
        Spacer(minLength: 0)
        HStack(spacing: 3) {
            Image(systemName: "checkmark.seal")
            Text("실측")
            Spacer(minLength: 0)
            if !entry.usedSharedSnapshot {
                // 메뉴바 앱이 갱신을 멈춘 상태(꺼짐) — 값이 느리게 따라온다는 신호.
                Image(systemName: "bolt.slash")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// 각 바 아래에 남은 시간을 적는다. 주간은 며칠 단위라 "5d 3h" 형태로 나온다.
    private func serverDetail(_ window: ServerUsageWindow) -> String {
        guard let reset = window.resetsAt else { return "claude.ai 실측" }
        return "\(max(0, reset.timeIntervalSince(entry.date)).compactRemainingString) 남음"
    }

    // MARK: - 로컬 추정 (서버 없을 때)

    private func sessionBar(_ block: SessionBlock) -> some View {
        let ratio = snapshot.sessionUtilization(config: config)
        return UsageBar(title: "5시간 창",
                        ratio: ratio,
                        detail: "\(config.metric.format(block.tokens.value(for: config.metric))) / \(config.metric.format(config.sessionLimit))",
                        trailing: "\(Int((ratio * 100).rounded()))%")
    }

    private var weeklyBar: some View {
        let ratio = snapshot.weeklyUtilization(config: config)
        return UsageBar(title: config.weeklyTitle,
                        ratio: ratio,
                        detail: "\(config.metric.format(snapshot.weeklyTokens.value(for: config.metric))) / \(config.metric.format(config.weeklyLimit))",
                        trailing: "\(Int((ratio * 100).rounded()))%")
    }

    private func estimateResetLine(_ block: SessionBlock) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
            Text("\(block.remainingTime(at: entry.date).compactDurationString) 남음")
            Spacer(minLength: 0)
            if !entry.usedSharedSnapshot {
                // 메뉴바 앱이 꺼져 있으면 갱신이 느리다는 신호.
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
