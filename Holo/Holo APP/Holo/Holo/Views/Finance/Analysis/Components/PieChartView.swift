//
//  PieChartView.swift
//  Holo
//
//  环形饼图组件（用于类别 Tab）
//  使用 Swift Charts 实现
//

import SwiftUI
import Charts

// MARK: - PieChartView

/// 环形饼图视图
struct PieChartView: View {
    let aggregations: [CategoryAggregation]
    let selectedCategory: Category?
    let onSelectCategory: ((Category?) -> Void)?

    // 图表颜色
    private let chartColors: [Color] = [
        .holoChart1, .holoChart2, .holoChart3, .holoChart4, .holoChart5
    ]

    var body: some View {
        VStack(spacing: HoloSpacing.md) {
            if aggregations.isEmpty {
                emptyChartView
            } else {
                chartContent
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    // MARK: - 图表内容

    private var chartContent: some View {
        Chart(aggregations) { agg in
            SectorMark(
                angle: .value("金额", Double(truncating: agg.amount as NSDecimalNumber)),
                innerRadius: .ratio(0.5),
                angularInset: 1.5
            )
            .cornerRadius(4)
            .foregroundStyle(colorForCategory(agg.category, at: aggregations.firstIndex(where: { $0.id == agg.id }) ?? 0))
            .opacity(selectedCategory == nil || selectedCategory?.id == agg.category.id ? 1 : 0.3)
        }
        .frame(height: 220)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                                let location = value.location

                                // 计算角度
                                let dx = location.x - center.x
                                let dy = location.y - center.y
                                let distance = sqrt(dx * dx + dy * dy)
                                let radius = min(geometry.size.width, geometry.size.height) / 2

                                // 检查是否在环形区域内
                                if distance > radius * 0.5 && distance < radius {
                                    var angle = atan2(dy, dx) * 180 / .pi
                                    if angle < 0 { angle += 360 }

                                    // 找到对应扇区
                                    let total = aggregations.reduce(0.0) { $0 + Double(truncating: $1.amount as NSDecimalNumber) }
                                    var currentAngle = -90.0 // 从顶部开始

                                    for agg in aggregations {
                                        let sectorAngle = (Double(truncating: agg.amount as NSDecimalNumber) / total) * 360
                                        if angle >= currentAngle && angle < currentAngle + sectorAngle {
                                            onSelectCategory?(agg.category)
                                            return
                                        }
                                        currentAngle += sectorAngle
                                    }
                                }
                            }
                            .onEnded { _ in
                                // 保持选中状态
                            }
                    )
            }
        }
    }

    // MARK: - 空状态

    private var emptyChartView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "chart.pie")
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无数据")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(height: 220)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 辅助方法

    private func colorForCategory(_ category: Category, at index: Int) -> Color {
        // 优先使用分类自身的颜色
        if category.isSubCategory {
            // 二级分类使用父分类颜色
            return chartColors[index % chartColors.count]
        }
        return chartColors[index % chartColors.count]
    }
}

// MARK: - Preview

#Preview("Pie Chart") {
    VStack {
        PieChartView(
            aggregations: [],
            selectedCategory: nil
        ) { _ in }
        Spacer()
    }
    .padding()
    .background(Color.holoBackground)
}
