//
//  OverBudgetStripes.swift
//  Holo
//
//  预算超支提示 - 进度条斜纹叠加层
//

import SwiftUI

/// 45° 斜纹 Shape（用于超支进度条的"溢出"视觉提示）
struct OverBudgetStripes: Shape {
    var stripeWidth: CGFloat = 6
    var spacing: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let period = stripeWidth + spacing
        var x: CGFloat = -rect.height
        while x < rect.width + rect.height {
            path.move(to: CGPoint(x: x, y: rect.height))
            path.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += period
        }
        return path
    }
}

/// 斜纹叠加层：白色半透明斜纹，盖在满格红色进度条上
struct OverBudgetStripeOverlay: View {
    var body: some View {
        OverBudgetStripes()
            .stroke(Color.white.opacity(0.25), lineWidth: 6)
    }
}
