//
//  UnifiedIconPicker.swift
//  Holo
//
//  用户自建实体统一图标选择器（习惯/财务项目/记账分类共用）。
//  - UnifiedIconGrid：双页签网格内容（经典单色精选 + Emoji 库），可直接嵌入 Form 或弹层
//  - UnifiedIconPickerSheet：sheet 弹层壳，选完即关；footer 插槽供模块附加常驻内容（如习惯色点行）
//  经典页磁贴 52pt + 标签，整体热区 ≥ 44pt；当前图标不在精选集且非 emoji 时顶部单独展示（存量兜底）
//

import SwiftUI

// MARK: - 网格内容

struct UnifiedIconGrid: View {

    /// 当前已选图标（传实际展示值，用于高亮与页签落点）
    var currentIcon: String

    /// 选中回调；是否关闭容器由调用方决定
    let onSelect: (String) -> Void

    /// Emoji 页最大高度。嵌入 Form/List 行时必须给定（行对 ScrollView 的高度提议无界，
    /// 几千个 emoji 会被全量展开渲染）；放在 sheet 壳等有界容器里传 nil 即可
    var emojiPaneMaxHeight: CGFloat? = nil

    enum PickerTab: String, CaseIterable, Identifiable {
        case classic
        case emoji = "Emoji"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .classic: String(localized: "经典")
            case .emoji: "Emoji"
            }
        }
    }

    @State private var tab: PickerTab

    init(currentIcon: String, emojiPaneMaxHeight: CGFloat? = nil, onSelect: @escaping (String) -> Void) {
        self.currentIcon = currentIcon
        self.emojiPaneMaxHeight = emojiPaneMaxHeight
        self.onSelect = onSelect
        self._tab = State(initialValue: EmojiCatalog.isEmojiIcon(currentIcon) ? .emoji : .classic)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)

    /// 当前图标既不是 emoji 也不在精选集（存量 SF Symbol / 历史资产），顶部单独展示避免「看不见自己选了什么」
    private var needsFallback: Bool {
        !currentIcon.isEmpty
            && !EmojiCatalog.isEmojiIcon(currentIcon)
            && !UnifiedIconCatalog.contains(currentIcon)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("图标类型", selection: $tab) {
                ForEach(PickerTab.allCases) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)

            if tab == .emoji {
                if let maxHeight = emojiPaneMaxHeight {
                    // 限高嵌入场景：底部渐隐提示下方还能滚，否则最后一行磁贴被拦腰裁切像到底了
                    emojiGrid
                        .frame(maxHeight: maxHeight)
                        .mask(
                            VStack(spacing: 0) {
                                Rectangle()
                                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 28)
                            }
                        )
                } else {
                    emojiGrid
                }
            } else {
                classicGrid
            }
        }
    }

    private var emojiGrid: some View {
        EmojiCatalogGrid(currentIcon: currentIcon) { emoji in
            onSelect(emoji)
        }
    }

    // MARK: 经典页

    private var classicGrid: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: HoloSpacing.xl, pinnedViews: []) {
                if needsFallback {
                    VStack(alignment: .leading, spacing: HoloSpacing.md) {
                        sectionHeader(title: String(localized: "当前图标"), icon: "circle.dashed")
                        LazyVGrid(columns: columns, spacing: 10) {
                            iconCell(name: currentIcon, label: String(localized: "当前"), isAsset: UnifiedIconCatalog.isAssetIcon(currentIcon))
                        }
                    }
                }

                ForEach(UnifiedIconCatalog.sections) { section in
                    VStack(alignment: .leading, spacing: HoloSpacing.md) {
                        sectionHeader(title: section.title, icon: section.icon)
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(section.items) { item in
                                iconCell(name: item.name, label: item.label, isAsset: item.isAsset)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.md)
        }
    }

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.holoPrimary)
            Text(title)
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
        }
    }

    private func iconCell(name: String, label: String, isAsset: Bool) -> some View {
        let isSelected = currentIcon == name
        return Button {
            onSelect(name)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .fill(isSelected ? Color.holoPrimary.opacity(0.14) : Color.holoCardBackground)
                        .frame(width: 52, height: 52)

                    entityIconGlyph(name, size: 22, color: isSelected ? .holoPrimary : .holoTextPrimary)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .stroke(isSelected ? Color.holoPrimary : Color.holoBorder, lineWidth: isSelected ? 2 : 1)
                )

                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - 弹层壳

/// 图标选择 sheet：选中即回调并关闭；`footer` 为常驻底部区（如习惯的 12 色点行），默认无
struct UnifiedIconPickerSheet<Footer: View>: View {

    var currentIcon: String
    let onSelect: (String) -> Void
    @ViewBuilder let footer: () -> Footer

    @Environment(\.dismiss) private var dismiss

    init(
        currentIcon: String,
        onSelect: @escaping (String) -> Void,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.currentIcon = currentIcon
        self.onSelect = onSelect
        self.footer = footer
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                UnifiedIconGrid(currentIcon: currentIcon) { icon in
                    onSelect(icon)
                    dismiss()
                }
                footer()
            }
            .background(Color.holoToolBackground)
            .navigationTitle("选择图标")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                    .accessibilityLabel(Text("关闭"))
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

extension UnifiedIconPickerSheet where Footer == EmptyView {
    init(currentIcon: String, onSelect: @escaping (String) -> Void) {
        self.init(currentIcon: currentIcon, onSelect: onSelect) { EmptyView() }
    }
}

#Preview {
    UnifiedIconPickerSheet(currentIcon: "figure.run") { _ in }
}
