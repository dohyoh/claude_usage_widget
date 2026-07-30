#!/usr/bin/env swift
//
//  make-images.swift
//  배포용 이미지 일괄 생성 — 앱 아이콘 · README 히어로 · GitHub 소셜 프리뷰 · DMG 배경.
//
//  톤 토큰(색·형태·모티프)을 이 파일 한 곳에만 두고 모든 산출물을 같은 소스에서
//  뽑는다. 색을 하나 바꾸면 아이콘·README·DMG 가 함께 따라온다.
//
//  사용법:  ./assets/make-images.swift        (저장소 루트에서)
//

import AppKit

_ = NSApplication.shared   // 폰트/그래픽스 초기화

// MARK: - 톤 토큰 ────────────────────────────────────────────────────────────

/// 앱 UI 와 같은 계열. coral 은 AccentColor(진행 바 normal), amber/red 는 경고 단계.
enum T {
    static let coralLight = hex(0xE89870)
    static let coral      = hex(0xD97757)   // Claude 계열 시그니처 — AccentColor 와 동일
    static let coralDeep  = hex(0xB8512C)

    static let cream      = hex(0xFBF8F3)
    static let paper      = hex(0xF2EBE1)

    static let ink        = hex(0x171614)   // 히어로 배경
    static let inkCard    = hex(0x232120)   // 위젯 카드
    static let inkRaised  = hex(0x2C2926)   // 메뉴바 칩
    static let inkLine    = hex(0x3A3632)

    static let textDim    = hex(0xA9A29A)
    static let textFaint  = hex(0x6E675E)
    static let inkOnPaper = hex(0x2A2724)

    static let amber      = hex(0xE0A33E)

    /// 아이콘 링이 보여주는 소진율. README 샘플(5시간 62%)과 같은 값.
    static let ringRatio: CGFloat = 0.62

    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255,
                alpha: a)
    }
}

func fade(_ c: CGColor, _ a: CGFloat) -> CGColor { c.copy(alpha: a)! }

// MARK: - 캔버스 ─────────────────────────────────────────────────────────────

/// 포인트 단위로 그리고 scale 배 픽셀로 굽는다. 텍스트·벡터는 scale 에서 그대로 선명하다.
final class Canvas {
    let rep: NSBitmapImageRep
    let cg: CGContext
    let w: CGFloat
    let h: CGFloat

    init(_ width: CGFloat, _ height: CGFloat, scale: CGFloat = 1) {
        w = width; h = height
        rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int((width * scale).rounded()),
                               pixelsHigh: Int((height * scale).rounded()),
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
        // rep.size 를 픽셀과 같게 둬야 컨텍스트가 1:1 로 열린다. 여기에 point 크기를
        // 넣으면 AppKit 이 CTM 을 한 번 더 스케일해 아래 scaleBy 와 겹쳐 배로 커진다.
        rep.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        let gc = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        cg = gc.cgContext
        cg.scaleBy(x: scale, y: scale)
        cg.setAllowsAntialiasing(true)
        cg.interpolationQuality = .high
    }

    /// 위에서 잰 y 를 아래 원점 좌표로. 레이아웃을 디자인 감각(위→아래)으로 적기 위해.
    func top(_ y: CGFloat) -> CGFloat { h - y }

    func finish() -> CGImage {
        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }
}

// MARK: - 형태 ───────────────────────────────────────────────────────────────

