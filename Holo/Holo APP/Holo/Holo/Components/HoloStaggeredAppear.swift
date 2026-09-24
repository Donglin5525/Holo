//
//  HoloStaggeredAppear.swift
//  Holo
//
//  列表行错峰入场：按 index 依次淡入（与习惯磁贴墙同一手感：easeOut 0.45s、
//  每行错峰 0.04s、只做 opacity 不做位移——克制，不表演）。
//  用法：ForEach 内的行视图挂 `.holoStaggeredAppear(index: index)`。
//

import SwiftUI

struct HoloStaggeredAppear: ViewModifier {

    let index: Int

    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .onAppear {
                guard !appeared else { return }
                withAnimation(.easeOut(duration: 0.45).delay(Double(min(index, 12)) * 0.04)) {
                    appeared = true
                }
            }
    }
}

extension View {
    /// 列表行错峰入场。index 传行在列表中的序号；延迟按 min(index, 12) 封顶，
    /// 长列表滚到底部时不再累计等待（滚入的新行立即播自己的淡入）。
    func holoStaggeredAppear(index: Int) -> some View {
        modifier(HoloStaggeredAppear(index: index))
    }
}
