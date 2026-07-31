//
//  MenuBarIcon.swift
//  ClaudeUsageWidgetApp
//
//  메뉴바 라벨을 아이콘부터 글자까지 한 장의 NSImage 로 직접 그린다.
//
//  MenuBarExtra 의 label 은 SwiftUI 뷰를 그대로 그리지 않는다. 내부적으로 NSStatusItem 의
//  image 와 title 로만 뽑아 쓰기 때문에 실측해 보면 이렇게 동작한다.
//
//    - Shape·Canvas·GeometryReader 는 아무것도 그려지지 않는다.
//    - Text 를 Image 앞에 두어도 항상 «이미지 → 글자» 순서로 나온다(선언 순서 무시).
//    - VStack 으로 Text 를 두 줄 쌓으면 그 블록이 통째로 사라진다.
//    - Text 에 준 .foregroundStyle 은 무시된다.
//
//  그래서 «사용량은 왼쪽, 주간·남은 시간은 오른쪽», «두 줄 축소 표기», «글자 색 지정»을
//  하려면 라벨 전체를 직접 그려 Image(nsImage:) 하나로 넘기는 수밖에 없다. 값이 바뀔 때
//  (5초 갱신마다) 다시 그리지만 벡터 몇 개와 짧은 문자열이라 비용은 무시할 수준이다.
//

import AppKit
import SwiftUI

/// 아이콘 하나를 그리는 데 필요한 값 전부.
struct MenuBarIconModel {
    /// 5시간 창 소진율(0...1+). 1을 넘으면 링·막대는 꽉 찬 상태로 자른다.
    var usage: Double
    /// 그 창에서 지난 시간 비율(0...1). 진행 중인 창이 없으면 nil.
    var elapsed: Double?
    /// 색 단계 — 패널의 진행 바와 같은 기준.
    var severity: UsageSeverity
    /// 아이콘 안에 넣을 소진율(%). 표시할 값이 없으면 nil.
    var percent: Int?

    /// 아직 데이터가 없을 때 설정 창에서 디자인을 견주기 위한 예시 값.
    static let sample = MenuBarIconModel(usage: 0.62, elapsed: 0.45, severity: .normal, percent: 62)
}

/// 메뉴바 라벨 한 개의 구성.
struct MenuBarLabelSpec {
    var style: MenuBarStyle
    var model: MenuBarIconModel
    /// 아이콘 왼쪽에 둘 사용량 텍스트. 비어 있으면 생략한다.
    var leading: String = ""
    /// 아이콘 오른쪽에 둘 줄. 두 개면 글자를 줄여 위아래로 쌓는다.
    var trailing: [String] = []
    /// 글자 색. 설정에서 고른다.
    var textColor: NSColor = .black
}

enum MenuBarIcon {
    /// 링 지름.
    ///
    /// 메뉴바가 24pt 이미지까지 자르지 않고 받는 것을 확인했지만, 표준 메뉴바(24pt)에서
    /// 위아래 여백이 남도록 20pt 로 둔다.
    private static let ringSide: CGFloat = 20
    private static let barsSize = NSSize(width: 22, height: 11)
    /// 요소(글자·아이콘) 사이 간격.
    private static let gap: CGFloat = 3
    /// 라벨 전체 높이 상한.
    private static let maxHeight: CGFloat = 22

    /// 라벨 한 장. 아이콘·왼쪽 사용량·오른쪽 부가 정보를 한 이미지에 담는다.
    static func label(for spec: MenuBarLabelSpec) -> NSImage {
        let color = spec.textColor
        // 오른쪽에 붙일 것이 둘이면 글자를 줄여 위아래로 쌓는다. 하나면 그대로 한 줄.
        let stacks = spec.trailing.count > 1
        let trailingFont = stacks ? stackedFont : primaryFont
        let leading = spec.leading.isEmpty
            ? nil : attributed(spec.leading, font: primaryFont, color: color)
        let trailing = spec.trailing.map { attributed($0, font: trailingFont, color: color) }

        let icon = iconSize(for: spec)
        let leadingSize = leading?.size() ?? .zero
        let trailingWidth = trailing.map { $0.size().width }.max() ?? 0
        let lineHeight = ceil(trailingFont.ascender - trailingFont.descender)
        let trailingHeight = lineHeight * CGFloat(trailing.count)

        var width = leadingSize.width + icon.width + trailingWidth
        // 실제로 존재하는 요소 사이에만 간격을 넣는다.
        if leadingSize.width > 0, icon.width > 0 { width += gap }
        if trailingWidth > 0, leadingSize.width + icon.width > 0 { width += gap }
        let height = min(maxHeight, max(icon.height, max(leadingSize.height, trailingHeight)))

        let image = NSImage(size: NSSize(width: ceil(width), height: ceil(height)),
                            flipped: false) { rect in
            var x = rect.minX
            if let leading {
                leading.draw(at: NSPoint(x: x, y: rect.midY - leadingSize.height / 2))
                x += leadingSize.width + gap
            }
            if icon.width > 0 {
                drawIcon(spec, in: NSRect(x: x, y: rect.midY - icon.height / 2,
                                          width: icon.width, height: icon.height),
                         textColor: color)
                x += icon.width + gap
            }
            // 첫 줄이 위 — 한 줄로 이어 붙일 때의 순서(주간 → 남은 시간)를 위아래로 옮긴 것이다.
            var lineTop = rect.midY + trailingHeight / 2
            for line in trailing {
                let size = line.size()
                line.draw(at: NSPoint(x: x, y: lineTop - lineHeight + (lineHeight - size.height) / 2))
                lineTop -= lineHeight
            }
            return true
        }
        // 색(주황·빨강·지정색)을 살려야 하므로 템플릿으로 두지 않는다.
        image.isTemplate = false
        // 글자를 이미지로 그리면 VoiceOver 가 읽을 것이 없어지므로 설명을 붙인다.
        image.accessibilityDescription = ([spec.leading] + spec.trailing)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return image
    }