/// Apple 아이콘의 연속 곡률 사각형(슈퍼타원). 원형 라운드보다 옆면이 곧아 실제 아이콘과 붙는다.
///
/// 각도(t)로 균등 샘플하면 축을 지나는 네 지점에서 표본이 크게 벌어져 테두리를 그을 때
/// 평평한 흠이 보인다. 그래서 한 사분면을 45° 에서 잘라 완만한 쪽은 x, 급한 쪽은 y 로
/// 훑고 나머지 사분면은 미러링한다.
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let a = r.width / 2, b = r.height / 2
    let cx = r.midX, cy = r.midY
    let m = 160
    let split = pow(0.5, 1 / n)                 // 45° 지점의 정규화 좌표

    var quad: [(CGFloat, CGFloat)] = []         // 12시 → 3시
    for i in 0...m {                            // 완만한 구간: x 균등
        let u = split * CGFloat(i) / CGFloat(m)
        quad.append((u, pow(max(0, 1 - pow(u, n)), 1 / n)))
    }
    for i in 0...m {                            // 급한 구간: y 균등
        let v = split * (1 - CGFloat(i) / CGFloat(m))
        quad.append((pow(max(0, 1 - pow(v, n)), 1 / n), v))
    }

    var pts: [CGPoint] = []
    pts += quad.map { CGPoint(x: cx + $0.0 * a, y: cy + $0.1 * b) }              // 우상
    pts += quad.reversed().map { CGPoint(x: cx + $0.0 * a, y: cy - $0.1 * b) }   // 우하
    pts += quad.map { CGPoint(x: cx - $0.0 * a, y: cy - $0.1 * b) }              // 좌하
    pts += quad.reversed().map { CGPoint(x: cx - $0.0 * a, y: cy + $0.1 * b) }   // 좌상

    // 사분면 이음새에서 같은 점이 두 번 들어간다. 길이 0 인 선분은 반투명 테두리를
    // 두 번 겹쳐 칠해 밝은 점으로 보이므로 걸러낸다.
    let p = CGMutablePath()
    p.move(to: pts[0])
    var last = pts[0]
    for pt in pts.dropFirst() where hypot(pt.x - last.x, pt.y - last.y) > 0.01 {
        p.addLine(to: pt)
        last = pt
    }
    p.closeSubpath()
    return p
}

/// 4방향 반짝임(SF Symbol `sparkle` 계열) — 앱 헤더가 쓰는 모티프.
func sparkle(center c: CGPoint, radius r: CGFloat, pinch: CGFloat = 0.13) -> CGPath {
    let tips = [CGPoint(x: 0, y: r), CGPoint(x: r, y: 0), CGPoint(x: 0, y: -r), CGPoint(x: -r, y: 0)]
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x + tips[0].x, y: c.y + tips[0].y))
    for i in 0..<4 {
        let from = tips[i], to = tips[(i + 1) % 4]
        p.addQuadCurve(to: CGPoint(x: c.x + to.x, y: c.y + to.y),
                       control: CGPoint(x: c.x + (from.x + to.x) * pinch,
                                        y: c.y + (from.y + to.y) * pinch))
    }
    p.closeSubpath()
    return p
}

extension CGContext {
    func fill(_ path: CGPath, _ color: CGColor) {
        saveGState(); addPath(path); setFillColor(color); fillPath(); restoreGState()
    }

    func stroke(_ path: CGPath, _ color: CGColor, _ width: CGFloat, cap: CGLineCap = .round) {
        saveGState()
        addPath(path); setStrokeColor(color); setLineWidth(width); setLineCap(cap)
        setLineJoin(.round)
        strokePath(); restoreGState()
    }

    /// 두 점을 잇는 축 방향 그라디언트.
    func gradient(_ path: CGPath, from: CGPoint, to: CGPoint, _ colors: [CGColor]) {
        saveGState()
        addPath(path); clip()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: colors as CFArray, locations: nil)!
        drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        restoreGState()
    }

    func glow(at c: CGPoint, radius: CGFloat, _ color: CGColor) {
        saveGState()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [color, fade(color, 0)] as CFArray, locations: [0, 1])!
        drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
        restoreGState()
    }

    /// 12시에서 시계 방향으로 도는 진행 호. 사용량 바와 같은 둥근 끝.
    func arc(center c: CGPoint, radius: CGFloat, ratio: CGFloat, width: CGFloat, _ color: CGColor) {
        guard ratio > 0 else { return }
        let p = CGMutablePath()
        p.addArc(center: c, radius: radius,
                 startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * min(ratio, 1),
                 clockwise: true)
        stroke(p, color, width)
    }

    func capsule(_ r: CGRect, _ color: CGColor) {
        fill(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil), color)
    }
}

