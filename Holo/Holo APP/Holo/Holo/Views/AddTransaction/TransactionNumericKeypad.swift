//
//  TransactionNumericKeypad.swift
//  Holo
//
//  AddTransactionSheet 数字键盘：通用组件薄壳（键盘本体与求值见 HoloAmountKeypad）
//  + 托盘顶排条（运算符小 chip + 快捷金额横滑，2026-11-09 空间优化：托盘 350→240pt）
//

import SwiftUI

// MARK: - 键盘视图

extension AddTransactionSheet {

    /// 数字键盘：✓ = 算式求值成结果 / 纯数字确认保存（两段式见 HoloAmountKeypad）；↩︎ = 收键盘跳名称输入
    /// 瘦身态：运算符不占键身，由 keypadTopRow 的小 chip 输入
    var numericKeypad: some View {
        HoloAmountKeypad(
            amountText: $amountString,
            onConfirm: {
                saveTransaction()
            },
            onNext: {
                showNumericKeypad = false
                isNoteFocused = true
            },
            operatorsInTray: true
        )
    }

    /// 托盘顶排条（36pt）：左端 ÷×－+ 运算符 chip，分隔线，右接快捷金额横滑
    /// 不自带底色（与托盘同色），托盘以背景形状画圆角而不裁剪，chip 外扩命中区才不被裁掉
    var keypadTopRow: some View {
        HStack(spacing: 8) {
            ForEach(HoloAmountKeypad.operatorRow, id: \.self) { op in
                keypadOperatorChip(op)
            }

            Rectangle()
                .fill(Color.holoBorder)
                .frame(width: 0.5, height: 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(amountTags) { tag in
                        QuickTagChip(item: tag) {
                            handleQuickTagTap(value: tag.value, kind: tag.kind)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .overlay(alignment: .top) {
            // 顶部细线避开托盘 24pt 圆角，不戳出圆角外
            Rectangle()
                .fill(Color.holoBorder.opacity(0.55))
                .frame(height: 0.5)
                .padding(.horizontal, HoloRadius.xl)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    /// 运算符小 chip：视觉 28 高（最小宽 36 含内边距），命中区四向外扩 8pt：
    /// 竖向 28+16=44（上沿外扩 4pt 落在托盘外、下沿止于首行键帽顶，不与键帽重叠），
    /// 横向相邻 chip 外扩区在 8pt 间隙内重叠、后者优先，每个 chip 有效命中宽 ≥44
    /// 输入规则与键身运算符完全一致（HoloAmountKeypad.appendOperator 单一来源）
    private func keypadOperatorChip(_ op: String) -> some View {
        Button {
            HapticManager.light()
            amountString = HoloAmountKeypad.appendOperator(op, to: amountString)
        } label: {
            // 逻辑键是半角 "-"（AmountMath 识别），显示用全角减号与原型字形一致
            Text(op == "-" ? "−" : op)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.holoToolTextSecondary)
                .padding(.horizontal, 12)
                .frame(minWidth: 36)
                .frame(height: 28)
                .background(Capsule().fill(Color.holoToolInset))
                .contentShape(Rectangle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("keypad.\(op)")
    }

}
