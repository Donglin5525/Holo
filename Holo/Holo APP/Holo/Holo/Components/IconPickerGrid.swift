//
//  IconPickerGrid.swift
//  Holo
//
//  图标网格选择组件
//  展示 82 个预设图标，4 列网格布局，单选模式
//

import SwiftUI

// MARK: - 预设图标列表

/// 所有预设分类图标名称（105 个）
let presetCategoryIcons: [String] = [
    // 餐饮类
    "icon_breakfast", "icon_lunch", "icon_dinner", "icon_snack",
    "icon_late_snack", "icon_takeout", "icon_dining", "icon_coffee",
    "icon_beverage", "icon_fruit", "icon_alcohol", "icon_supermarket",

    // 交通类
    "icon_transport", "icon_metro", "icon_taxi", "icon_fuel",
    "icon_parking", "icon_toll", "icon_bike_share", "icon_trip", "icon_travel",
    "icon_bus", "icon_train", "icon_flight",

    // 购物类
    "icon_shopping", "icon_groceries", "icon_clothes", "icon_digital",
    "icon_furniture", "icon_stationery", "icon_book", "icon_textbook",

    // 娱乐类
    "icon_entertainment", "icon_cinema", "icon_ktv", "icon_gaming",
    "icon_music", "icon_video", "icon_sport", "icon_fitness", "icon_gym",

    // 居住类
    "icon_housing", "icon_rent", "icon_property", "icon_water",
    "icon_electricity", "icon_gas", "icon_internet", "icon_repair",
    "icon_mortgage", "icon_appliance", "icon_renovation",

    // 医疗类
    "icon_health", "icon_medical", "icon_medicine", "icon_checkup",
    "icon_supplement", "icon_dental", "icon_medical_supply",

    // 学习类
    "icon_education", "icon_course", "icon_exam",

    // 人情类
    "icon_cash_gift", "icon_treat", "icon_gifting", "icon_visit", "icon_social_other",

    // 社交类
    "icon_social", "icon_gift", "icon_present", "icon_donation",
    "icon_red_packet",

    // 投资理财类（收入）
    "icon_salary", "icon_bonus", "icon_interest", "icon_stock",
    "icon_investment", "icon_invest_other", "icon_rent_income",
    "icon_return", "icon_winning", "icon_refund",

    // 其他收入
    "icon_parttime", "icon_loan_in", "icon_repay_in", "icon_transfer_in",
    "icon_other_income", "icon_other_inc", "icon_reimburse", "icon_housing_fund", "icon_secondhand",

    // 其他支出
    "icon_other_expense", "icon_other_exp", "icon_transfer_out",
    "icon_repayment", "icon_subscription", "icon_insurance",
    "icon_pet", "icon_beauty", "icon_barber", "icon_laundry",
    "icon_communication", "icon_phone_bill", "icon_tobacco_alcohol"
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

            Image(iconName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
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
        @State var selectedIcon = "icon_dining"

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
