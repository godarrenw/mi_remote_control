import SwiftUI

// MARK: - 几何（纯函数，180×480 逻辑坐标系；供绘制 + hitTest + self-test 共用）

enum RemoteDiagramGeometry {
    static let canvas = CGSize(width: 180, height: 480)
    static let ringCenter = CGPoint(x: 90, y: 168)
    static let ringOuter: CGFloat = 71
    static let ringInner: CGFloat = 33

    /// 独立圆键：(圆心, 半径)
    static let circles: [RemoteKey: (center: CGPoint, r: CGFloat)] = [
        .power: (CGPoint(x: 57, y: 46), 17),
        .voice: (CGPoint(x: 123, y: 46), 17),
        .back:  (CGPoint(x: 57, y: 271), 19),
        .home:  (CGPoint(x: 57, y: 317), 19),
        .menu:  (CGPoint(x: 57, y: 363), 19),
        .tv:    (CGPoint(x: 123, y: 363), 19),
    ]

    /// 音量胶囊：x 101…145，上半 252…294，下半 294…336。
    static let volRect = CGRect(x: 101, y: 252, width: 44, height: 84)
    static let volSplitY: CGFloat = 294

    /// 方向段角度范围（度，0°=+x，顺时针为正因 y 向下）。
    static func direction(forAngle deg: Double) -> RemoteKey {
        // 归一到 -180…180
        var a = deg.truncatingRemainder(dividingBy: 360)
        if a > 180 { a -= 360 }
        if a < -180 { a += 360 }
        switch a {
        case -135 ..< -45: return .up
        case -45 ..< 45:   return .right
        case 45 ..< 135:   return .down
        default:           return .left
        }
    }

    /// 命中测试（逻辑坐标）。hit 区比可见略大（r+2）。
    static func key(at p: CGPoint) -> RemoteKey? {
        // 方向环 + OK
        let dx = p.x - ringCenter.x, dy = p.y - ringCenter.y
        let dist = (dx * dx + dy * dy).squareRoot()
        if dist <= ringInner + 2 { return .ok }
        if dist <= ringOuter + 2 {
            let deg = atan2(Double(dy), Double(dx)) * 180 / .pi
            return direction(forAngle: deg)
        }
        // 独立圆键
        for (key, c) in circles {
            let ddx = p.x - c.center.x, ddy = p.y - c.center.y
            if (ddx * ddx + ddy * ddy).squareRoot() <= c.r + 2 { return key }
        }
        // 音量胶囊
        if volRect.insetBy(dx: -2, dy: -2).contains(p) {
            return p.y < volSplitY ? .volUp : .volDown
        }
        return nil
    }

    /// 方向段的圆弧角度范围（SwiftUI Angle 用，度）。
    static func sectorAngles(_ key: RemoteKey) -> (start: Double, end: Double)? {
        switch key {
        case .up:    return (225, 315)
        case .right: return (-45, 45)
        case .down:  return (45, 135)
        case .left:  return (135, 225)
        default:     return nil
        }
    }

    /// 方向段圆点标记位置。
    static let sectorDot: [RemoteKey: CGPoint] = [
        .up: CGPoint(x: 90, y: 116), .right: CGPoint(x: 142, y: 168),
        .down: CGPoint(x: 90, y: 220), .left: CGPoint(x: 38, y: 168),
    ]

    /// 环形扇区 Path（逻辑坐标）。
    static func sectorPath(_ key: RemoteKey) -> Path? {
        guard let (start, end) = sectorAngles(key) else { return nil }
        var p = Path()
        p.addArc(center: ringCenter, radius: ringOuter,
                 startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        let endRad = end * .pi / 180
        p.addLine(to: CGPoint(x: ringCenter.x + ringInner * CGFloat(cos(endRad)),
                              y: ringCenter.y + ringInner * CGFloat(sin(endRad))))
        p.addArc(center: ringCenter, radius: ringInner,
                 startAngle: .degrees(end), endAngle: .degrees(start), clockwise: true)
        p.closeSubpath()
        return p
    }

    /// 自测：关键点命中。
    static func selfCheck() -> Bool {
        key(at: CGPoint(x: 90, y: 168)) == .ok
            && key(at: CGPoint(x: 90, y: 116)) == .up
            && key(at: CGPoint(x: 142, y: 168)) == .right
            && key(at: CGPoint(x: 90, y: 220)) == .down
            && key(at: CGPoint(x: 38, y: 168)) == .left
            && key(at: CGPoint(x: 57, y: 46)) == .power
            && key(at: CGPoint(x: 123, y: 46)) == .voice
            && key(at: CGPoint(x: 57, y: 271)) == .back
            && key(at: CGPoint(x: 57, y: 317)) == .home
            && key(at: CGPoint(x: 57, y: 363)) == .menu
            && key(at: CGPoint(x: 123, y: 363)) == .tv
            && key(at: CGPoint(x: 123, y: 273)) == .volUp
            && key(at: CGPoint(x: 123, y: 315)) == .volDown
            && key(at: CGPoint(x: 10, y: 10)) == nil
            && key(at: CGPoint(x: 90, y: 460)) == nil
    }
}

// MARK: - 视图

/// 遥控器示意图（纯 SwiftUI 矢量绘制，180×480 逻辑坐标等比缩放）。
/// selected=点选高亮；flashing=「按下即亮」实时回显（复用高亮样式）。
@MainActor
struct RemoteDiagram: View {
    @Binding var selected: RemoteKey
    var flashing: RemoteKey?
    var connected: Bool
    /// 额外强调的键（向导配对步高亮 主页+返回；与选中/回显共用高亮样式）
    var emphasized: Set<RemoteKey> = []
    /// false = 纯展示（不可点选、不画选中高亮），供向导等只读场景
    var interactive: Bool = true

