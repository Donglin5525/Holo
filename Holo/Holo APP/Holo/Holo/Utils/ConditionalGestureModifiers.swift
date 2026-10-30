//
//  ConditionalGestureModifiers.swift
//  Holo
//
//  条件手势工具（防死入口）：子视图「可选交互」在能力不可用时必须整组不挂手势，
//  让点击穿透到父级（如整卡打开详情）；挂了手势又在 action 里判空 = 吞点击的死区。
//

import SwiftUI

extension View {
    /// 仅在条件成立时挂点击手势；不成立时不挂，点击穿透到父级。
    @ViewBuilder
    func onTapGestureIf(_ condition: Bool, perform action: @escaping () -> Void) -> some View {
        if condition {
            onTapGesture(perform: action)
        } else {
            self
        }
    }

    /// 仅在条件成立时声明命中区；不成立时不拦截，点击穿透到父级。
    @ViewBuilder
    func contentShapeIf<S: Shape>(_ condition: Bool, shape: S) -> some View {
        if condition {
            contentShape(shape)
        } else {
            self
        }
    }
}
