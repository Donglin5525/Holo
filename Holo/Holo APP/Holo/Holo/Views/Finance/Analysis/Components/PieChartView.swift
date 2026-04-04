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
    }

    // MARK: - 图表带中心信息

    private var chartWithCenter: some View {
        ZStack {
            // 饼图
            Chart(aggregations) { agg in
                let index = aggregations.firstIndex(where: { $0.id == agg.id }) ?? 0
                SectorMark(
                    angle: .value("金额", Double(truncating: agg.amount as NSDecimalNumber)),
                    innerRadius: .ratio(0.55),
                    angularInset: 1.5
                )
                .cornerRadius(4)
                .foregroundStyle(colorForCategory(agg.category, at: index))
                .opacity(selectedCategory == nil || selectedCategory?.id == agg.category.id ? 1 : 0.3)
                .annotation(position: .overlay, alignment: .center) {
                    if agg.percentage >= 5 {
                        VStack(spacing: 1) {
                            Text(agg.category.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                            Text(agg.formattedPercentage)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
                                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                        }
                    }
                }
            }
            .frame(height: 240)
            .chartOverlay { _ in
                PieChartInteractionOverlay(
                    aggregations: aggregations,
                    onSelect: { category in
                        onSelectCategory?(category)
                    }
                )
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

// MARK: - Pie Chart Interaction Overlay (UIViewRepresentable)

/// 饼图交互覆盖层 - 使用 UIKit 手势识别器解决 ScrollView 手势冲突
/// 遵循项目规范：ScrollView 内自定义手势必须用 UIViewRepresentable + UIPanGestureRecognizer
struct PieChartInteractionOverlay: UIViewRepresentable {
    let aggregations: [CategoryAggregation]
    let onSelect: (Category?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.aggregations = aggregations

        let panGesture = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleGesture(_:))
        )
        panGesture.cancelsTouchesInView = false
        panGesture.delegate = context.coordinator
        view.addGestureRecognizer(panGesture)

        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleGesture(_:))
        )
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = context.coordinator
        view.addGestureRecognizer(tapGesture)

        return view
    }

    func updateUIView(_ uiView: InteractionView, context: Context) {
        uiView.aggregations = aggregations
        context.coordinator.parent = self
    }

    // MARK: - Interaction View

    class InteractionView: UIView {
        var aggregations: [CategoryAggregation] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = true
        }

        required init?(coder: NSCoder) { fatalError() }

        /// 只处理环形区域的触摸，其他区域放行给 ScrollView
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let dx = point.x - center.x
            let dy = point.y - center.y
            let distance = sqrt(dx * dx + dy * dy)
            let radius = min(bounds.width, bounds.height) / 2
            return distance > radius * 0.45 && distance < radius * 1.05
        }

        /// 根据触摸点计算对应的分类
        func categoryAtPoint(_ point: CGPoint) -> Category? {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let dx = point.x - center.x
            let dy = point.y - center.y
            let distance = sqrt(dx * dx + dy * dy)
            let radius = min(bounds.width, bounds.height) / 2

            guard distance > radius * 0.55 && distance < radius else { return nil }

            var angle = atan2(dy, dx) * 180 / .pi
            if angle < 0 { angle += 360 }

            let total = aggregations.reduce(0.0) { $0 + Double(truncating: $1.amount as NSDecimalNumber) }
            guard total > 0 else { return nil }

            var currentAngle = -90.0
            for agg in aggregations {
                let sectorAngle = (Double(truncating: agg.amount as NSDecimalNumber) / total) * 360
                if angle >= currentAngle && angle < currentAngle + sectorAngle {
                    return agg.category
                }
                currentAngle += sectorAngle
            }
            return nil
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PieChartInteractionOverlay

        init(_ parent: PieChartInteractionOverlay) {
            self.parent = parent
        }

        @objc func handleGesture(_ gesture: UIGestureRecognizer) {
            guard let view = gesture.view as? InteractionView else { return }
            let location = gesture.location(in: view)
            let category = view.categoryAtPoint(location)
            withAnimation(.easeInOut(duration: 0.2)) {
                parent.onSelect(category)
            }
        }

        /// 允许与 ScrollView 手势同时识别
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            return true
        }
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
