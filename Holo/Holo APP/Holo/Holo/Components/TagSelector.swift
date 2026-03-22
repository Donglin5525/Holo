//
//  TagSelector.swift
//  Holo
//
//  标签选择器组件
//  提供预设标签列表，支持多选
//

import SwiftUI

/// 标签选择器视图
struct TagSelector: View {
    
    // MARK: - Properties
    
    /// 选中的标签
    @Binding var selectedTags: [String]
    
    /// 预设标签列表
    private let presetTags = [
        "早餐", "午餐", "晚餐",
        "地铁", "公交", "打车",
        "超市", "网购",
        "电影", "游戏", "聚会",
        "工资", "奖金", "兼职"
    ]
    
    // MARK: - Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 标题
            Text("标签")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            
            // 已选标签
            if !selectedTags.isEmpty {
                FlowLayout(spacing: HoloSpacing.sm) {
                    ForEach(selectedTags, id: \.self) { tag in
                        TagChip(
                            text: tag,
                            isSelected: true,
                            onTap: {
                                selectedTags.removeAll { $0 == tag }
                            }
                        )
                    }
                }
            }
            
            // 预设标签网格
            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ],
                spacing: HoloSpacing.sm
            ) {
                ForEach(presetTags.filter { !selectedTags.contains($0) }, id: \.self) { tag in
                    TagChip(
                        text: tag,
                        isSelected: false,
                        onTap: {
                            selectedTags.append(tag)
                        }
                    )
                }
            }
        }
        .padding(HoloSpacing.md)
    }
}

/// 标签芯片组件
struct TagChip: View {

    // MARK: - Properties

    /// 标签文字
    let text: String

    /// 是否选中
    let isSelected: Bool

    /// 自定义颜色（选中时使用）
    var color: Color = .holoPrimary

    /// 点击回调
    let onTap: () -> Void

    // MARK: - Body

    var body: some View {
        Button(action: onTap) {
            Text(text)
                .font(.holoLabel)
                .foregroundColor(isSelected ? .white : .holoTextPrimary)
                .padding(.horizontal, HoloSpacing.sm)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? color : Color.holoGlassBackground)
                        .overlay(
                            Capsule()
                                .stroke(isSelected ? Color.clear : Color.holoBorder, lineWidth: 1)
                        )
                )
        }
    }
}

// MARK: - Flow Layout

/// 流式布局容器
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                       y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if x + size.width > maxWidth && x > 0 {
                    // 换行
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
            }
            
            self.size = CGSize(width: maxWidth, height: y + rowHeight)
        }
    }
}

// MARK: - Preview

#Preview {
    TagSelector(selectedTags: .constant(["早餐", "地铁"]))
}
