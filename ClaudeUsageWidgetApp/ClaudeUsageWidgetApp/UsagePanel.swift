//
//  UsagePanel.swift
//  ClaudeUsageWidgetApp
//
//  메뉴바 아이콘을 눌렀을 때 열리는 패널.
//
//  claude.ai 실측 사용량(Safe Storage 쿠키로 조회)이 있으면 그 백분율을 주 표시로 쓰고,
//  서버가 주지 않는 토큰·비용·모델별 분해는 로컬 로그에서 보완한다. 서버 조회가 실패하거나
//  꺼져 있으면 기존의 로그 기반 추정 표시로 돌아간다.
//

import SwiftUI

struct UsagePanel: View {
    let monitor: UsageMonitor

    @Environment(\.openWindow) private var openWindow
    /// 남은 시간을 초 단위로 흘려보내기 위한 틱.
    @State private var now = Date()

    private var snapshot: UsageSnapshot { monitor.snapshot }
    private var config: UsageConfig { monitor.config }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 280)
        .task {
            // 패널이 열려 있는 동안만 1초 틱을 돌린다.
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - 본문 분기

    @ViewBuilder private var content: some View {
        if let reason = snapshot.failureReason {
            failure(reason)
        } else if let server = snapshot.usableServerUsage(config: config) {
            serverSection(server)
            Divider()
            localBreakdown(snapshot.activeBlock)
            if !snapshot.weeklyTokensByModel.isEmpty {
                Divider()
                modelSection
            }
        } else if let block = snapshot.activeBlock {
            sessionSection(block)
            Divider()
            totalsSection
            if !snapshot.weeklyTokensByModel.isEmpty {
                Divider()
                modelSection
            }
            serverFailureNote
        } else {
            idle
            Divider()
            totalsSection
            serverFailureNote
        }
    }

    // MARK: - 헤더 / 푸터

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .foregroundStyle(.tint)
            Text("Claude 사용량")
                .font(.headline)
            Spacer()
            Button {
                monitor.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("지금 다시 읽기 (서버 포함)")
        }
    }

    private var footer: some View {
        HStack {
            if snapshot.generatedAt == .distantPast {
                Text("읽는 중…")
            } else {
                Text("갱신 \(snapshot.generatedAt, format: .dateTime.hour().minute().second())")
            }
            Spacer()
            Button("설정") {
                SettingsWindow.activateApp()
                openWindow(id: SettingsWindow.id)
            }
            .buttonStyle(.link)
            Button("종료") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.link)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: - 서버 실측 섹션

    private func serverSection(_ server: ServerUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let five = server.fiveHour {
                serverBar(title: "5시간 창", window: five,
                          length: ClaudeUsageLimits.sessionWindow)
            }
            if let week = server.sevenDay {
                serverBar(title: "주간", window: week,
                          length: ClaudeUsageLimits.weeklyWindow)
            }
            if let opus = server.sevenDayOpus {
                serverBar(title: "주간 · Opus", window: opus,
                          length: ClaudeUsageLimits.weeklyWindow)
            }
            // 바 아래 얇은 청록 바가 무엇인지 한 번 알려준다.
            UsageElapsedLegend()
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.tint)
                Text("claude.ai 실측")
                if let name = server.organizationName {
                    Text("· \(name)")
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(server.fetchedAt, format: .dateTime.hour().minute())
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    /// 서버 실측 창 하나를 진행 바로 그린다. 리셋 시각이 있으면 남은 시간을 곁들인다.
    /// - Parameter length: 이 창의 전체 길이 — 경과 시간 바의 분모다.
    private func serverBar(title: String, window: ServerUsageWindow, length: TimeInterval) -> some View {
        let pct = Int(window.utilizationPercent.rounded())
        let detail: String
        if let reset = window.resetsAt, let remaining = window.remainingTime(at: now) {
            // 주간은 며칠 뒤라 시각만으로는 언제인지 알 수 없다 — 요일을 함께 적는다.
            let stamp = length > 24 * 60 * 60
                ? reset.formatted(.dateTime.weekday().hour().minute())
                : reset.formatted(.dateTime.hour().minute())
            detail = "리셋까지 \(remaining.compactRemainingString) (\(stamp))"
        } else {
            detail = "계정 전체 실측 소진율"
        }
        return UsageBar(title: title,
                        ratio: window.ratio,
                        detail: detail,
                        trailing: "\(pct)%",
                        elapsedRatio: window.elapsedRatio(at: now, window: length))
    }

    /// 서버가 주지 않는 토큰·비용·모델별 상세(로컬 로그 기반).
    private func localBreakdown(_ block: SessionBlock?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude Code 로컬 상세")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let block {
                HStack {
                    Text("이번 5시간 창")
                    Spacer()
                    Text("\(config.metric.format(block.tokens.value(for: config.metric))) · 요청 \(block.requestCount)회")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)
            }
            HStack {
                Label("오늘 \(config.metric.format(snapshot.todayTokens.value(for: config.metric)))",
                      systemImage: "sun.max")
                Spacer()
                Label("캐시 읽기 \(snapshot.weeklyTokens.cacheRead.abbreviatedTokenString)",
                      systemImage: "arrow.down.doc")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 로컬 추정 섹션 (서버 없을 때)

    private func sessionSection(_ block: SessionBlock) -> some View {
        let ratio = snapshot.sessionUtilization(config: config)
        let remaining = block.remainingTime(at: now)
        let used = config.metric.format(block.tokens.value(for: config.metric))
        let limit = config.metric.format(config.sessionLimit)
        return VStack(alignment: .leading, spacing: 6) {
            UsageBar(title: "5시간 창 (추정)",
                     ratio: ratio,
                     detail: "\(used) / \(limit) · 요청 \(block.requestCount)회",
                     trailing: "\(Int((ratio * 100).rounded()))%",
                     elapsedRatio: block.elapsedRatio(at: now))

            // 시계 아이콘을 시간 바와 같은 색으로 둔다 — 이 줄이 그 바의 설명이다.
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .foregroundStyle(Color.usageTimeTint)
                Text("리셋까지 \(remaining.compactDurationString)")
                Text("(\(block.endsAt, format: .dateTime.hour().minute()))")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var totalsSection: some View {
        let weeklyRatio = snapshot.weeklyUtilization(config: config)
        let used = config.metric.format(snapshot.weeklyTokens.value(for: config.metric))
        let limit = config.metric.format(config.weeklyLimit)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                UsageBar(title: "\(config.weeklyTitle) (추정)",
                         ratio: weeklyRatio,
                         detail: "\(used) / \(limit)",
                         trailing: "\(Int((weeklyRatio * 100).rounded()))%",
                         elapsedRatio: config.weeklyElapsedRatio(now: now))

                // 주간 리셋 요일을 지정했을 때만 리셋 시점이 존재한다.
                if let reset = config.nextWeeklyReset(now: now) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .foregroundStyle(Color.usageTimeTint)
                        Text("리셋까지 \(max(0, reset.timeIntervalSince(now)).compactRemainingString)")
                        Text("(\(reset, format: .dateTime.weekday().hour().minute()))")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                Label("오늘 \(config.metric.format(snapshot.todayTokens.value(for: config.metric)))",
                      systemImage: "sun.max")
                Spacer()
                Label("캐시 읽기 \(snapshot.weeklyTokens.cacheRead.abbreviatedTokenString)",
                      systemImage: "arrow.down.doc")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var modelSection: some View {
        // 소비량이 큰 모델부터 최대 4개.
        let top = snapshot.weeklyTokensByModel
            .sorted { $0.value > $1.value }
            .prefix(4)
        return VStack(alignment: .leading, spacing: 3) {
            Text("모델별 (7일)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(Array(top), id: \.key) { model, tokens in
                HStack {
                    Text(model.prettyModelName)
                        .font(.caption)
                    Spacer()
                    Text(tokens.abbreviatedTokenString)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var idle: some View {
        HStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .foregroundStyle(.secondary)
            Text("진행 중인 5시간 창이 없습니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func failure(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(reason)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 서버 실측을 켰지만 조회에 실패했을 때만 보이는 작은 안내.
    @ViewBuilder private var serverFailureNote: some View {
        if config.showsServerUsage, let reason = snapshot.server?.failureReason {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "wifi.exclamationmark")
                Text("실측 사용량: \(reason)")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
