//
//  ReceiptReviewEvidenceSheet.swift
//  Holo
//
//  复核确认页 · 两个弹层（2026-11-11 重设计，弹层语言照设计规范 §8.8）：
//  原图弹层——原图从页面内嵌块改弹层，看完关掉页面位置不动；
//  日期弹层——日期从常驻控件改「chip 点开弹层」（复核场景日期基本不用改）。
//

import SwiftUI

/// 原图弹层：头部标题 + 左上 X 圆钮 + 内容 ScrollView + 底部暂存脚注，无主按钮
struct ReceiptReviewEvidenceSheet: View {
    let image: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(title: String(localized: "凭证原图"), onClose: { dismiss() })
            ScrollView {
                Group {
                    if let image {
                        #if canImport(UIKit)
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                        #else
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                        #endif
                    }
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            Text("仅在本机暂存，确认或删除后自动清理")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 20)
        }
        .holoSheetShell()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// 日期弹层：头部「记账日期」+ X、graphical 日历、底部「完成」主按钮
struct ReceiptReviewDatePickerSheet: View {
    @Binding var date: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(title: String(localized: "记账日期"), onClose: { dismiss() })
            DatePicker("", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(.horizontal, 16)
            Button {
                dismiss()
            } label: {
                Text("完成")
                    .font(.holoBody.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.holoPrimary)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .holoSheetShell()
        // 图形日历本体 ~330pt + 头部 + 主按钮：320 装不下会裁掉按钮，取实际组合高度
        .presentationDetents([.height(460)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - 弹层头部（标题左对齐 + 右上 X 圆钮）

private func sheetHeader(title: String, onClose: @escaping () -> Void) -> some View {
    HStack(spacing: 12) {
        Text(title)
            .font(.holoHeading)
            .foregroundColor(.holoTextPrimary)
        Spacer()
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.holoSystemGray6))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "关闭")))
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
}
