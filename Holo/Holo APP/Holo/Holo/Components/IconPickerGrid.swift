//
//  IconPickerGrid.swift
//  Holo
//
//  图标网格选择组件
//  展示预设 SF Symbol 图标，4 列网格布局，单选模式
//

import SwiftUI

// MARK: - 预设图标列表

/// 所有预设分类图标名称（SF Symbol）
let presetCategoryIcons: [String] = [
    // 餐饮类
    "fork.knife", "sunrise.fill", "sun.max.fill", "moon.stars.fill",
    "moonphase.waning.crescent", "popcorn.fill", "cup.and.saucer.fill",
    "bag.fill", "wineglass.fill", "carrot.fill", "wineglass", "cart.fill",

    // 交通类
    "car.fill", "train.side.front.car", "car.side.fill", "fuelpump.fill",
    "parkingsign.circle.fill", "building.columns.fill", "bicycle",
    "airplane", "figure.walk", "bus.fill", "train.side.rear.car", "airplane.departure",

    // 购物类
    "hanger", "desktopcomputer", "basket.fill", "sparkles",
    "sofa.fill", "book.fill", "sportscourt.fill", "gift.fill",

    // 娱乐类
    "music.note.list", "film.fill", "mic.fill", "gamecontroller.fill",
    "play.tv.fill", "figure.run",

    // 居住类
    "house.fill", "key.fill", "building.2.fill", "drop.fill",
    "bolt.fill", "flame.fill", "wifi", "wrench.fill",
    "banknote.fill", "tv.fill", "paintbrush.fill",

    // 医疗类
    "heart.text.square.fill", "stethoscope", "pill.fill",
    "leaf.fill", "heart.circle.fill", "cross.case.fill", "dumbbell.fill",

    // 学习类
    "book.closed.fill", "text.book.closed.fill", "checkmark.rectangle.fill",

    // 人情类
    "yensign.circle.fill", "figure.walk.arrival", "ellipsis.circle.fill",

    // 社交类
    "person.2.fill", "heart.fill",
    "trophy.fill",

    // 投资理财类（收入）
    "percent", "star.fill", "chart.line.uptrend.xyaxis",
    "chart.pie.fill", "briefcase.fill",
    "arrow.uturn.backward.circle.fill", "arrow.counterclockwise.circle.fill",

    // 其他收入
    "arrow.left.circle.fill", "arrow.down.circle.fill",
    "arrow.uturn.forward.circle.fill", "shippingbox.fill",
    "arrow.3.trianglepath", "plus.circle.fill",

    // 其他支出
    "pawprint.fill", "scissors", "washer.fill",
    "phone.fill", "smoke.fill", "shield.checkered",
    "arrow.right.circle.fill", "questionmark.folder.fill",
    "pencil.line", "arrow.trianglehead.clockwise"
]

// MARK: - Icon Picker Grid

/// 图标网格选择器
struct IconPickerGrid: View {

    // MARK: - Properties

    /// 当前选中的图标名称
    @Binding var selectedIcon: String

    /// 4 列网格布局
    private let gridColumns = Array(
        repeating: GridItem(.flexible(), spacing: 16),
        count: 4
    )

    // MARK: - Body

    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: 16) {
            ForEach(presetCategoryIcons, id: \.self) { iconName in
                iconCell(iconName)
            }
        }
    }

    // MARK: - Private Views

    @ViewBuilder
    private func iconCell(_ iconName: String) -> some View {
        let isSelected = selectedIcon == iconName

        ZStack {
            Circle()
                .fill(isSelected ? Color.holoPrimary.opacity(0.15) : Color.holoCardBackground)
                .frame(width: 64, height: 64)

            Image(systemName: iconName)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)

            if isSelected {
                Circle()
                    .strokeBorder(Color.holoPrimary, lineWidth: 2)
                    .frame(width: 64, height: 64)
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedIcon = iconName
            }
        }
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State var selectedIcon = "fork.knife"

        var body: some View {
            ScrollView {
                VStack(spacing: 16) {
                    Text("选中: \(selectedIcon)")
                        .font(.holoBody)

                    IconPickerGrid(selectedIcon: $selectedIcon)
                        .padding()
                }
            }
            .background(Color.holoBackground)
        }
    }

    return PreviewWrapper()
}
