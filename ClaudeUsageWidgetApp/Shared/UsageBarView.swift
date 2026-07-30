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

/// 한도 소진율을 보여주는 한 줄. 위젯과 메뉴바가 같은 모양을 쓴다.
struct UsageBar: View {
    let title: String
    /// 0...1 을 넘어갈 수 있다(추정 한도를 초과한 경우).
    let ratio: Double
    let detail: String
    var trailing: String?

    private var severity: UsageSeverity { UsageSeverity(ratio: ratio) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
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

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.quaternary)
                    Capsule(style: .continuous)
                        .fill(severity.tint)
                        // 한도를 넘겨도 바가 넘치지 않게 자른다.
                        .frame(width: geometry.size.width * min(max(ratio, 0), 1))
                }
            }
            .frame(height: 5)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
