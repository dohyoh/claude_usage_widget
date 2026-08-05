//
//  UsagePanel.swift
//  ClaudeUsageWidgetApp
//
//  메뉴바 아이콘을 눌렀을 때 열리는 패널.
//
//  소진율(%)은 claude.ai 실측만 쓴다. 서버가 주지 않는 토큰·모델별 분해는 로컬 로그에서
//  보완하되, 창 경계를 아는 창에만 존재한다 — 경계를 모르면 그 줄을 그리지 않는다.
//

import SwiftUI

struct UsagePanel: View {
    let monitor: UsageMonitor

    @Environment(\.openWindow) private var openWindow
    /// 남은 시간을 초 단위로 흘려보내기 위한 틱.
    @State private var now = Date()

    private var snapshot: UsageSnapshot { monitor.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
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
        if let server = snapshot.usableServerUsage {
            serverSection(server)
        } else {
            serverUnavailable
        }
        Divider()
        localBreakdown
        modelSection
        // 로컬 로그를 아예 읽지 못한 경우 — 상세가 왜 비었는지 알려준다.
        if let reason = snapshot.failureReason {
            failure(reason)
        }
    }

    // MARK: - 헤더 / 푸터

    /// 제목 바로 옆에 새로고침을, 오른쪽 끝에 설정(톱니바퀴)을 둔다.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .foregroundStyle(.tint)
            Text("Claude 사용량")
                .font(.title3)
            Button {
                monitor.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("지금 다시 읽기 (서버 포함)")
            Spacer()
            Button {
                SettingsWindow.activateApp()
                openWindow(id: SettingsWindow.id)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("설정")
        }
        .imageScale(.large)
    }

    private var footer: some View {
        HStack {
            if snapshot.generatedAt == .distantPast {
                Text("읽는 중…")
            } else {
                Text("갱신 \(snapshot.generatedAt, format: .dateTime.hour().minute().second())")
            }
            Spacer()
            Button("종료") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - 서버 실측 섹션

    private func serverSection(_ server: ServerUsage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
            UsageElapsedLegend(size: .large)
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
            .font(.caption)
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
                        elapsedRatio: window.elapsedRatio(at: now, window: length),
                        size: .large)
    }

    /// 실측을 보여줄 수 없을 때. 아직 로그인하지 않았거나 조회가 실패한 상태다.
    ///
    /// 로컬 로그로 소진율을 추정해 대신 채우지 않는다. 로컬 로그에는 데스크톱·웹 사용분이
    /// 없어 계정 전체 소진율보다 낮게 나오고, 그 숫자를 실측과 같은 자리에 같은 모양으로
    /// 그리면 사용자는 구분하지 못한다.
    @ViewBuilder private var serverUnavailable: some View {
        let reason = snapshot.server?.failureReason
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: reason == nil ? "person.crop.circle.badge.plus"
                                            : "wifi.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(reason ?? "claude.ai에 로그인하면 계정 전체 소진율이 표시됩니다")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                // 일시적 실패에는 로그인 버튼을 붙이지 않는다 — 기다리면 풀리는 상태에서
                // 로그인을 권하면 멀쩡한 세션을 버리게 된다.
                if reason == nil {
                    Button("Claude 로그인") { monitor.signIn() }
                        .buttonStyle(.link)
                }
            }
        }
    }

    // MARK: - 로컬 로그 상세

    /// 서버가 주지 않는 토큰 상세. 창 경계를 아는 창만 줄이 생긴다.
    private var localBreakdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude Code 로컬 상세")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let block = snapshot.activeBlock {
                detailRow("이번 5시간 창",
                          "\(block.tokens.billable.abbreviatedTokenString) · 요청 \(block.requestCount)회")
            }
            detailRow("오늘", snapshot.todayTokens.billable.abbreviatedTokenString)
            if let weekly = snapshot.weeklyTokens {
                detailRow("이번 주기",
                          "\(weekly.billable.abbreviatedTokenString) · 캐시 읽기 \(weekly.cacheRead.abbreviatedTokenString)")
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.subheadline)
    }

    /// 이번 주기의 모델별 사용량. 주기 경계를 모르면 집계 자체가 없다.
    @ViewBuilder private var modelSection: some View {
        if let byModel = snapshot.weeklyTokensByModel, !byModel.isEmpty {
            // 소비량이 큰 모델부터 최대 4개.
            let top = byModel.sorted { $0.value > $1.value }.prefix(4)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("모델별 (이번 주기)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(top), id: \.key) { model, tokens in
                    HStack {
                        Text(model.prettyModelName)
                            .font(.subheadline)
                        Spacer()
                        Text(tokens.abbreviatedTokenString)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
}