// MARK: - 텍스트 ─────────────────────────────────────────────────────────────

enum Align { case left, center, right }

func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, mono: Bool = false) -> NSFont {
    mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
         : NSFont.systemFont(ofSize: size, weight: weight)
}

/// baseline 기준으로 그린다. align 은 x 를 기준선으로 삼는다.
@discardableResult
func text(_ s: String, _ f: NSFont, _ color: CGColor, x: CGFloat, y: CGFloat,
          align: Align = .left, tracking: CGFloat = 0) -> CGFloat {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: f,
        .foregroundColor: NSColor(cgColor: color)!,
        .kern: tracking,
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    let width = str.size().width
    let ox: CGFloat = align == .left ? x : (align == .center ? x - width / 2 : x - width)
    str.draw(at: NSPoint(x: ox, y: y))
    return width
}

func textWidth(_ s: String, _ f: NSFont, tracking: CGFloat = 0) -> CGFloat {
    NSAttributedString(string: s, attributes: [.font: f, .kern: tracking]).size().width
}

// MARK: - 아이콘 ─────────────────────────────────────────────────────────────

/// 앱 아이콘 한 장. 1024 캔버스 안에 824 스퀘어클 + 그림자(macOS 규격).
///
/// 작은 크기(≤32px)는 반짝임을 빼고 링을 굵게 그린다 — 축소만 하면 메뉴바 크기에서
/// 두 요소가 서로 뭉개져 무엇인지 읽히지 않는다.
func renderIcon(px: Int) -> CGImage {
    let simplified = px <= 32
    let ss: CGFloat = px <= 256 ? 4 : 2          // 슈퍼샘플 후 축소 → 얇은 선이 깨끗하다
    let S: CGFloat = 1024                        // 설계 단위
    let c = Canvas(S, S, scale: CGFloat(px) * ss / S)

    let inset: CGFloat = 100                     // 824 콘텐츠 + 여백
    let body = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let shape = squircle(body)

    // 접지 그림자 — macOS 아이콘의 살짝 뜬 느낌.
    c.cg.saveGState()
    c.cg.setShadow(offset: CGSize(width: 0, height: -18), blur: 46, color: T.hex(0x000000, 0.34))
    c.cg.fill(shape, T.coral)
    c.cg.restoreGState()

    // 바탕 — 좌상 밝은 코랄에서 우하 진한 코랄로.
    c.cg.gradient(shape,
                  from: CGPoint(x: body.minX, y: body.maxY),
                  to: CGPoint(x: body.maxX, y: body.minY),
                  [T.coralLight, T.coral, T.coralDeep])

    // 위쪽 광택과 아래쪽 깊이.
    c.cg.saveGState()
    c.cg.addPath(shape); c.cg.clip()
    c.cg.glow(at: CGPoint(x: body.midX, y: body.maxY + 40), radius: body.width * 0.78, T.hex(0xFFFFFF, 0.16))
    c.cg.glow(at: CGPoint(x: body.midX, y: body.minY - 60), radius: body.width * 0.62, T.hex(0x6E2A10, 0.30))
    c.cg.restoreGState()

    // 안쪽 테두리 — 유리 같은 얇은 림.
    c.cg.stroke(shape, T.hex(0xFFFFFF, 0.18), S * 0.0045)

    // 사용량 링.
    let center = CGPoint(x: body.midX, y: body.midY)
    let ringR = body.width * (simplified ? 0.315 : 0.300)
    let ringW = body.width * (simplified ? 0.150 : 0.105)
    let track = CGMutablePath()
    track.addEllipse(in: CGRect(x: center.x - ringR, y: center.y - ringR, width: ringR * 2, height: ringR * 2))
    c.cg.stroke(track, T.hex(0x4A1C08, 0.22), ringW)
    c.cg.saveGState()
    c.cg.setShadow(offset: .zero, blur: ringW * 0.55, color: T.hex(0x4A1C08, 0.30))
    c.cg.arc(center: center, radius: ringR, ratio: T.ringRatio, width: ringW, T.cream)
    c.cg.restoreGState()

    // 가운데 반짝임 — 앱 헤더의 sparkle 과 같은 모티프.
    if !simplified {
        c.cg.fill(sparkle(center: center, radius: body.width * 0.150), T.cream)
        c.cg.fill(sparkle(center: CGPoint(x: center.x + body.width * 0.125, y: center.y + body.height * 0.112),
                          radius: body.width * 0.045), fade(T.cream, 0.92))
    }

    return downscale(c.finish(), to: px)
}

