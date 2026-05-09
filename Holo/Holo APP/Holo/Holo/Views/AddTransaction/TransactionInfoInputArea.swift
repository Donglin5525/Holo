//
//  TransactionInfoInputArea.swift
//  Holo
//
//  AddTransactionSheet 信息输入区 — 列表式行（账户/日期/分期）+ 备注大文本框
//

import SwiftUI
import CoreData

// MARK: - 信息输入区

extension AddTransactionSheet {

    /// 信息输入区（V3：弹窗式选择 + 固定备注框）
    var infoInputArea: some View {
        VStack(spacing: 0) {
            // 账户行（点击弹窗选择）
            accountRow

            Divider().padding(.leading, 44)

            // 日期行（点击弹窗选择）
            dateRow

            // 分期设置（仅新增模式，点击弹窗）
            if !isEditMode {
                Divider().padding(.leading, 44)
                installmentRow
            }

            Divider().padding(.leading, 44)

            // 补充备注（始终可见的大文本框）
            remarkSection
        }
        .padding(.vertical, 4)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    // MARK: - 账户选择行

    /// 账户选择行（点击弹窗）
    private var accountRow: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                showAccountPicker = true
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedAccount?.icon ?? "wallet.pass")
                    .font(.system(size: 18))
                    .foregroundColor(selectedAccount?.swiftUIColor ?? .green)
                    .frame(width: 24)

