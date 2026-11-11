//
//  ReceiptReviewChipField.swift
//  Holo
//
//  复核确认页 · 2×2 宫格字段 chip（2026-11-11 重设计，原型画板①②）：
//  SF Symbol + 标签 + 值 + 上下选择箭头，44pt 高、内嵌容器圆角 10。
//  纯视觉容器——科目/账户/项目的 Menu 与日期的 Button 由调用方按字段包在 外面，
//  组件不关心交互方式。
//

import SwiftUI

struct ReceiptReviewChipField: View {
    /// SF Symbol 名（科目 tag / 账户 creditcard / 项目 folder / 日期 calendar）
    let icon: String
    /// 字段标签（科目/账户/项目/日期），LocalizedStringKey 走既有词条
    let label: LocalizedStringKey
    /// 当前值（空值文案由调用方按现状口径给：正在匹配科目…/自动识别/不挂项目）
    let value: String
    /// 收入笔项目等不可编辑态：整格 opacity 0.5、无箭头
    var dimmed: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            // 四个图标统一灰色线性样式（原型契约）；Menu label 会把模板色染成主题橙，
            // foregroundColor 才钉得住（foregroundStyle 会被 Menu tint 覆盖，判读实测）
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
            Text(label)
                .font(.caption2)
                .foregroundColor(.holoTextSecondary)
                .fixedSize()
            Text(value)
                .font(.footnote.weight(.semibold))
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if !dimmed {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundColor(Color.holoTextPlaceholder)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.holoSystemGray6)
        )
        .opacity(dimmed ? 0.5 : 1)
    }
}
