//
//  HoloStaggeredAppear.swift
//  Holo
//
//  列表行错峰入场：按 index 依次淡入（与习惯磁贴墙同一手感：easeOut 0.3s、
//  最多错峰 0.3s、只做 opacity 不做位移——克制，不表演）。
//  用法：ForEach 内的行视图挂 `.holoStaggeredAppear(index: index)`。
//

import SwiftUI

struct HoloStaggeredAppear: ViewModifier {

    let index: Int
    var motion = HoloContinuousMotion()

    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared || !motion.isActive ? 1 : 0)
            .onAppear {
                guard !appeared else { return }
                withAnimation(motion.isActive ? .easeOut(duration: 0.3).delay(Double(max(0, min(index, 3))) * 0.1) : nil) {
                    appeared = true
                }
            }
    }
}

extension View {
    /// 列表行错峰入场。延迟最多 0.3 秒，总时长不超过 0.6 秒；
    /// 减少动态效果或页面不可见时直接展示，不累积后台入场。
    func holoStaggeredAppear(index: Int) -> some View {
        modifier(HoloStaggeredAppear(index: index))
    }
}
