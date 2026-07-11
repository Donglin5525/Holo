//
//  Category+Icon.swift
//  Holo
//
//  分类图标扩展 - 提供分类图标的统一渲染方法
//

import SwiftUI

// MARK: - Category Icon View Builder

/// 获取分类图标
/// - Parameters:
///   - category: 分类对象
///   - size: 图标尺寸
/// - Returns: 图标视图
@ViewBuilder
func transactionCategoryIcon(_ category: Category, size: CGFloat) -> some View {
    let name = category.icon

    if name.hasPrefix("icon_") {
        // 兼容：用户自定义分类仍使用旧 icon_ 名称，回退到 tag.fill
        Image(systemName: "tag.fill")
            .font(.system(size: size * 0.6, weight: .medium))
            .foregroundColor(category.swiftUIColor)
    } else {
        categoryIconGlyph(name, size: size * 0.6, color: category.swiftUIColor)
    }
}

@ViewBuilder
func categoryIconGlyph(_ iconName: String, size: CGFloat, color: Color) -> some View {
    if iconName.hasPrefix("finance_") || iconName.hasPrefix("income_") || iconName.hasPrefix("cat_") {
        Image(iconName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundColor(color)
    } else if CategoryIconCatalog.isCustomIcon(iconName) {
        HoloFallbackCategoryIcon(kind: iconName, size: size)
            .foregroundColor(color)
    } else {
        Image(systemName: iconName)
            .font(.system(size: size, weight: .medium))
            .foregroundColor(color)
    }
}

private struct HoloFallbackCategoryIcon: View {
    let kind: String
    let size: CGFloat

    var body: some View {
        if kind == "holo.category.breakfast" {
            BreakfastFallbackShape()
                .stroke(style: StrokeStyle(lineWidth: max(1.6, size * 0.09), lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
        } else if kind == "holo.category.lunch" {
            LunchFallbackShape()
                .stroke(style: StrokeStyle(lineWidth: max(1.6, size * 0.09), lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
        } else if kind == "holo.category.dinner" {
            DinnerFallbackShape()
                .stroke(style: StrokeStyle(lineWidth: max(1.6, size * 0.09), lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
        } else if kind == "holo.category.fruit" {
            FruitFallbackShape()
                .stroke(style: StrokeStyle(lineWidth: max(1.6, size * 0.09), lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
        } else if kind == "holo.category.misc" {
            MiscFallbackShape()
                .stroke(style: StrokeStyle(lineWidth: max(1.6, size * 0.09), lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
        } else {
            GenericFallbackShape()
                .stroke(style: StrokeStyle(lineWidth: max(1.6, size * 0.09), lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
        }
    }
}

private struct BreakfastFallbackShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        let r = CGRect(x: origin.x, y: origin.y, width: side, height: side)

        var path = Path()
        path.addEllipse(in: CGRect(x: r.minX + side * 0.22, y: r.minY + side * 0.30, width: side * 0.56, height: side * 0.44))
        path.addEllipse(in: CGRect(x: r.minX + side * 0.40, y: r.minY + side * 0.42, width: side * 0.20, height: side * 0.16))
        path.move(to: CGPoint(x: r.minX + side * 0.24, y: r.minY + side * 0.82))
        path.addLine(to: CGPoint(x: r.minX + side * 0.76, y: r.minY + side * 0.82))
        path.move(to: CGPoint(x: r.minX + side * 0.34, y: r.minY + side * 0.16))
        path.addCurve(
            to: CGPoint(x: r.minX + side * 0.34, y: r.minY + side * 0.28),
            control1: CGPoint(x: r.minX + side * 0.28, y: r.minY + side * 0.20),
            control2: CGPoint(x: r.minX + side * 0.42, y: r.minY + side * 0.24)
        )
        path.move(to: CGPoint(x: r.minX + side * 0.52, y: r.minY + side * 0.12))
        path.addCurve(
            to: CGPoint(x: r.minX + side * 0.52, y: r.minY + side * 0.26),
            control1: CGPoint(x: r.minX + side * 0.46, y: r.minY + side * 0.17),
            control2: CGPoint(x: r.minX + side * 0.60, y: r.minY + side * 0.21)
        )
        return path
    }
}

private struct LunchFallbackShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        let r = CGRect(x: origin.x, y: origin.y, width: side, height: side)

        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: r.minX + side * 0.20, y: r.minY + side * 0.28, width: side * 0.60, height: side * 0.48),
            cornerSize: CGSize(width: side * 0.14, height: side * 0.14)
        )
        path.move(to: CGPoint(x: r.minX + side * 0.20, y: r.minY + side * 0.42))
        path.addLine(to: CGPoint(x: r.minX + side * 0.80, y: r.minY + side * 0.42))
        path.move(to: CGPoint(x: r.minX + side * 0.36, y: r.minY + side * 0.28))
        path.addLine(to: CGPoint(x: r.minX + side * 0.36, y: r.minY + side * 0.76))
        path.move(to: CGPoint(x: r.minX + side * 0.58, y: r.minY + side * 0.22))
        path.addLine(to: CGPoint(x: r.minX + side * 0.74, y: r.minY + side * 0.14))
        return path
    }
}

private struct DinnerFallbackShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        let r = CGRect(x: origin.x, y: origin.y, width: side, height: side)

        var path = Path()
        path.addArc(
            center: CGPoint(x: r.midX, y: r.minY + side * 0.56),
            radius: side * 0.27,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.move(to: CGPoint(x: r.minX + side * 0.20, y: r.minY + side * 0.56))
        path.addLine(to: CGPoint(x: r.minX + side * 0.80, y: r.minY + side * 0.56))
        path.move(to: CGPoint(x: r.midX, y: r.minY + side * 0.24))
        path.addLine(to: CGPoint(x: r.midX, y: r.minY + side * 0.18))
        path.move(to: CGPoint(x: r.minX + side * 0.26, y: r.minY + side * 0.72))
        path.addLine(to: CGPoint(x: r.minX + side * 0.74, y: r.minY + side * 0.72))
        path.move(to: CGPoint(x: r.minX + side * 0.38, y: r.minY + side * 0.82))
        path.addLine(to: CGPoint(x: r.minX + side * 0.62, y: r.minY + side * 0.82))
        return path
    }
}

private struct FruitFallbackShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        let r = CGRect(x: origin.x, y: origin.y, width: side, height: side)

        var path = Path()
        path.addEllipse(in: CGRect(x: r.minX + side * 0.24, y: r.minY + side * 0.30, width: side * 0.52, height: side * 0.50))
        path.move(to: CGPoint(x: r.midX, y: r.minY + side * 0.32))
        path.addCurve(
            to: CGPoint(x: r.minX + side * 0.56, y: r.minY + side * 0.14),
            control1: CGPoint(x: r.minX + side * 0.48, y: r.minY + side * 0.24),
            control2: CGPoint(x: r.minX + side * 0.52, y: r.minY + side * 0.18)
        )
        path.addCurve(
            to: CGPoint(x: r.minX + side * 0.72, y: r.minY + side * 0.24),
            control1: CGPoint(x: r.minX + side * 0.66, y: r.minY + side * 0.12),
            control2: CGPoint(x: r.minX + side * 0.72, y: r.minY + side * 0.16)
        )
        path.addCurve(
            to: CGPoint(x: r.minX + side * 0.56, y: r.minY + side * 0.26),
            control1: CGPoint(x: r.minX + side * 0.66, y: r.minY + side * 0.28),
            control2: CGPoint(x: r.minX + side * 0.62, y: r.minY + side * 0.28)
        )
        return path
    }
}

private struct GenericFallbackShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        let r = CGRect(x: origin.x, y: origin.y, width: side, height: side)
        let dot = side * 0.13
        let points = [
            CGPoint(x: r.minX + side * 0.28, y: r.minY + side * 0.30),
            CGPoint(x: r.minX + side * 0.70, y: r.minY + side * 0.26),
            CGPoint(x: r.minX + side * 0.74, y: r.minY + side * 0.70),
            CGPoint(x: r.minX + side * 0.32, y: r.minY + side * 0.74),
        ]

        var path = Path()
        path.addRoundedRect(in: r.insetBy(dx: side * 0.08, dy: side * 0.08), cornerSize: CGSize(width: side * 0.22, height: side * 0.22))
        path.move(to: points[0])
        path.addLine(to: points[1])
        path.addLine(to: points[2])
        path.addLine(to: points[3])
        path.closeSubpath()

        for point in points {
            path.addEllipse(in: CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot))
        }
        return path
    }
}

private struct MiscFallbackShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        let r = CGRect(x: origin.x, y: origin.y, width: side, height: side)

        var path = Path()
        path.addRoundedRect(in: CGRect(x: r.minX + side * 0.14, y: r.minY + side * 0.18, width: side * 0.48, height: side * 0.48), cornerSize: CGSize(width: side * 0.14, height: side * 0.14))
        path.addEllipse(in: CGRect(x: r.minX + side * 0.48, y: r.minY + side * 0.42, width: side * 0.34, height: side * 0.34))
        path.move(to: CGPoint(x: r.minX + side * 0.24, y: r.minY + side * 0.80))
        path.addLine(to: CGPoint(x: r.minX + side * 0.76, y: r.minY + side * 0.80))
        return path
    }
}
