//
//  MacQuadrantDragPreview.swift
//  HoloMac
//
//  拖拽跟手影像（与 iOS TaskQuadrantDragPreview 同语言）：3pt 原格象限色竖条
//  + 标题轻卡，不截图整卡——拖的是「这件事」，不是卡片皮肤。
//

import SwiftUI

struct MacQuadrantDragPreview: View {
    let title: String
    /// 原格象限色（待整理池用次级文字色）
    let sourceTint: Color

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(sourceTint)
                .frame(width: 3, height: 28)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.holoTextPrimary)
                .lineLimit(2)
                .frame(width: 210, alignment: .leading)
        }
        .padding(10)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }
}
