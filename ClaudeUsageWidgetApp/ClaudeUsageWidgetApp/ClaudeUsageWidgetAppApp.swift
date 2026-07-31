//
//  ClaudeUsageWidgetAppApp.swift
//  ClaudeUsageWidgetApp
//
//  Created by 송동훈 on 7/29/26.
//

import SwiftUI

@main
struct ClaudeUsageWidgetAppApp: App {
    @State private var monitor = UsageMonitor()

    var body: some Scene {
        // 위젯 타임라인은 수 분 단위로만 갱신되므로, 초 단위 실시간 표시는 메뉴바가 담당한다.
        MenuBarExtra {
            UsagePanel(monitor: monitor)
        } label: {
            // 아이콘·글자 모두 설정에서 고른 디자인이 정한다. label 은 snapshot 을 읽으므로
            // 5초 갱신마다 다시 그려진다.
            MenuBarContent(spec: monitor.menuBarLabelSpec)
        }
        .menuBarExtraStyle(.window)

        // Settings 씬 대신 일반 Window를 쓴다. LSUIElement 앱에서는 SettingsLink 가
        // 창을 열어도 앞으로 나오지 않아 "눌러도 반응 없음"으로 보인다.
        Window("Claude 사용량 설정", id: SettingsWindow.id) {
            UsageSettingsView(monitor: monitor)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