                Text("账户")
                    .font(.system(size: 15))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 36, alignment: .leading)

                Spacer()

                HStack(spacing: 4) {
                    Text(selectedAccount?.name ?? "默认账户")
                        .font(.system(size: 15))
                        .foregroundColor(.holoTextPrimary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.holoTextSecondary.opacity(0.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 日期选择行

    /// 日期选择行（点击弹窗）
    private var dateRow: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                showDatePicker = true
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 18))
                    .foregroundColor(.purple)
                    .frame(width: 24)

                Text("日期")
                    .font(.system(size: 15))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 36, alignment: .leading)

                Spacer()

                HStack(spacing: 4) {
                    Text(formattedSelectedDate)
                        .font(.system(size: 15))
                        .foregroundColor(.holoTextPrimary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.holoTextSecondary.opacity(0.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分期设置行

    /// 分期设置行（点击弹窗）
    private var installmentRow: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                showInstallmentSheet = true
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "repeat")
                    .font(.system(size: 18))
                    .foregroundColor(.orange)
                    .frame(width: 24)

                Text("分期")
                    .font(.system(size: 15))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 36, alignment: .leading)

                Spacer()

                HStack(spacing: 4) {
                    if isInstallment {
                        Text("\(installmentPeriods)期")
                            .font(.system(size: 15))
                            .foregroundColor(.holoPrimary)
                    } else {
                        Text("未设置")
                            .font(.system(size: 15))
                            .foregroundColor(.holoTextSecondary.opacity(0.5))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.holoTextSecondary.opacity(0.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 备注大文本框

    /// 补充备注（始终可见的大文本框）
    private var remarkSection: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "note.text")
                    .font(.system(size: 18))
                    .foregroundColor(.orange)
                    .frame(width: 24)

                Text("备注")
                    .font(.system(size: 15))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 36, alignment: .leading)

                Spacer()
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $remark)
                    .font(.system(size: 15))
                    .focused($isRemarkFocused)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)

                if remark.isEmpty {
                    Text("添加补充备注（选填）...")
                        .font(.system(size: 15))
                        .foregroundColor(.holoTextSecondary.opacity(0.5))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .padding(12)
            .background(Color.holoBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - 分期详情设置（弹窗中使用）

    /// 分期详情设置
    var installmentDetailSection: some View {
        VStack(spacing: HoloSpacing.md) {
            // 期数快捷选择
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text("期数")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                HStack(spacing: HoloSpacing.sm) {
                    ForEach([3, 6, 12, 24], id: \.self) { period in
                        Button {
                            installmentPeriods = period
                            showCustomPeriods = false
                        } label: {
                            Text("\(period)期")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(
                                    !showCustomPeriods && installmentPeriods == period
                                        ? .white : .holoTextPrimary
                                )
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    !showCustomPeriods && installmentPeriods == period
                                        ? Color.holoPrimary : Color.holoBackground
                                )
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        showCustomPeriods = true
                    } label: {
                        if showCustomPeriods {
                            HStack(spacing: 2) {
                                TextField("", text: $customPeriodsText)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                                    .keyboardType(.numberPad)
                                    .frame(width: 30)
                                    .multilineTextAlignment(.center)
                                    .onChange(of: customPeriodsText) { _, newValue in
                                        if let val = Int(newValue), val > 0 {
                                            installmentPeriods = val
                                        }
                                    }
                                Text("期")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.holoPrimary)
                            .clipShape(Capsule())
                        } else {
                            Text("自定义")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.holoTextSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.holoBackground)
                                .clipShape(Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // 每期手续费
            HStack(spacing: HoloSpacing.sm) {
                Text("手续费")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                HStack(spacing: 4) {
                    Text("¥")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)
                    TextField("0.00", text: $feePerPeriod)
                        .font(.holoBody)
                        .keyboardType(.decimalPad)
                        .frame(width: 80)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.holoBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))

                Text("/每期")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                Spacer()
            }

            Divider()

            // 实时计算预览
            installmentPreview
        }
        .padding(.horizontal, 16)
        .padding(.bottom, HoloSpacing.md)
    }

    /// 分期预览信息
    private var installmentPreview: some View {
        let totalAmount = Decimal(string: displayAmountString) ?? 0
        let fee = Decimal(string: feePerPeriod) ?? 0
        let periods = max(installmentPeriods, 1)
        let perPeriod = totalAmount / Decimal(periods) + fee
        let totalFee = fee * Decimal(periods)
        let totalCost = totalAmount + totalFee

        return VStack(spacing: HoloSpacing.xs) {
            installmentPreviewRow(label: "每期金额", value: formatPreviewAmount(perPeriod))
            installmentPreviewRow(label: "总手续费", value: formatPreviewAmount(totalFee))
            installmentPreviewRow(label: "实际总支出", value: formatPreviewAmount(totalCost))
        }
    }

    private func installmentPreviewRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
        }
    }

    private func formatPreviewAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter.currency
        return formatter.string(from: amount as NSDecimalNumber) ?? "¥0.00"
    }

    /// 格式化的日期显示文字
    private var formattedSelectedDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        let text = f.string(from: selectedDate)
        if selectedDate.isToday { return "\(text)（今天）" }
        return text
    }

    // MARK: - 弹窗视图

    /// 账户选择弹窗
    var accountPopup: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showAccountPicker = false
                    }
                }

            VStack(spacing: 0) {
                Text("选择账户")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                ScrollView(showsIndicators: false) {
                    ForEach(accounts, id: \.objectID) { account in
                        Button {
                            selectedAccount = account
                            lastSelectedAccountId = account.id.uuidString
                            withAnimation(.easeOut(duration: 0.2)) {
                                showAccountPicker = false
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: account.icon)
                                    .font(.system(size: 16))
                                    .foregroundColor(account.swiftUIColor)
                                    .frame(width: 24)

                                Text(account.name)
                                    .font(.system(size: 15))
                                    .foregroundColor(.holoTextPrimary)

                                Spacer()

                                if selectedAccount?.objectID == account.objectID {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.holoPrimary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxHeight: 280)

                Divider()

                Button("取消") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showAccountPicker = false
                    }
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.holoTextSecondary)
                .padding(.vertical, 14)
            }
            .frame(maxWidth: 320)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
        }
        .transition(.opacity)
    }

    /// 日期选择弹窗
    var datePopup: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showDatePicker = false
                    }
                }

            VStack(spacing: 0) {
                Text("选择日期")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .padding(.top, 20)
                    .padding(.bottom, 8)

                DatePicker(
                    "",
                    selection: $selectedDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .padding(.horizontal, 16)

                Divider()

                Button("完成") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showDatePicker = false
                    }
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.holoPrimary)
                .padding(.vertical, 14)
            }
            .frame(maxWidth: 340)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
        }
        .transition(.opacity)
    }

    /// 分期设置弹窗
    var installmentPopup: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showInstallmentSheet = false
                    }
                }

            VStack(spacing: 0) {
                Text("分期设置")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .padding(.top, 20)
                    .padding(.bottom, 8)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        Toggle(isOn: $isInstallment) {
                            Text("启用分期")
                                .font(.system(size: 15, weight: .medium))
                        }
                        .padding(.horizontal, 16)

                        if isInstallment {
                            installmentDetailSection
                        }
                    }
                }
                .frame(maxHeight: 400)

                Divider()

                Button("完成") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showInstallmentSheet = false
                    }
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.holoPrimary)
                .padding(.vertical, 14)
            }
            .frame(maxWidth: 340)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
        }
        .transition(.opacity)
    }
}