    // MARK: - 아이콘

    /// 이 디자인의 아이콘 크기. 아이콘이 없는 디자인이면 `.zero`.
    private static func iconSize(for spec: MenuBarLabelSpec) -> NSSize {
        switch spec.style {
        case .ringDual, .ring, .ringInline:
            return NSSize(width: ringSide, height: ringSide)
        case .bars:
            return barsSize
        case .gauge:
            return gaugeSymbol(for: spec.model, color: .labelColor)?.size ?? NSSize(width: 18, height: 16)
        case .text:
            return .zero
        }
    }

    private static func drawIcon(_ spec: MenuBarLabelSpec, in rect: NSRect, textColor: NSColor) {
        switch spec.style {
        case .ringDual, .ring, .ringInline:
            drawRing(spec.model, style: spec.style, in: rect, textColor: textColor)
        case .bars:
            drawBars(spec.model, in: rect)
        case .gauge:
            gaugeSymbol(for: spec.model, color: textColor)?.draw(in: rect)
        case .text:
            break
        }
    }

    private static func drawRing(_ model: MenuBarIconModel, style: MenuBarStyle,
                                 in rect: NSRect, textColor: NSColor) {
        // 숫자를 안에 넣는 변형은 선을 얇게 해 글자 자리를 넓힌다.
        let lineWidth: CGFloat = style == .ringInline ? 2.2 : 2.8
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - lineWidth / 2 - 0.5

        strokeArc(center: center, radius: radius, lineWidth: lineWidth,
                  ratio: 1, color: trackColor)
        strokeArc(center: center, radius: radius, lineWidth: lineWidth,
                  ratio: model.usage, color: tint(model.severity))

        if style == .ringDual, let elapsed = model.elapsed {
            // 바깥 링과 겹치지 않게 선 두께 절반씩 + 여백 1pt 만큼 안으로 들인다.
            let innerWidth: CGFloat = 1.8
            let innerRadius = radius - lineWidth / 2 - 1.0 - innerWidth / 2
            strokeArc(center: center, radius: innerRadius, lineWidth: innerWidth,
                      ratio: 1, color: faintTrackColor)
            strokeArc(center: center, radius: innerRadius, lineWidth: innerWidth,
                      ratio: elapsed, color: timeTint)
        }

        if style == .ringInline {
            drawInlineNumber(model, in: rect, color: textColor)
        }
    }

    /// 링 안쪽의 숫자. 세 자리가 되면 글자를 줄여 링을 넘지 않게 한다.
    private static func drawInlineNumber(_ model: MenuBarIconModel, in rect: NSRect, color: NSColor) {
        guard let percent = model.percent else {
            draw("–", centeredIn: rect, fontSize: 8, weight: .semibold,
                 color: color.withAlphaComponent(0.5))
            return
        }
        let text = "\(min(percent, 999))"
        draw(text, centeredIn: rect, fontSize: text.count >= 3 ? 8 : 9.5,
             weight: .semibold, color: color)
    }

    private static func drawBars(_ model: MenuBarIconModel, in rect: NSRect) {
        let usageHeight: CGFloat = 5
        let timeHeight: CGFloat = 3
        let gapHeight: CGFloat = 2.5
        let stack = model.elapsed == nil ? usageHeight : usageHeight + gapHeight + timeHeight
        var y = rect.midY + stack / 2 - usageHeight

        fillCapsule(x: rect.minX, y: y, width: rect.width, height: usageHeight,
                    ratio: 1, color: trackColor)
        fillCapsule(x: rect.minX, y: y, width: rect.width, height: usageHeight,
                    ratio: model.usage, color: tint(model.severity))

        if let elapsed = model.elapsed {
            y -= gapHeight + timeHeight
            fillCapsule(x: rect.minX, y: y, width: rect.width, height: timeHeight,
                        ratio: 1, color: faintTrackColor)
            fillCapsule(x: rect.minX, y: y, width: rect.width, height: timeHeight,
                        ratio: elapsed, color: timeTint)
        }
    }

