//
//  MonthYearPickerView.swift
//  Holo
//
//  年月滚轮选择器 — 双 Picker 联动（年 + 月），
//  用于在月历中快速跳转到任意历史月份
//

import SwiftUI

// MARK: - MonthYearPickerView

/// 年月滚轮选择器
/// - Parameters:
///   - selectedYear: 当前选中的年份
///   - selectedMonth: 当前选中的月份（1~12）
///   - onConfirm: 确认回调，传出 (year, month)
///   - onCancel: 取消回调
struct MonthYearPickerView: View {
    
    @State private var pickerYear: Int
    @State private var pickerMonth: Int
    
    let onConfirm: (Int, Int) -> Void
    let onCancel: () -> Void
    
    /// 年份范围：当前年份往前 10 年 ~ 当前年份往后 1 年
    private let yearRange: [Int] = {
        let currentYear = Calendar.current.component(.year, from: Date())
        return Array((currentYear - 10)...(currentYear + 1))
    }()
    
    /// 月份范围 1~12
    private let monthRange = Array(1...12)
    
    // MARK: - Init
    
    init(currentYear: Int, currentMonth: Int,
         onConfirm: @escaping (Int, Int) -> Void,
         onCancel: @escaping () -> Void) {
        _pickerYear = State(initialValue: currentYear)
        _pickerMonth = State(initialValue: currentMonth)
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏：取消 + 标题 + 确认
            HStack {
                Button("取消") { onCancel() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                
                Spacer()
                
                Text("选择月份")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
                
                Spacer()
                
                Button("确认") { onConfirm(pickerYear, pickerMonth) }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoPrimary)
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, 14)
            
            Divider()
            
            // 双滚轮：年 + 月
            HStack(spacing: 0) {
                // 年份滚轮
                Picker("年份", selection: $pickerYear) {
                    ForEach(yearRange, id: \.self) { year in
                        Text("\(String(year))年")
                            .tag(year)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .clipped()
                
                // 月份滚轮
                Picker("月份", selection: $pickerMonth) {
                    ForEach(monthRange, id: \.self) { month in
                        Text("\(month)月")
                            .tag(month)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .clipped()
            }
            .frame(height: 200)
            .padding(.horizontal, HoloSpacing.md)
        }
        .background(Color.holoBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