    private typealias G = RemoteDiagramGeometry
    private let bodyFill = Color(nsColor: NSColor(name: nil) { $0.name == .darkAqua
        ? NSColor(white: 0.32, alpha: 1) : NSColor(red: 0.843, green: 0.851, blue: 0.859, alpha: 1) })
    private let bodyStroke = Color(nsColor: NSColor(name: nil) { $0.name == .darkAqua
        ? NSColor(white: 0.25, alpha: 1) : NSColor(red: 0.757, green: 0.765, blue: 0.776, alpha: 1) })
    private let keyFace = Color(red: 0.11, green: 0.11, blue: 0.12)   // #1c1c1e，深浅模式均保留

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / G.canvas.width, geo.size.height / G.canvas.height)
            ZStack(alignment: .topLeading) {
                canvasView(scale: scale)
            }
            .frame(width: G.canvas.width * scale, height: G.canvas.height * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard interactive else { return }
                let origin = CGPoint(x: (geo.size.width - G.canvas.width * scale) / 2,
                                     y: (geo.size.height - G.canvas.height * scale) / 2)
                let logical = CGPoint(x: (location.x - origin.x) / scale,
                                      y: (location.y - origin.y) / scale)
                if let key = G.key(at: logical) {
                    withAnimation(Motion.select) { selected = key }
                }
            }
        }
        .aspectRatio(G.canvas.width / G.canvas.height, contentMode: .fit)
    }

    private func highlighted(_ key: RemoteKey) -> Bool {
        (interactive && selected == key) || flashing == key || emphasized.contains(key)
    }

    @ViewBuilder
    private func canvasView(scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                ctx.scaleBy(x: scale, y: scale)

                // 机身
                let bodyRect = CGRect(x: 6, y: 6, width: 168, height: 448)
                let bodyPath = Path(roundedRect: bodyRect, cornerRadius: 40)
                ctx.fill(bodyPath, with: .color(bodyFill))
                ctx.stroke(bodyPath, with: .color(bodyStroke), lineWidth: 1)

                // 方向环底盘
                let ring = Path(ellipseIn: CGRect(x: G.ringCenter.x - G.ringOuter, y: G.ringCenter.y - G.ringOuter,
                                                  width: G.ringOuter * 2, height: G.ringOuter * 2))
                ctx.fill(ring, with: .color(keyFace))

                // 方向段：默认灰点，选中蓝弧+蓝点+发光
                for dir in [RemoteKey.up, .right, .down, .left] {
                    let hi = highlighted(dir)
                    if hi, let sector = G.sectorPath(dir) {
                        ctx.fill(sector, with: .color(Color.accentColor.opacity(0.18)))
                    }
                    if let dot = G.sectorDot[dir] {
                        let dotPath = Path(ellipseIn: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6))
                        ctx.fill(dotPath, with: .color(hi ? Color.accentColor : Color(white: 0.43)))
                    }
                    if hi, let (start, end) = G.sectorAngles(dir) {
                        var arc = Path()
                        arc.addArc(center: G.ringCenter, radius: G.ringOuter - 1.5,
                                   startAngle: .degrees(start + 4), endAngle: .degrees(end - 4), clockwise: false)
                        var glow = ctx
                        glow.addFilter(.shadow(color: Color.accentColor.opacity(0.6), radius: 4))
                        glow.stroke(arc, with: .color(Color.accentColor), lineWidth: 2)
                    }
                }

                // OK
                let okRect = CGRect(x: G.ringCenter.x - G.ringInner, y: G.ringCenter.y - G.ringInner,
                                    width: G.ringInner * 2, height: G.ringInner * 2)
                let ok = Path(ellipseIn: okRect)
                ctx.fill(ok, with: .color(.black))
                if highlighted(.ok) {
                    ctx.fill(ok, with: .color(Color.accentColor.opacity(0.22)))
                    var glow = ctx
                    glow.addFilter(.shadow(color: Color.accentColor.opacity(0.6), radius: 4))
                    glow.stroke(ok, with: .color(Color.accentColor), lineWidth: 2)
                } else {
                    ctx.stroke(ok, with: .color(Color(white: 0.3)), lineWidth: 1)
                }

                // 独立圆键
                for (key, c) in G.circles {
                    let rect = CGRect(x: c.center.x - c.r, y: c.center.y - c.r, width: c.r * 2, height: c.r * 2)
                    let path = Path(ellipseIn: rect)
                    ctx.fill(path, with: .color(keyFace))
                    if highlighted(key) {
                        ctx.fill(path, with: .color(Color.accentColor.opacity(0.22)))
                        var glow = ctx
                        glow.addFilter(.shadow(color: Color.accentColor.opacity(0.6), radius: 4))
                        glow.stroke(path, with: .color(Color.accentColor), lineWidth: 2)
                    }
                }

                // 音量胶囊
                let vol = Path(roundedRect: G.volRect, cornerRadius: 22)
                ctx.fill(vol, with: .color(keyFace))
                var split = Path()
                split.move(to: CGPoint(x: G.volRect.minX + 4, y: G.volSplitY))
                split.addLine(to: CGPoint(x: G.volRect.maxX - 4, y: G.volSplitY))
                ctx.stroke(split, with: .color(.black.opacity(0.5)), lineWidth: 1)
                for (key, half) in [(RemoteKey.volUp, CGRect(x: G.volRect.minX, y: G.volRect.minY, width: 44, height: 42)),
                                    (.volDown, CGRect(x: G.volRect.minX, y: G.volSplitY, width: 44, height: 42))] {
                    if highlighted(key) {
                        let corners: Path = key == .volUp
                            ? partialCapsule(half, roundTop: true)
                            : partialCapsule(half, roundTop: false)
                        var fillHalf = corners
                        fillHalf.closeSubpath()
                        ctx.fill(fillHalf, with: .color(Color.accentColor.opacity(0.22)))
                        var glow = ctx
                        glow.addFilter(.shadow(color: Color.accentColor.opacity(0.6), radius: 4))
                        glow.stroke(corners, with: .color(Color.accentColor), lineWidth: 2)
                    }
                }

                // 底部丝印
                ctx.draw(Text("xiaomi").font(.system(size: 9)).foregroundStyle(Color(white: 0.6)),
                         at: CGPoint(x: 90, y: 430))
                let nfc = Path(roundedRect: CGRect(x: 136, y: 421, width: 13, height: 13), cornerRadius: 3)
                ctx.stroke(nfc, with: .color(Color(white: 0.6)), lineWidth: 1)
                ctx.draw(Text("N").font(.system(size: 8)).foregroundStyle(Color(white: 0.6)),
                         at: CGPoint(x: 142.5, y: 427.5))

                // 连接状态
                let dot = Path(ellipseIn: CGRect(x: 90 - 26 - 3, y: 463, width: 6, height: 6))
                ctx.fill(dot, with: .color(connected ? Color.accentColor : Color(white: 0.6)))
                ctx.draw(Text(connected ? "已连接" : "未连接").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: 90 + 8, y: 466))
            }

            // 键面图标（SF Symbols，逻辑坐标 → 缩放）
            iconOverlay(scale: scale)
        }
    }

    private func partialCapsule(_ rect: CGRect, roundTop: Bool) -> Path {
        var p = Path()
        let r: CGFloat = 22
        if roundTop {
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                     startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        return p
    }

    @ViewBuilder
    private func iconOverlay(scale: CGFloat) -> some View {
        let icons: [(RemoteKey, String, CGPoint, CGFloat)] = [
            (.power, "power", CGPoint(x: 57, y: 46), 14),
            (.voice, "mic", CGPoint(x: 123, y: 46), 14),
            (.back, "arrow.left", CGPoint(x: 57, y: 271), 15),
            (.home, "house", CGPoint(x: 57, y: 317), 15),
            (.menu, "line.3.horizontal", CGPoint(x: 57, y: 363), 15),
            (.tv, "tv", CGPoint(x: 123, y: 363), 14),
            (.volUp, "plus", CGPoint(x: 123, y: 273), 13),
            (.volDown, "minus", CGPoint(x: 123, y: 315), 13),
        ]
        ForEach(icons, id: \.0) { item in
            Image(systemName: item.1)
                .font(.system(size: item.3 * scale, weight: .medium))
                .foregroundStyle(.white)
                .position(x: item.2.x * scale, y: item.2.y * scale)
                .allowsHitTesting(false)
        }
        Text("OK")
            .font(.system(size: 13 * scale, weight: .semibold))
            .foregroundStyle(.white)
            .position(x: RemoteDiagramGeometry.ringCenter.x * scale,
                      y: RemoteDiagramGeometry.ringCenter.y * scale)
            .allowsHitTesting(false)
    }
}
