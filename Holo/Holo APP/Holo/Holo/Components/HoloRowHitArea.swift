import SwiftUI

extension View {
    /// 放在行内容的内边距之后，让留白也属于外层按钮或导航的点击区域。
    /// 本修饰符只定义布局与命中范围，不接管开关、展开按钮等独立动作。
    func holoRowHitArea(minHeight: CGFloat = 44, alignment: Alignment = .leading) -> some View {
        frame(maxWidth: .infinity, minHeight: minHeight, alignment: alignment)
            .contentShape(Rectangle())
    }
}
