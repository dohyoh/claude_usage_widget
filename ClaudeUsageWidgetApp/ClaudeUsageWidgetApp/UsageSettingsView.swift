//
//  UsageSettingsView.swift
//  ClaudeUsageWidgetApp
//
//  Claude는 남은 한도도, 한도 산정식도 로컬에 남기지 않는다. 그래서 백분율은
//  "어떤 값으로 재는가(metric)" + "그 값의 한도가 얼마인가"의 조합으로 추정한다.
//  Claude가 보여주는 %를 캘리브레이션에 넣으면 한도를 역산해 맞출 수 있다.
//

import SwiftUI

/// 설정 창을 여는 쪽과 정의하는 쪽이 공유하는 식별자.
enum SettingsWindow {
    static let id = "usage-settings"

    /// 메뉴바 앱은 `.accessory` 정책이라 activate 없이는 창이 뒤에 열린다.
    static func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct UsageSettingsView: View {
    @Bindable var monitor: UsageMonitor
    @State private var launch = LaunchAtLoginController()
    /// 캘리브레이션 입력 — Claude에서 본 소진율.
    @State private var observedPercent: Double = 0
    /// 5시간 창 리셋 시각 입력. 시·분만 쓴다.
    @State private var sessionResetTime = Date()
    /// 입력한 리셋 시각이 5시간 범위를 벗어나 거부됐는지.
    @State private var resetInputRejected = false

    private var config: UsageConfig { monitor.config }

    /// 시·분만 지정한 오늘 날짜의 Date — DatePicker 바인딩용.
    private static func time(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    /// 입력한 시·분을 5시간 창 리셋 시각으로 해석한다.
    ///
    /// 리셋은 지금 기준 ±5시간 안에 있어야 의미가 있다. 아직 오지 않았으면 현재 창의
    /// 끝이고, 방금 지났으면 새 창의 시작이다. 그 범위를 넘기면 엉뚱한 창 경계를
    /// 강제하게 되므로 거부한다. 하루를 더하거나 빼서 자정 경계도 처리한다.
    private static func sessionReset(from time: Date, now: Date = Date()) -> Date? {
        let day: TimeInterval = 24 * 60 * 60
        let window = ClaudeUsageLimits.sessionWindow
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        guard var candidate = Calendar.current.date(bySettingHour: c.hour ?? 0,
                                                   minute: c.minute ?? 0,
                                                   second: 0,
                                                   of: now) else { return nil }
        if candidate < now.addingTimeInterval(-window) {
            candidate.addTimeInterval(day)
        } else if candidate > now.addingTimeInterval(window) {
            candidate.addTimeInterval(-day)
        }
        guard abs(candidate.timeIntervalSince(now)) <= window else { return nil }
        return candidate
    }

    var body: some View {
        Form {
            Section {
                Toggle("로그인 시 자동 실행", isOn: Binding(
                    get: { launch.isEnabled },
                    set: { launch.setEnabled($0) }
                ))
                if !launch.isInstalledInApplications {
                    Label("앱이 /Applications 밖에서 실행 중입니다. 설치 후 켜세요.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = launch.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("실행")
            }

            Section {
                Toggle("claude.ai 실측 사용량 표시", isOn: Binding(
                    get: { config.showsServerUsage },
                    set: { monitor.config.serverUsageEnabled = $0 }
                ))
                if config.showsServerUsage {
                    Picker("갱신 주기", selection: Binding(
                        get: { config.serverRefreshSeconds ?? 60 },
                        set: { monitor.config.serverRefreshSeconds = $0 }
                    )) {
                        Text("30초").tag(30)
                        Text("1분").tag(60)
                        Text("3분").tag(180)
                        Text("5분").tag(300)
                        Text("10분").tag(600)
                        Text("30분").tag(1800)
                        Text("수동 (시작 시 1회 + 새로고침)").tag(0)
                    }
                    serverStatus
                }
            } header: {
                Text("실측 사용량 (claude.ai)")
            } footer: {
                Text("Claude 데스크톱 앱의 로그인 쿠키를 Safe Storage 키로 복호화해 계정 전체(코드·데스크톱·웹) 실측 소진율을 가져옵니다. Safe Storage 키는 앱 실행당 한 번만 읽어 재사용하고, 위 주기마다 사용량만 다시 조회합니다. '수동'으로 두면 시작 때 1회만 가져오고 이후엔 패널의 새로고침 버튼으로 갱신합니다. 첫 조회 때 키체인 접근 허용 창이 뜹니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("측정 방식", selection: Binding(
                    get: { config.metric },
                    set: { monitor.config.changeMetric(to: $0) }
                )) {
                    ForEach(UsageMetric.allCases, id: \.self) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                Text(config.metric.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("측정 방식")
            } footer: {
                Text("캐시 읽기는 이 세션에서 전체 비용의 절반을 넘습니다. 캐시 읽기를 제외하면 실제 소진율보다 낮게 나옵니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("주간 리셋 요일", selection: Binding(
                    get: { config.weeklyResetWeekday ?? 0 },
                    set: { monitor.config.weeklyResetWeekday = $0 == 0 ? nil : $0 }
                )) {
                    Text("모름 (최근 7일 롤링)").tag(0)
                    ForEach(1...7, id: \.self) { weekday in
                        Text(UsageConfig.weekdaySymbol(weekday)).tag(weekday)
                    }
                }
                if config.weeklyResetWeekday != nil {
                    DatePicker("주간 리셋 시각",
                               selection: Binding(
                                   get: { Self.time(hour: config.weeklyResetHour,
                                                    minute: config.weeklyResetMinute) },
                                   set: { newValue in
                                       let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                                       monitor.config.weeklyResetHour = c.hour ?? 15
                                       monitor.config.weeklyResetMinute = c.minute ?? 0
                                   }),
                               displayedComponents: .hourAndMinute)
                    if let next = config.nextWeeklyReset(now: Date()) {
                        LabeledContent("다음 주간 리셋") {
                            Text(next, format: .dateTime.weekday().month().day().hour().minute())
                                .font(.caption)
                        }
                    }
                }

                Divider()

                DatePicker("5시간 창 리셋 시각", selection: $sessionResetTime,
                           displayedComponents: .hourAndMinute)
                HStack {
                    if let reset = config.sessionResetAt,
                       let start = config.sessionWindowStart(now: Date()) {
                        Text("적용 중: 리셋 \(reset, format: .dateTime.hour().minute()) · 창 시작 \(start, format: .dateTime.hour().minute())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("해제") { monitor.config.sessionResetAt = nil }
                            .buttonStyle(.link)
                    } else {
                        Text("미적용 — 로그 기준으로 창을 추정합니다")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("적용") {
                        if let reset = Self.sessionReset(from: sessionResetTime) {
                            monitor.config.sessionResetAt = reset
                            resetInputRejected = false
                        } else {
                            resetInputRejected = true
                        }
                    }
                }
                if resetInputRejected {
                    Label("리셋 시각은 지금 기준 ±5시간 안이어야 합니다. 그보다 먼 값은 창 경계를 잘못 잡습니다.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("리셋 시점")
            } footer: {
                Text("Claude 앱에 표시되는 리셋 시각을 넣으면 창 경계가 정확해집니다. 주간 한도는 롤링이 아니라 고정 주기(예: 화요일 15:00)로 리셋되므로, 요일을 지정하지 않으면 지난 주기 사용량까지 함께 잡혀 과다 계상됩니다. 5시간 창 리셋 시각은 지나면 자동으로 무시됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LimitField(title: "5시간 창 한도",
                           value: $monitor.config.sessionLimit,
                           metric: config.metric)
                LimitField(title: "주간 한도",
                           value: $monitor.config.weeklyLimit,
                           metric: config.metric)
            } header: {
                Text("추정 한도")
            }

            Section {
                LabeledContent("현재 측정값") {
                    Text(config.metric.format(monitor.currentSessionValue))
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    TextField("", value: $observedPercent, format: .number)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                    Text("%")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("이 값에 맞추기") {
                        monitor.config.calibrate(observedPercent: observedPercent,
                                                 currentValue: monitor.currentSessionValue)
                        observedPercent = 0
                    }
                    .disabled(observedPercent <= 0 || monitor.currentSessionValue <= 0)
                }
            } header: {
                Text("캘리브레이션")
            } footer: {
                Text("Claude Code에서 `/usage`로 본 5시간 한도 %를 입력하고 «이 값에 맞추기»를 누르면 한도를 역산합니다. 주간 한도는 5시간 한도와의 비율을 유지한 채 함께 조정됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("데이터 소스") {
                    Text("~/.claude/projects/**/*.jsonl")
                        .font(.caption)
                        .monospaced()
                        .textSelection(.enabled)
                }
                LabeledContent("세션 파일") {
                    Text("\(monitor.snapshot.scannedSessionCount)개")
                }
                if let block = monitor.snapshot.activeBlock {
                    LabeledContent("창 비용 환산") {
                        Text(String(format: "$%.2f", block.tokens.costUSD))
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("진단")
            } footer: {
                Text("로컬 추정은 ~/.claude 로그(Claude Code)만 봅니다. 데스크톱·웹 사용분은 로그에 없어 로컬 추정에서는 빠지지만, 위의 claude.ai 실측에는 포함됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("기본값으로 되돌리기") {
                    monitor.config = .default
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    /// 실측 사용량 조회 상태 — 성공 시 %·조직·갱신 시각, 실패 시 사유.
    @ViewBuilder private var serverStatus: some View {
        if let server = monitor.snapshot.server {
            if let reason = server.failureReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if server.isUsable {
                if let five = server.fiveHour {
                    LabeledContent("5시간 창") {
                        Text("\(Int(five.utilizationPercent.rounded()))%").monospacedDigit()
                    }
                }
                if let week = server.sevenDay {
                    LabeledContent("주간") {
                        Text("\(Int(week.utilizationPercent.rounded()))%").monospacedDigit()
                    }
                }
                if let opus = server.sevenDayOpus {
                    LabeledContent("주간 Opus") {
                        Text("\(Int(opus.utilizationPercent.rounded()))%").monospacedDigit()
                    }
                }
                if let name = server.organizationName {
                    LabeledContent("조직") { Text(name).lineLimit(1) }
                }
                LabeledContent("갱신") {
                    Text(server.fetchedAt, format: .dateTime.hour().minute().second())
                }
            }
        } else {
            Text("불러오는 중… 키체인 접근을 허용하면 표시됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 한도를 숫자로 입력받는 줄. 단위와 축약 표기를 함께 보여준다.
private struct LimitField: View {
    let title: String
    @Binding var value: Double
    let metric: UsageMetric

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: $value, format: .number)
                    .frame(width: 120)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Text(metric.unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                Text(metric.format(value))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 60, alignment: .leading)
            }
        }
    }
}
