//
//  MenuBarStyle.swift
//  Shared between ClaudeUsageWidgetApp (menu bar) and ClaudeUsageWidgetExtension.
//
//  메뉴바 아이콘 디자인 목록.
//
//  설정 파일(UsageConfig)에 문자열로 저장되고, 그 파일은 위젯 타깃에서도 디코딩하므로
//  타입 자체는 Shared 에 둔다. 실제로 그리는 쪽은 앱 타깃의 MenuBarIcon 이다.
//

import Foundation

/// 메뉴바에 사용량을 어떤 모양으로 그릴지.
enum MenuBarStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 이중 링 — 바깥은 사용량, 안쪽 얇은 링은 창에서 지난 시간.
    case ringDual
    /// 단일 링 — 사용량만.
    case ring
    /// 링 안에 숫자를 넣어 폭을 가장 아낀다.
    case ringInline
    /// 얇은 이중 막대 — 위는 사용량, 아래는 지난 시간.
    case bars
    /// SF Symbol 게이지. v1 의 모양.
    case gauge
    /// 아이콘 없이 숫자만.
    case text

    static let `default`: MenuBarStyle = .ringDual

    var id: String { rawValue }

    /// 설정 창의 카드에 붙는 짧은 이름.
    var title: String {
        switch self {
        case .ringDual: return "이중 링"
        case .ring: return "링"
        case .ringInline: return "링 + 내부 숫자"
        case .bars: return "막대"
        case .gauge: return "게이지"
        case .text: return "숫자만"
        }
    }

    /// 고른 디자인 하나에 대해서만 보여주는 설명.
    var detail: String {
        switch self {
        case .ringDual:
            return "바깥 링은 5시간 창 소진율, 안쪽 얇은 링은 그 창에서 지난 시간입니다. 사용량 링이 시간 링보다 앞서 있으면 시간보다 빨리 한도를 태우는 중입니다."
        case .ring:
            return "링 하나로 5시간 창 소진율만 채웁니다. 남은 시간은 오른쪽 숫자(«리셋까지 남은 시간 함께 표시»를 켜면)로 봅니다."
        case .ringInline:
            return "숫자를 링 안에 넣어 메뉴바 폭을 가장 적게 씁니다. 소진율은 링과 숫자 둘 다로 보이고, 주간·남은 시간을 켜면 그것만 오른쪽에 붙습니다."
        case .bars:
            return "패널의 진행 바와 같은 모양입니다. 위 막대는 사용량, 아래 얇은 막대는 창에서 지난 시간입니다."
        case .gauge:
            return "시스템 게이지 아이콘 + 숫자. 메뉴바 색을 그대로 따라가는 단색 표시입니다."
        case .text:
            return "아이콘 없이 숫자만 둡니다. 메뉴바가 가장 좁아집니다."
        }
    }

    /// 숫자를 아이콘 안에 그리는 디자인인지.
    ///
    /// 그렇다면 아이콘 오른쪽 텍스트에서 5시간 창 %를 빼야 같은 값이 두 번 나오지 않는다.
    var drawsPercentInIcon: Bool { self == .ringInline }

    /// 창에서 지난 시간을 아이콘에 함께 그리는지 — 설정 설명에만 쓴다.
    var showsElapsedTime: Bool { self == .ringDual || self == .bars }
}
