import SwiftUI

// MARK: - 全局设计常量（HIG 对齐：统一间距 / 圆角 / 动效，消灭散落的魔法数字）

/// 间距体系：页面 24 / 组间 20 / 组内 10 / 行内 14×8。
enum Spacing {
    /// 页面内容四周留白
    static let page: CGFloat = 24
    /// 分组（卡片）之间的垂直距离
    static let section: CGFloat = 20
    /// 组内元素间距（图标与文字、标题与卡片）
    static let intra: CGFloat = 10
    /// 行左右内边距
    static let rowH: CGFloat = 14
    /// 行上下内边距
    static let rowV: CGFloat = 8
    /// 表单行最小高度
    static let rowMinHeight: CGFloat = 38
    /// 卡片内自由布局的内边距
    static let cardPadding: CGFloat = 14
    /// sheet / 浮层容器的内边距
    static let sheetPadding: CGFloat = 20
}

/// 圆角体系：小微章 6 / 控件徽标 7 / 卡片 10 / HUD 12 / 浮层 16。
enum Radius {
    static let small: CGFloat = 6
    static let badge: CGFloat = 7
    static let card: CGFloat = 10
    static let hud: CGFloat = 12
    static let overlay: CGFloat = 16
}

/// 动效体系：浮层弹入用 spring，选中/焦点切换用 0.15s 缓动；
/// AppKit 侧（NSAnimationContext）淡入/淡出统一走这两个时长。
enum Motion {
    static let overlay = Animation.spring(response: 0.3, dampingFraction: 0.85)
    static let select = Animation.easeInOut(duration: 0.15)
    static let focus = Animation.easeInOut(duration: 0.2)
    static let fadeInDuration: TimeInterval = 0.18
    static let fadeOutDuration: TimeInterval = 0.2
    /// 微提示出现 / 退场（「已保存」一类 toast）
    static let quickFade = Animation.easeIn(duration: 0.1)
    static let toastFade = Animation.easeOut(duration: 0.4)
    /// 实时电平表刷新
    static let meter = Animation.linear(duration: 0.08)
}

/// 每页统一的大标题 + 副标题（复刻系统设置左对齐版式）。
struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}
