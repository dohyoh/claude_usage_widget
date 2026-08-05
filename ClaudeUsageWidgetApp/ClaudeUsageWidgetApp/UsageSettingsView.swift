//
//  UsageSettingsView.swift
//  ClaudeUsageWidgetApp
//
//  사용량 숫자는 전부 claude.ai 실측에서 오므로 여기에 한도나 측정 방식을 고르는 칸이
//  없다. 남은 것은 «어떻게 보여줄지»(실행·메뉴바)와 «어디서 얼마나 자주 가져올지»
//  (계정·조직·주기)뿐이다.
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

    private var config: UsageConfig { monitor.config }

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
                MenuBarStylePicker(monitor: monitor)
                Toggle("주간 소진율 함께 표시", isOn: Binding(
                    get: { config.showsMenuBarWeekly },
                    set: { monitor.config.menuBarShowsWeekly = $0 }
                ))
                Toggle("리셋까지 남은 시간 함께 표시", isOn: Binding(
                    get: { config.showsMenuBarRemaining },
                    set: { monitor.config.menuBarShowsRemaining = $0 }
                ))
                menuBarTextColor
            } header: {
                Text("메뉴바 표시")
            } footer: {
                Text("아이콘은 5시간 창 소진율에 따라 채워집니다. 소진율(%)은 아이콘 왼쪽에, 위에서 켠 주간 소진율·남은 시간은 오른쪽에 붙습니다. 둘 다 켜면 오른쪽에 글자를 줄여 위아래로 쌓습니다. 메뉴바가 좁아지면 macOS가 뒤쪽부터 잘라내므로 필요한 것만 켜는 편이 좋습니다. 표시할 값이 아직 없으면(주간 집계가 비었거나 진행 중인 창이 없으면) 그 항목은 생략됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                account
                organizationPicker
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
            } header: {
                Text("실측 사용량 (claude.ai)")
            } footer: {
                Text("앱 안의 로그인 창에서 claude.ai에 로그인하면 그 계정 전체(코드·데스크톱·웹)의 실측 소진율을 가져옵니다. 세션은 앱의 웹 저장소에 남아 다시 켜도 유지되고, 만료되면(대략 4주) 다시 로그인하라고 알립니다. Claude 데스크톱 앱은 필요하지 않고, 키체인 접근 허용 창도 뜨지 않습니다.")
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

    /// 메뉴바 글자 색. 자주 쓰는 색과 색상 선택기를 한 줄에 둔다.
    ///
    /// 라벨을 직접 그리기 때문에 색을 고를 수 있다. 링·막대의 사용량 색은 경고 단계를
    /// 나타내는 값이라 이 설정을 따르지 않는다.
    private var menuBarTextColor: some View {
        let current = config.menuBarTextColor
        return LabeledContent("글자 색") {
            HStack(spacing: 6) {
                ForEach(Self.textColorPresets, id: \.hex) { preset in
                    let isSelected = current.menuBarHexString
                        .caseInsensitiveCompare(preset.hex) == .orderedSame
                    Button {
                        monitor.config.menuBarTextColorHex = preset.hex
                    } label: {
                        Circle()
                            .fill(Color(nsColor: NSColor(menuBarHex: preset.hex) ?? .black))
                            .frame(width: 15, height: 15)
                            .overlay(Circle().strokeBorder(
                                isSelected ? Color.accentColor : Color.secondary.opacity(0.4),
                                lineWidth: isSelected ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                }
                // 프리셋에 없는 색은 선택기로 직접 고른다.
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: current) },
                    set: { monitor.config.menuBarTextColorHex = NSColor($0).menuBarHexString }
                ), supportsOpacity: false)
                .labelsHidden()
            }
        }
    }

    /// 메뉴바에서 읽히는 색만 골라 둔다 — 무채색과 패널 팔레트(테라코타·청록).
    private static let textColorPresets: [(name: String, hex: String)] = [
        ("검정 (기본)", "#000000"),
        ("흰색", "#FFFFFF"),
        ("연회색", "#B4B4B8"),
        ("테라코타", "#D97757"),
        ("청록", "#5C999E"),
        ("주황", "#FF9F0A"),
    ]

    /// 연동 계정 — 로그인 여부와 계정 표시, 계정 바꾸기.
    @ViewBuilder private var account: some View {
        if let server = monitor.serverAccount {
            LabeledContent("연동 계정") {
                HStack(spacing: 6) {
                    Text(server.email ?? server.organizationName ?? "로그인됨")
                        .lineLimit(1)
                    Button("다른 계정") {
                        monitor.signOut()
                        monitor.signIn()
                    }
                    .buttonStyle(.link)
                }
            }
            accountMismatch
        } else {
            LabeledContent("연동 계정") {
                HStack(spacing: 6) {
                    Text("로그인하지 않음").foregroundStyle(.secondary)
                    Button("Claude 로그인") { monitor.signIn() }
                }
            }
        }
    }

    /// 로컬 추정과 실측이 서로 다른 계정을 가리킬 때의 경고.
    ///
    /// 로컬 추정은 늘 Claude Code 로그(~/.claude/projects)를 세므로, 연동 계정과 Claude Code
    /// 계정이 다르면 패널의 두 숫자가 다른 계정 것이 된다.
    @ViewBuilder private var accountMismatch: some View {
        switch monitor.accountMatch {
        case .differentAccount, .differentOrganization:
            let local = monitor.localAccount
            let name = local?.email ?? local?.organizationName ?? "다른 계정"
            Label("로컬 추정은 Claude Code 계정(\(name))의 로그입니다. 위 실측과 다른 계정이라 두 숫자를 같이 비교하면 안 됩니다.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .same, .unknown:
            EmptyView()
        }
    }

    /// 조직 선택. 한 로그인이 여러 조직에 속하면 어느 조직을 보느냐로 숫자가 달라진다.
    @ViewBuilder private var organizationPicker: some View {
        if monitor.availableOrganizations.count > 1 {
            Picker("조직", selection: Binding(
                get: { config.organizationUuid ?? "" },
                set: { monitor.config.organizationUuid = $0.isEmpty ? nil : $0 }
            )) {
                Text("자동 (사용량 한도가 있는 조직)").tag("")
                ForEach(monitor.availableOrganizations, id: \.uuid) { organization in
                    Text(organization.name ?? organization.uuid).tag(organization.uuid)
                }
            }
        }
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
                if let notice = server.fallbackNotice {
                    Label(notice, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
            Text("불러오는 중…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 메뉴바 디자인을 실제 렌더 결과로 골라 보는 카드 목록.
///
/// 미리보기는 지금 메뉴바에 뜨는 값을 그대로 쓴다. 아직 데이터가 없으면 링이 모두 비어
/// 디자인을 견줄 수 없으므로 예시 값으로 채운다.
private struct MenuBarStylePicker: View {
    let monitor: UsageMonitor

    private static let columns = [GridItem(.flexible(), spacing: 8),
                                  GridItem(.flexible(), spacing: 8)]

    private var selected: MenuBarStyle { monitor.config.menuBarDesign }
    private var usesSample: Bool { !monitor.hasSessionData }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Self.columns, spacing: 8) {
                ForEach(MenuBarStyle.allCases) { style in
                    card(style)
                }
            }
            Text(selected.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if usesSample {
                Label("아직 사용량 데이터가 없어 예시 값(62% · 창 45% 경과)으로 그렸습니다.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func card(_ style: MenuBarStyle) -> some View {
        let isSelected = style == selected
        return Button {
            monitor.config.menuBarStyle = style.rawValue
        } label: {
            VStack(spacing: 7) {
                // 메뉴바 라벨을 그대로 그린 이미지다. 배경도 메뉴바처럼 외관을 따라가는
                // 색으로 둬 글자 색을 바꿨을 때 실제로 읽히는지 볼 수 있게 한다.
                MenuBarContent(spec: spec(style))
                    .frame(height: 24)
                    .padding(.horizontal, 8)
                    .background(Capsule(style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(Capsule(style: .continuous).strokeBorder(.quaternary))
                Text(style.title)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(style.detail)
    }

    /// 이 디자인의 미리보기. 값이 있으면 지금 그대로, 없으면 예시 값으로 그린다.
    private func spec(_ style: MenuBarStyle) -> MenuBarLabelSpec {
        guard usesSample else { return monitor.menuBarLabelSpec(for: style) }
        var trailing: [String] = []
        if monitor.config.showsMenuBarWeekly { trailing.append("주 39%") }
        if monitor.config.showsMenuBarRemaining { trailing.append("2h 14m") }
        return MenuBarLabelSpec(style: style,
                                model: .sample,
                                leading: style.drawsPercentInIcon ? "" : "62%",
                                trailing: trailing,
                                textColor: monitor.config.menuBarTextColor)
    }
}