/// 슈퍼샘플한 이미지를 목표 픽셀로 줄인다.
func downscale(_ image: CGImage, to px: Int) -> CGImage {
    guard image.width != px else { return image }
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

// MARK: - 공통 조각 (히어로 · 소셜이 함께 쓴다) ───────────────────────────────

/// 아이콘 아트를 임의 크기로 그려 넣는다(캔버스 합성용).
func drawIconArt(_ cg: CGContext, in rect: CGRect) {
    let img = renderIcon(px: max(256, Int(rect.width * 3)))
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -rect.height * 0.045), blur: rect.height * 0.16,
                 color: T.hex(0x000000, 0.45))
    cg.draw(img, in: rect)
    cg.restoreGState()
}

/// 앱의 UsageBar 한 줄(제목 · 캡슐 · 남은 시간)을 그대로 옮긴 것.
func drawUsageBar(_ cg: CGContext, x: CGFloat, top: CGFloat, width: CGFloat, canvas: Canvas,
                  title: String, percent: Int, detail: String, tint: CGColor, scale: CGFloat = 1) {
    let titleFont = font(11 * scale, .regular)
    let pctFont = font(11 * scale, .medium, mono: true)
    text(title, titleFont, T.textDim, x: x, y: canvas.top(top + 11 * scale))
    text("\(percent)%", pctFont, T.textDim, x: x + width, y: canvas.top(top + 11 * scale), align: .right)

    let barTop = top + 17 * scale
    let barH = 5 * scale
    cg.capsule(CGRect(x: x, y: canvas.top(barTop + barH), width: width, height: barH), fade(T.cream, 0.14))
    cg.capsule(CGRect(x: x, y: canvas.top(barTop + barH), width: width * CGFloat(percent) / 100, height: barH), tint)

    text(detail, font(10.5 * scale, .regular), T.textFaint, x: x, y: canvas.top(barTop + barH + 14 * scale))
}

/// 알림센터 위젯(작은 크기) 카드.
func drawWidgetCard(_ cg: CGContext, rect: CGRect, canvas: Canvas, scale: CGFloat = 1) {
    let card = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.17, cornerHeight: rect.width * 0.17, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 34 * scale, color: T.hex(0x000000, 0.55))
    cg.fill(card, T.inkCard)
    cg.restoreGState()
    cg.stroke(card, fade(T.cream, 0.09), 1 * scale)

    let pad = rect.width * 0.115
    let x = rect.minX + pad
    let w = rect.width - pad * 2
    var top = canvas.h - rect.maxY + pad

    // 헤더 — sparkle + Claude
    cg.fill(sparkle(center: CGPoint(x: x + 5 * scale, y: canvas.top(top + 5 * scale)), radius: 6.5 * scale), T.coral)
    text("Claude", font(12 * scale, .semibold), T.cream, x: x + 15 * scale, y: canvas.top(top + 10 * scale))
    top += 24 * scale

    // detail 문구는 실제 위젯이 쓰는 표기를 그대로 옮긴다 (compactRemainingString).
    drawUsageBar(cg, x: x, top: top, width: w, canvas: canvas,
                 title: "5시간 창", percent: 62, detail: "3h 4m 남음", tint: T.coral, scale: scale)
    top += 46 * scale
    drawUsageBar(cg, x: x, top: top, width: w, canvas: canvas,
                 title: "주간", percent: 39, detail: "5d 3h 남음", tint: T.coral, scale: scale)

    // 푸터 — 실측 배지
    let fy = canvas.h - rect.minY - pad - 2 * scale
    text("✓ 실측", font(10.5 * scale, .medium), T.textFaint, x: x, y: canvas.top(fy))
}

