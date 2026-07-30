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
            HStack(spacing: 3) {
                Image(systemName: monitor.hasSessionData
                      ? "gauge.with.dots.needle.50percent"
                      : "gauge.with.dots.needle.0percent")
                Text(monitor.menuBarLabel)
            }
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
