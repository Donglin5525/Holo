//
//  SwipeActionIcons.swift
//  Holo
//
//  右滑手势 - 自绘图标
//

import SwiftUI

// MARK: - 归档图标

/// 自绘归档图标（圆角矩形箱子 + 向下箭头）
struct ArchiveIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let offsetX = (rect.width - 24 * scale) / 2
        let offsetY = (rect.height - 24 * scale) / 2

        var path = Path()

        // 箱子主体（圆角矩形）
        let boxRect = CGRect(
            x: 3 * scale + offsetX,
            y: 7 * scale + offsetY,
            width: 18 * scale,
            height: 14 * scale
        )
        let cornerRadius = 2 * scale
        path.addRoundedRect(in: boxRect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))

        // 箱盖（顶部横线）
        path.move(to: CGPoint(x: 3 * scale + offsetX, y: 10 * scale + offsetY))
        path.addLine(to: CGPoint(x: 21 * scale + offsetX, y: 10 * scale + offsetY))

        // 向下箭头
        let arrowCenterX = 12 * scale + offsetX
        let arrowTop = 12 * scale + offsetY
        let arrowBottom = 17.5 * scale + offsetY

        path.move(to: CGPoint(x: arrowCenterX, y: arrowTop))
        path.addLine(to: CGPoint(x: arrowCenterX, y: arrowBottom))

        path.move(to: CGPoint(x: 9.5 * scale + offsetX, y: 15 * scale + offsetY))
        path.addLine(to: CGPoint(x: arrowCenterX, y: arrowBottom))
        path.addLine(to: CGPoint(x: 14.5 * scale + offsetX, y: 15 * scale + offsetY))

        return path
    }
}

// MARK: - 延期图标

/// 自绘延期图标（表盘 + 顺时针箭头，语义：把时间往后拨）
struct PostponeIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let offsetX = (rect.width - 24 * scale) / 2
        let offsetY = (rect.height - 24 * scale) / 2

        var path = Path()
        let centerX = 12 * scale + offsetX
        let centerY = 12 * scale + offsetY
        let radius = 8 * scale

        // 表盘（留出右上箭头的缺口：从 55° 画到 305°，逆时针方向不画）
        path.addArc(
            center: CGPoint(x: centerX, y: centerY),
            radius: radius,
            startAngle: .degrees(55),
            endAngle: .degrees(305),
            clockwise: true
        )

        // 指针
        path.move(to: CGPoint(x: centerX, y: centerY))
        path.addLine(to: CGPoint(x: centerX, y: centerY - 5 * scale))
        path.move(to: CGPoint(x: centerX, y: centerY))
        path.addLine(to: CGPoint(x: centerX + 3.5 * scale, y: centerY + 1.5 * scale))

        // 右上角顺时针箭头
        let arrowBase = CGPoint(x: centerX + 4.6 * scale, y: centerY - 4.6 * scale)
        let arrowTip = CGPoint(x: centerX + 7.2 * scale, y: centerY - 2 * scale)
        path.move(to: arrowBase)
        path.addLine(to: arrowTip)
        path.move(to: arrowTip)
        path.addLine(to: CGPoint(x: arrowTip.x - 3.2 * scale, y: arrowTip.y))
        path.move(to: arrowTip)
        path.addLine(to: CGPoint(x: arrowTip.x, y: arrowTip.y - 3.2 * scale))

        return path
    }
}

// MARK: - 删除图标

/// 自绘删除图标（梯形桶身 + 手柄 + 内部分隔线）
struct TrashIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let offsetX = (rect.width - 24 * scale) / 2
        let offsetY = (rect.height - 24 * scale) / 2

        var path = Path()

        // 手柄（顶部 U 形）
        path.move(to: CGPoint(x: 9 * scale + offsetX, y: 5.5 * scale + offsetY))
        path.addLine(to: CGPoint(x: 9 * scale + offsetX, y: 4 * scale + offsetY))
        path.addArc(
            center: CGPoint(x: 12 * scale + offsetX, y: 4 * scale + offsetY),
            radius: 3 * scale,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: 15 * scale + offsetX, y: 5.5 * scale + offsetY))

        // 桶顶横线
        path.move(to: CGPoint(x: 4.5 * scale + offsetX, y: 6.5 * scale + offsetY))
        path.addLine(to: CGPoint(x: 19.5 * scale + offsetX, y: 6.5 * scale + offsetY))

        // 桶身（梯形）
        path.move(to: CGPoint(x: 6 * scale + offsetX, y: 8 * scale + offsetY))
        path.addLine(to: CGPoint(x: 7.5 * scale + offsetX, y: 19.5 * scale + offsetY))
        path.addLine(to: CGPoint(x: 16.5 * scale + offsetX, y: 19.5 * scale + offsetY))
        path.addLine(to: CGPoint(x: 18 * scale + offsetX, y: 8 * scale + offsetY))

        // 内部分隔线
        path.move(to: CGPoint(x: 10 * scale + offsetX, y: 10 * scale + offsetY))
        path.addLine(to: CGPoint(x: 10.3 * scale + offsetX, y: 17 * scale + offsetY))

        path.move(to: CGPoint(x: 14 * scale + offsetX, y: 10 * scale + offsetY))
        path.addLine(to: CGPoint(x: 13.7 * scale + offsetX, y: 17 * scale + offsetY))

        return path
    }
}
