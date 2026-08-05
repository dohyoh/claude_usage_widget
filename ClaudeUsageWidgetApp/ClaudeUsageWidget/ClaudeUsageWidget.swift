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
    /// 메뉴바 앱이 내려준 실측. 아직 없거나 리셋이 지났으면 nil.
    let server: ServerUsage?
    /// 실측을 보여줄 수 없는 이유. 보여줄 실측이 있으면 nil.
    let reason: String?
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(context.isPreview ? .sample : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = currentEntry()
        // WidgetKit은 요청한 간격을 그대로 지켜주지 않는다(실질 수 분~수십 분).
        // 초 단위 실시간은 메뉴바 앱이 담당하고, 위젯은 백업 표시로 쓴다.
        let next = Date().addingTimeInterval(5 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    /// 메뉴바 앱이 내려준 스냅샷의 실측을 읽는다.
    ///
    /// 위젯은 샌드박스라 claude.ai를 조회할 수 없으므로 스냅샷이 유일한 출처다. 스냅샷이
    /// 낡았다고 버리지 않는다 — 위젯은 시스템이 깨우는 시점에 의존해 구조적으로 낡아 있고,
    /// 버리면 화면이 빈다. 대신 조회 시각을 함께 그려 신선도를 사용자가 판단하게 한다.
    private func currentEntry() -> UsageEntry {
        let now = Date()
        let stored = UsageSharedStore.loadSnapshot()?.server
        if let server = stored?.validated(at: now) {
            return UsageEntry(date: now, server: server, reason: nil)
        }
        return UsageEntry(date: now, server: nil, reason: Self.reason(for: stored))
    }

    /// 실측이 없는 이유를 사용자 문구로 바꾼다.
    private static func reason(for server: ServerUsage?) -> String {
        guard let server else { return "claude.ai에 로그인하면 표시됩니다" }
        if let failure = server.failureReason { return failure }
        // 리셋이 지나 지난 창의 값만 남은 상태. 메뉴바 앱이 다음 조회에서 새 창을 받아온다.
        return "새 한도 창을 불러오는 중…"
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

/// 위젯이 그리는 바 하나의 재료. 값 채우기와 배치를 나눠 둔다.
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

    private var server: ServerUsage? { entry.server }

    /// 줄 사이 간격. 작은 위젯은 155pt 안에 헤더 + 바 두 개 + 배지를 넣어야 해서 좁힌다.
    private var spacing: CGFloat { isCompact ? 4 : 6 }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            header

            if let reason = entry.reason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
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
                 size: isCompact ? .compact : .regular)
    }

    /// 지금 그릴 바 목록. 실측이 유일한 출처다.
    private var specs: [UsageBarSpec] {
        guard let server else { return [] }
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

    // MARK: - 하단 배지

    /// 이 숫자가 언제 기준인지. 위젯은 시스템이 깨우는 시점에 의존해 늘 조금 낡아 있으므로
    /// 조회 시각을 적어 신선도를 사용자가 판단하게 한다.
    @ViewBuilder private var footer: some View {
        if let fetchedAt = server?.fetchedAt {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.seal")
                Text(fetchedAt, format: .dateTime.hour().minute())
                Spacer(minLength: 0)
                // 시간 바의 색을 한 번 설명해 준다. 작은 위젯에는 자리가 없다.
                if !isCompact, specs.contains(where: { $0.elapsedRatio != nil }) {
                    UsageElapsedLegend()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
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

extension UsageEntry {
    /// 위젯 갤러리 미리보기용 값.
    static var sample: UsageEntry {
        let now = Date()
        let server = ServerUsage(
            fetchedAt: now,
            fiveHour: ServerUsageWindow(utilizationPercent: 62,
                                        resetsAt: now.addingTimeInterval(3 * 60 * 60)),
            sevenDay: ServerUsageWindow(utilizationPercent: 39,
                                        resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60)),
            sevenDayOpus: nil,
            organizationName: "My Org",
            failureReason: nil)
        return UsageEntry(date: now, server: server, reason: nil)
    }
}

#Preview("Small", as: .systemSmall) {
    ClaudeUsageWidget()
} timeline: {
    UsageEntry.sample
}

#Preview("Medium", as: .systemMedium) {
    ClaudeUsageWidget()
} timeline: {
    UsageEntry.sample
}
