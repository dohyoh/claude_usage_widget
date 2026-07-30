//
//  UsageBarView.swift
//  Shared between ClaudeUsageWidgetApp (menu bar) and ClaudeUsageWidgetExtension.
//

import SwiftUI

/// 진행 바 색을 정하는 3단계.
enum UsageSeverity: Sendable {
    case normal, warning, critical

    init(ratio: Double) {
        switch ratio {
        case ..<0.7: self = .normal
        case ..<0.9: self = .warning
        default: self = .critical
        }
    }

    var tint: Color {
        switch self {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

extension Color {
    /// 시간 축(경과 시간 바·리셋 표시)의 색.
    ///
    /// 사용량 바는 accent(테라코타) → 주황 → 빨강으로 «달아오르는» 한 계열을 쓴다. 시간은
    /// 성격이 다른 축이라 그 계열에 섞이면 두 바를 구별할 수 없고, 그렇다고 팔레트를
    /// 벗어나면 위젯이 튄다. 그래서 accent의 보색 쪽(청록)으로 빼되 채도·명도는 accent와
    /// 비슷하게 낮춰 둔다. 경고 단계는 없다 — 시간이 흐르는 것 자체는 나쁜 상태가 아니다.
    static let usageTimeTint = Color(red: 0.36, green: 0.60, blue: 0.62)
}

/// 한도 소진율을 보여주는 한 줄. 위젯과 메뉴바가 같은 모양을 쓴다.
struct UsageBar: View {
    let title: String
    /// 0...1 을 넘어갈 수 있다(추정 한도를 초과한 경우).
    let ratio: Double
    let detail: String
    var trailing: String?
    /// 창 전체 길이에서 지금까지 지나간 비율(0...1). nil이면 시간 바를 그리지 않는다
    /// — 롤링 집계처럼 리셋 시점 자체가 없는 경우.
    var elapsedRatio: Double?
    /// 작은 위젯처럼 높이가 모자란 자리에서 줄 간격과 바 두께를 줄인다.
    var compact: Bool = false

    private var severity: UsageSeverity { UsageSeverity(ratio: ratio) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                if let trailing {
                    Text(trailing)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            track(fill: severity.tint, ratio: ratio)
                .frame(height: compact ? 4 : 5)

            if let elapsedRatio {
                // 사용량과 같이 왼쪽에서 자라게 둔다. 두 바의 길이를 그대로 견줄 수 있어
                // — 사용량 바가 더 길면 시간보다 빨리 태우는 중이다 — 소진 속도가 한눈에
                // 보인다. 구분은 색과 두께가 맡는다.
                track(fill: .usageTimeTint, ratio: elapsedRatio)
                    .frame(height: 3)
            }

            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func track(fill: Color, ratio: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.quaternary)
                Capsule(style: .continuous)
                    .fill(fill)
                    // 한도를 넘겨도 바가 넘치지 않게 자른다.
                    .frame(width: geometry.size.width * min(max(ratio, 0), 1))
            }
        }
    }
}

/// 시간 바가 무슨 색인지 한 번 알려주는 작은 범례. 자리가 있는 곳에서만 쓴다.
struct UsageElapsedLegend: View {
    var body: some View {
        HStack(spacing: 3) {
            Capsule(style: .continuous)
                .fill(Color.usageTimeTint)
                .frame(width: 10, height: 3)
            Text("창에서 지난 시간")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}
