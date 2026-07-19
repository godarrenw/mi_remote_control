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
}

/// 圆角体系：卡片 10 / 控件徽标 7 / 浮层 16 / HUD 12。
enum Radius {
    static let card: CGFloat = 10
    static let badge: CGFloat = 7
    static let overlay: CGFloat = 16
    static let hud: CGFloat = 12
}

/// 动效体系：浮层弹入用 spring，选中/焦点切换用 0.15s 缓动。
enum Motion {
    static let overlay = Animation.spring(response: 0.3, dampingFraction: 0.85)
    static let select = Animation.easeInOut(duration: 0.15)
    static let focus = Animation.easeInOut(duration: 0.2)
}

/// 每页统一的大标题 + 副标题（复刻系统设置左对齐版式）。
struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title.bold())
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}