    /// v1 의 게이지 심볼. 단색이라 글자 색을 그대로 따른다.
    private static func gaugeSymbol(for model: MenuBarIconModel, color: NSColor) -> NSImage? {
        let name = model.percent == nil
            ? "gauge.with.dots.needle.0percent"
            : "gauge.with.dots.needle.50percent"
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    // MARK: - 그리기 도구

    /// 12시에서 시작해 시계 방향으로 `ratio` 만큼 도는 호. 1 이상이면 원 전체.
    private static func strokeArc(center: CGPoint, radius: CGFloat, lineWidth: CGFloat,
                                  ratio: Double, color: NSColor) {
        let clamped = min(max(ratio, 0), 1)
        guard clamped > 0.001, radius > 0 else { return }
        let path = NSBezierPath()
        if clamped >= 1 {
            path.appendOval(in: NSRect(x: center.x - radius, y: center.y - radius,
                                       width: radius * 2, height: radius * 2))
        } else {
            path.appendArc(withCenter: center, radius: radius,
                           startAngle: 90, endAngle: 90 - 360 * clamped, clockwise: true)
        }
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    private static func fillCapsule(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                                    ratio: Double, color: NSColor) {
        let filled = width * min(max(ratio, 0), 1)
        guard filled > 0.3 else { return }
        let radius = min(height / 2, filled / 2)
        let path = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: filled, height: height),
                                xRadius: radius, yRadius: radius)
        color.setFill()
        path.fill()
    }

    private static func draw(_ text: String, centeredIn rect: NSRect, fontSize: CGFloat,
                             weight: NSFont.Weight, color: NSColor) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: color,
        ])
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: rect.midX - size.width / 2,
                                    y: rect.midY - size.height / 2))
    }

    private static func attributed(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    // MARK: - 글꼴

    /// 한 줄로 둘 때의 글꼴. 메뉴바 기본 크기를 따르고 숫자 폭을 고정해 값이 바뀌어도 흔들리지 않게 한다.
    private static var primaryFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
                                         weight: .regular)
    }

    /// 두 줄로 쌓을 때의 글꼴. 작아진 만큼 굵기를 한 단계 올려 읽히게 한다.
    private static var stackedFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
    }

    // MARK: - 색

    /// 사용량 색. 패널 진행 바와 같은 계열(테라코타 → 주황 → 빨강)을 쓴다.
    private static func tint(_ severity: UsageSeverity) -> NSColor {
        switch severity {
        case .normal: return NSColor(named: "AccentColor") ?? .controlAccentColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    /// 시간 축 색. `Color.usageTimeTint` 와 같은 값을 쓴다.
    private static var timeTint: NSColor { NSColor(Color.usageTimeTint) }

    /// 링·막대의 빈 부분.
    ///
    /// 메뉴바는 시스템 외관을 따르므로 앱의 유효 외관으로 밝기를 고른다. 동적 색
    /// (`tertiaryLabelColor`)을 쓰면 NSImage 가 어느 외관에서 래스터화되는지에 따라
    /// 트랙이 배경에 묻힐 수 있어, 양쪽에서 보이는 반투명 회색으로 고정한다.
    private static var trackColor: NSColor {
        isDarkAppearance ? NSColor(white: 1, alpha: 0.30) : NSColor(white: 0, alpha: 0.20)
    }

    /// 안쪽 시간 링/막대의 트랙 — 바깥 트랙보다 흐리게 둬 링이 두 겹으로 보이지 않게 한다.
    private static var faintTrackColor: NSColor {
        isDarkAppearance ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.11)
    }

    private static var isDarkAppearance: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// 메뉴바 라벨. MenuBarExtra 와 설정 창의 미리보기가 같은 이미지를 쓴다.
struct MenuBarContent: View {
    let spec: MenuBarLabelSpec

    var body: some View {
        Image(nsImage: MenuBarIcon.label(for: spec))
            .renderingMode(.original)
    }
}

// MARK: - 설정에 저장하는 글자 색

extension UsageConfig {
    /// 메뉴바 글자 색. 고르지 않았거나 값이 깨졌으면 검정.
    var menuBarTextColor: NSColor {
        menuBarTextColorHex.flatMap { NSColor(menuBarHex: $0) } ?? .black
    }
}

extension NSColor {
    /// `#RRGGBB` 문자열에서 만든다. 형식이 어긋나면 nil.
    convenience init?(menuBarHex hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }

    /// 설정 파일에 넣을 `#RRGGBB` 문자열.
    var menuBarHexString: String {
        let srgb = usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X",
                      Int((srgb.redComponent * 255).rounded()),
                      Int((srgb.greenComponent * 255).rounded()),
                      Int((srgb.blueComponent * 255).rounded()))
    }
}