/// 메뉴바에 뜨는 모양 — 아이콘 옆 소진율.
func drawMenuBarChip(_ cg: CGContext, at origin: CGPoint, canvas: Canvas, scale: CGFloat = 1) {
    let h = 28 * scale
    let label = "62%"
    let f = font(13 * scale, .medium, mono: true)
    let w = 22 * scale + textWidth(label, f) + 14 * scale
    let r = CGRect(x: origin.x, y: canvas.top(origin.y + h), width: w, height: h)
    let path = CGPath(roundedRect: r, cornerWidth: 9 * scale, cornerHeight: 9 * scale, transform: nil)
    cg.fill(path, T.inkRaised)
    cg.stroke(path, fade(T.cream, 0.10), 1 * scale)
    cg.fill(sparkle(center: CGPoint(x: r.minX + 13 * scale, y: r.midY), radius: 6.5 * scale), T.coral)
    text(label, f, T.cream, x: r.minX + 22 * scale, y: r.midY - 5 * scale)
}

/// 좌하단 특징 칩.
func drawChips(_ cg: CGContext, labels: [String], x: CGFloat, top: CGFloat, canvas: Canvas, scale: CGFloat = 1) {
    var cx = x
    let f = font(12 * scale, .medium)
    for label in labels {
        let w = textWidth(label, f) + 24 * scale
        let h = 26 * scale
        let r = CGRect(x: cx, y: canvas.top(top + h), width: w, height: h)
        let path = CGPath(roundedRect: r, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
        cg.fill(path, fade(T.coral, 0.13))
        cg.stroke(path, fade(T.coral, 0.34), 1 * scale)
        text(label, f, T.coralLight, x: r.midX, y: r.midY - 4.5 * scale, align: .center)
        cx += w + 8 * scale
    }
}

/// 다크 바탕 + 코랄 광 — 히어로/소셜 공통 배경.
func drawDarkBackdrop(_ c: Canvas) {
    let full = CGPath(rect: CGRect(x: 0, y: 0, width: c.w, height: c.h), transform: nil)
    c.cg.gradient(full, from: CGPoint(x: 0, y: c.h), to: CGPoint(x: c.w, y: 0),
                  [T.hex(0x1E1B19), T.ink, T.hex(0x100F0E)])
    c.cg.glow(at: CGPoint(x: c.w * 0.82, y: c.h * 0.92), radius: c.h * 1.05, fade(T.coral, 0.20))
    c.cg.glow(at: CGPoint(x: c.w * 0.06, y: c.h * 0.10), radius: c.h * 0.75, fade(T.coralDeep, 0.14))
    // 위·아래 얇은 코랄 선 — 배포물 전체에서 반복하는 마감.
    c.cg.capsule(CGRect(x: 0, y: c.h - 3, width: c.w, height: 3), fade(T.coral, 0.55))
}

// MARK: - README 히어로 ──────────────────────────────────────────────────────

/// scale 1.5 는 README 표시 폭(880) 의 Retina 배수를 겨우 넘기는 지점 — 2배로 뽑으면
/// 눈에 보이는 차이 없이 파일만 두 배가 된다.
func renderHero(scale: CGFloat = 1.5) -> CGImage {
    let W: CGFloat = 1200, H: CGFloat = 380
    let c = Canvas(W * scale, H * scale, scale: 1)
    let s = scale                                  // 모든 좌표에 곱한다
    drawDarkBackdrop(c)

    let left: CGFloat = 76 * s

    drawIconArt(c.cg, in: CGRect(x: left, y: c.top(48 * s) - 88 * s, width: 88 * s, height: 88 * s))

    text("Claude Usage Widget", font(42 * s, .semibold), T.cream, x: left, y: c.top(204 * s), tracking: -0.6 * s)
    text("메뉴바와 알림센터에서 Claude 사용량을 한눈에", font(17 * s, .regular), T.textDim,
         x: left, y: c.top(238 * s))
    text("claude.ai 서버 실측 소진율 · 5시간 창과 주간 한도 · 로컬 로그 기반 토큰 상세",
         font(14 * s, .regular), T.textFaint, x: left, y: c.top(266 * s))

    drawChips(c.cg, labels: ["실측 사용량", "5초 갱신", "메뉴바 + 위젯", "SwiftUI · WidgetKit"],
              x: left, top: 306 * s, canvas: c, scale: s)

    // 오른쪽 — 실제 UI 구성을 옮긴 미리보기.
    let cardSide = 232 * s
    let cardX = W * s - 84 * s - cardSide
    drawWidgetCard(c.cg, rect: CGRect(x: cardX, y: c.top(104 * s) - cardSide, width: cardSide, height: cardSide),
                   canvas: c, scale: s)
    drawMenuBarChip(c.cg, at: CGPoint(x: cardX + 6 * s, y: 54 * s), canvas: c, scale: s)

    return c.finish()
}

// MARK: - GitHub 소셜 프리뷰 (1280×640) ──────────────────────────────────────

func renderSocial() -> CGImage {
    let W: CGFloat = 1280, H: CGFloat = 640
    let c = Canvas(W, H, scale: 1)
    drawDarkBackdrop(c)

    let left: CGFloat = 96
    drawIconArt(c.cg, in: CGRect(x: left, y: c.top(126) - 124, width: 124, height: 124))

    text("Claude Usage Widget", font(54, .semibold), T.cream, x: left, y: c.top(332), tracking: -1)
    text("메뉴바와 알림센터에서 Claude 사용량을 한눈에", font(23, .regular), T.textDim, x: left, y: c.top(378))
    text("claude.ai 실측 소진율 · 5시간 창 / 주간 한도 · 토큰·비용 상세",
         font(18, .regular), T.textFaint, x: left, y: c.top(414))
    drawChips(c.cg, labels: ["macOS 15+", "SwiftUI", "WidgetKit"], x: left, top: 446, canvas: c, scale: 1.3)

    let side: CGFloat = 268
    drawWidgetCard(c.cg, rect: CGRect(x: W - 104 - side, y: c.top(190) - side, width: side, height: side),
                   canvas: c, scale: 1.15)
    drawMenuBarChip(c.cg, at: CGPoint(x: W - 104 - side + 10, y: 132), canvas: c, scale: 1.15)

    return c.finish()
}

// MARK: - DMG 배경 ──────────────────────────────────────────────────────────

/// Finder 창 배경. 아이콘이 놓이는 자리(좌 160,205 / 우 480,205)는 비워 둔다.
func renderDMGBackground(scale: CGFloat) -> CGImage {
    let W: CGFloat = 640, H: CGFloat = 400
    let c = Canvas(W, H, scale: scale)

    let full = CGPath(rect: CGRect(x: 0, y: 0, width: W, height: H), transform: nil)
    c.cg.gradient(full, from: CGPoint(x: 0, y: H), to: CGPoint(x: W, y: 0), [T.cream, T.paper])
    c.cg.glow(at: CGPoint(x: W * 0.5, y: c.top(96)), radius: 300, fade(T.coral, 0.10))
    c.cg.capsule(CGRect(x: 0, y: H - 4, width: W, height: 4), T.coral)

    // 브랜드 마크 — 아이콘 자리(160·480)와 겹치지 않게 제목 위에만.
    text("Claude Usage Widget", font(23, .semibold), T.inkOnPaper, x: W / 2, y: c.top(58), align: .center, tracking: -0.3)
    text("아이콘을 Applications 폴더로 드래그하세요", font(13, .regular), T.hex(0x7B7268),
         x: W / 2, y: c.top(86), align: .center)

    // 아이콘 자리 힌트 — 두 슬롯(160,205)/(480,205)에 옅은 원.
    for cx in [CGFloat(160), CGFloat(480)] {
        let r: CGFloat = 78
        let ring = CGMutablePath()
        ring.addEllipse(in: CGRect(x: cx - r, y: c.top(205 + r), width: r * 2, height: r * 2))
        c.cg.fill(ring, fade(T.coral, cx == 160 ? 0.05 : 0.07))
        c.cg.saveGState()
        c.cg.setLineDash(phase: 0, lengths: [5, 7])
        c.cg.stroke(ring, fade(T.coral, cx == 160 ? 0.20 : 0.34), 2)
        c.cg.restoreGState()
    }

    // 두 슬롯 사이 화살표 — 드래그 방향.
    let y = c.top(205)
    let a1: CGFloat = 252, a2: CGFloat = 388
    let dash = CGMutablePath()
    dash.move(to: CGPoint(x: a1, y: y)); dash.addLine(to: CGPoint(x: a2 - 15, y: y))
    c.cg.saveGState()
    c.cg.setLineDash(phase: 0, lengths: [7, 6])
    c.cg.stroke(dash, fade(T.coral, 0.8), 3, cap: .round)
    c.cg.restoreGState()
    let head = CGMutablePath()
    head.move(to: CGPoint(x: a2 - 16, y: y + 9))
    head.addLine(to: CGPoint(x: a2, y: y))
    head.addLine(to: CGPoint(x: a2 - 16, y: y - 9))
    head.closeSubpath()
    c.cg.fill(head, T.coral)

    // 아래쪽 안내 — 공증 없는 빌드에서 실제로 필요한 두 줄.
    text("설치 후 메뉴바 오른쪽에 아이콘이 나타납니다 (Dock 에는 뜨지 않습니다)",
         font(12, .regular), T.hex(0x857C72), x: W / 2, y: c.top(H - 58), align: .center)
    text("처음 열 때 경고가 뜨면 앱을 우클릭 → «열기» 를 선택하세요",
         font(11.5, .regular), T.hex(0x9E958B), x: W / 2, y: c.top(H - 36), align: .center)

    return c.finish()
}

// MARK: - 저장 ──────────────────────────────────────────────────────────────

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("assets")
// 앱과 위젯 익스텐션 두 곳에 넣는다. 위젯 갤러리(chronod)는 익스텐션 번들의 아이콘을
// 먼저 보므로, 앱에만 넣으면 «위젯 편집» 목록이 빈 아이콘으로 뜬다.
//
// 익스텐션은 256 까지만 넣는다 — 갤러리 목록은 아이콘을 작게(≤64pt) 쓴다. 이러면
// Assets.car 가 452KB → 142KB 로 줄어든다. (익스텐션의 AppIcon.icns 는 어차피 actool 이
// 없는 크기를 확대해서까지 전 슬롯을 채워 ~0.8MB 로 나온다. 앱 타겟은 반대로 16·32·
// 128·256 만 남기고 솎아낸다 — 두 경우 다 actool 이 정하는 것이라 여기서 못 막는다.)
struct IconTarget {
    let dir: URL
    let maxPixel: Int
}
let iconTargets = [
    IconTarget(dir: root.appendingPathComponent("ClaudeUsageWidgetApp/ClaudeUsageWidgetApp/Assets.xcassets/AppIcon.appiconset"),
               maxPixel: 1024),
    IconTarget(dir: root.appendingPathComponent("ClaudeUsageWidgetApp/ClaudeUsageWidget/Assets.xcassets/AppIcon.appiconset"),
               maxPixel: 256),
]

func write(_ image: CGImage, _ url: URL, pointSize: NSSize? = nil) {
    let rep = NSBitmapImageRep(cgImage: image)
    if let pointSize { rep.size = pointSize }
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("  \(url.path.replacingOccurrences(of: root.path + "/", with: ""))  \(image.width)×\(image.height)")
}

try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

print("==> 앱 아이콘")
// macOS 앱 아이콘 규격 — 16·32·128·256·512 의 1x/2x.
let macSizes: [(pt: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                                         (256, 1), (256, 2), (512, 1), (512, 2)]
func iconFileName(pt: Int, scale: Int) -> String {
    scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
}

var iconCache: [Int: CGImage] = [:]
for target in iconTargets {
    let sizes = macSizes.filter { $0.pt * $0.scale <= target.maxPixel }
    for (pt, scale) in sizes {
        let px = pt * scale
        let image = iconCache[px] ?? renderIcon(px: px)
        iconCache[px] = image
        write(image, target.dir.appendingPathComponent(iconFileName(pt: pt, scale: scale)))
    }
    // 남겨 두면 actool 이 Contents.json 에 없는 파일을 경고한다.
    for (pt, scale) in macSizes where !sizes.contains(where: { $0.pt == pt && $0.scale == scale }) {
        try? FileManager.default.removeItem(at: target.dir.appendingPathComponent(iconFileName(pt: pt, scale: scale)))
    }

    let contents = """
    {
      "images" : [
    """ + sizes.map { pt, scale in
        """
            {
              "filename" : "\(iconFileName(pt: pt, scale: scale))",
              "idiom" : "mac",
              "scale" : "\(scale)x",
              "size" : "\(pt)x\(pt)"
            }
        """
    }.joined(separator: ",\n") + """

      ],
      "info" : {
        "author" : "make-images.swift",
        "version" : 1
      }
    }

    """
    try! contents.write(to: target.dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("  Contents.json (\(sizes.count)개, 최대 \(target.maxPixel)px)")
}

print("==> 배포 이미지")
write(iconCache[1024] ?? renderIcon(px: 1024), assets.appendingPathComponent("app-icon.png"))
write(renderHero(), assets.appendingPathComponent("hero.png"))
write(renderSocial(), assets.appendingPathComponent("social-preview.png"))

let bg1 = renderDMGBackground(scale: 1)
let bg2 = renderDMGBackground(scale: 2)
// 미리보기용 1x PNG 만 남긴다 — Finder 가 실제로 읽는 것은 아래 다중 해상도 TIFF 다.
write(bg1, assets.appendingPathComponent("dmg-background.png"))

// Finder 는 다중 해상도 TIFF 한 장으로 Retina 배경을 고른다.
let tiffImage = NSImage()
for image in [bg1, bg2] {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: 640, height: 400)
    tiffImage.addRepresentation(rep)
}
tiffImage.size = NSSize(width: 640, height: 400)
// 무압축 TIFF 는 5MB 가 넘어 DMG 를 그만큼 불린다. LZW 로 줄여도 Finder 가 그대로 읽는다.
let tiffURL = assets.appendingPathComponent("dmg-background.tiff")
try! tiffImage.tiffRepresentation(using: .lzw, factor: 0)!.write(to: tiffURL)
let tiffKB = (try! Data(contentsOf: tiffURL)).count / 1024
print("  assets/dmg-background.tiff  640×400 (1x·2x, LZW \(tiffKB)KB)")

print("""

완료.
  · 앱 아이콘은 Assets.xcassets 에 바로 들어갔다 — ./install.sh 로 다시 빌드하면 반영된다.
  · DMG 배경·볼륨 아이콘은 ./package.sh 가 assets/ 와 appiconset 에서 자동으로 집어 쓴다.
  · assets/social-preview.png 은 GitHub 저장소 Settings → Social preview 에 올린다.
""")
