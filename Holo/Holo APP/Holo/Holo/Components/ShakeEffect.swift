//
//  ShakeEffect.swift
//  Holo
//
//  水平抖动效果：递增 trigger 驱动一次左右晃动，用于保存被拦截等需要
//  「明确告知哪里没做」的场景（金额为空点保存、分类未选等）。
//

import SwiftUI

struct ShakeEffect: GeometryEffect {
    /// 每次抖动的最大水平位移
    var travel: CGFloat = 7
    /// 单位位移内的晃动次数
    var shakesPerUnit: CGFloat = 3
    /// 动画驱动值：外部递增（如 `withAnimation { trigger += 1 }`）即触发一次抖动
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(
                translationX: travel * sin(animatableData * .pi * shakesPerUnit * 2),
                y: 0
            )
        )
    }
}
