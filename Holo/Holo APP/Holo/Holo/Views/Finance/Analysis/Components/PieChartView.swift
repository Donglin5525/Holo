//
//  PieChartView.swift
//  Holo
//
//  环形饼图组件（用于类别 Tab）
//  使用 Swift Charts 实现，带中心信息展示
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

    // 选中的聚合数据
    private var selectedAggregation: CategoryAggregation? {
        guard let category = selectedCategory else {
            return aggregations.first
        }
        return aggregations.first { $0.category.id == category.id }
    }

    // 总金额
    private var totalAmount: Decimal {
        aggregations.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        VStack(spacing: HoloSpacing.md) {
            if aggregations.isEmpty {
                emptyChartView
            } else {
                chartWithCenter
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    // MARK: - 图表带中心信息

    private var chartWithCenter: some View {
        ZStack {
            // 饼图
            Chart(aggregations) { agg in
                SectorMark(
                    angle: .value("金额", Double(truncating: agg.amount as NSDecimalNumber)),
                    innerRadius: .ratio(0.55),
                    angularInset: 1.5
                )
                .cornerRadius(4)
                .foregroundStyle(colorForCategory(agg.category, at: aggregations.firstIndex(where: { $0.id == agg.id }) ?? 0))
                .opacity(selectedCategory == nil || selectedCategory?.id == agg.category.id ? 1 : 0.3)
            }
            .frame(height: 240)
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

                                    let dx = location.x - center.x
                                    let dy = location.y - center.y
                                    let distance = sqrt(dx * dx + dy * dy)
                                    let radius = min(geometry.size.width, geometry.size.height) / 2

                                    if distance > radius * 0.55 && distance < radius {
                                        var angle = atan2(dy, dx) * 180 / .pi
                                        if angle < 0 { angle += 360 }

                                        let total = aggregations.reduce(0.0) { $0 + Double(truncating: $1.amount as NSDecimalNumber) }
                                        var currentAngle = -90.0

                                        for agg in aggregations {
                                            let sectorAngle = (Double(truncating: agg.amount as NSDecimalNumber) / total) * 360
                                            if angle >= currentAngle && angle < currentAngle + sectorAngle {
                                                withAnimation(.easeInOut(duration: 0.2)) {
                                                    onSelectCategory?(agg.category)
                                                }
                                                return
                                            }
                                            currentAngle += sectorAngle
                                        }
                                    }
                                }
                        )
                }
            }

            // 中心信息
            centerInfo
        }
    }

    // MARK: - 中心信息

    private var centerInfo: some View {
        VStack(spacing: HoloSpacing.xs) {
            if let agg = selectedAggregation {
                // 分类图标
                ZStack {
                    Circle()
                        .fill(agg.category.swiftUIColor.opacity(0.15))
                        .frame(width: 44, height: 44)

                    transactionCategoryIcon(agg.category, size: 22)
                }
                .transition(.scale.combined(with: .opacity))

                // 分类名称
                Text(agg.category.name)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                    .transition(.opacity)

                // 占比
                Text(agg.formattedPercentage)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(agg.category.swiftUIColor)
                    .transition(.scale.combined(with: .opacity))

                // 金额
                Text(agg.formattedAmount)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .transition(.opacity)
            } else {
                // 显示总计
                Text("总计")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                Text(NumberFormatter.currency.string(from: totalAmount as NSDecimalNumber) ?? "¥0")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.holoTextPrimary)

                Text("\(aggregations.count) 个分类")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedCategory)
        .frame(width: 120)
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
        .frame(height: 240)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 辅助方法

    private func colorForCategory(_ category: Category, at index: Int) -> Color {
        chartColors[index % chartColors.count]
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
