//
//  IconPickerGrid.swift
//  Holo
//
//  图标网格选择组件
//  按展示分组渲染分类图标，4 列网格布局，单选模式
//  支持历史图标 fallback 展示
//

import SwiftUI

// MARK: - Icon Picker Grid

/// 图标网格选择器 — 按 section 分组展示
/// 「经典」页为原单色图标目录，「Emoji」页为全 App 通用 emoji 库
struct IconPickerGrid: View {

    // MARK: - Properties

    /// 当前选中的图标名称
    @Binding var selectedIcon: String

    enum IconTab: String, CaseIterable, Identifiable {
        case classic = "经典"
        case emoji = "Emoji"
        var id: String { rawValue }
    }

    @State private var tab: IconTab

    init(selectedIcon: Binding<String>) {
        self._selectedIcon = selectedIcon
        // 当前已是 emoji 时直接落在 Emoji 页
        self._tab = State(initialValue: EmojiCatalog.isEmojiIcon(selectedIcon.wrappedValue) ? .emoji : .classic)
    }

    /// 4 列网格布局
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 16),
        count: 4
    )

    /// 当前选中图标是否不在目录中（需要 fallback section）
    private var needsFallback: Bool {
        !selectedIcon.isEmpty
            && !EmojiCatalog.isEmojiIcon(selectedIcon)
            && !CategoryIconCatalog.contains(selectedIcon)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 12) {
            Picker("图标类型", selection: $tab) {
                ForEach(IconTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            if tab == .emoji {
                EmojiCatalogGrid(currentIcon: selectedIcon) { emoji in
                    selectedIcon = emoji
                }
                .frame(maxHeight: 420)
            } else {
                classicGrid
            }
        }
    }

    @ViewBuilder
    private var classicGrid: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 20) {
                // Fallback: 当前图标不在目录中时，顶部展示
                if needsFallback {
                    sectionHeader("当前图标")
                    iconGrid([selectedIcon])
                }

                // 12 个展示分组
                ForEach(CategoryIconCatalog.sections) { section in
                    sectionHeader(section.title)
                    iconGrid(section.icons)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Private Views

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.holoCaption)
            .foregroundColor(.holoTextSecondary)
            .padding(.leading, 4)
            .padding(.top, 4)
    }

    @ViewBuilder
    private func iconGrid(_ icons: [String]) -> some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(icons, id: \.self) { iconName in
                iconCell(iconName)
            }
        }
    }

    @ViewBuilder
    private func iconCell(_ iconName: String) -> some View {
        let isSelected = selectedIcon == iconName

        ZStack {
            Circle()
                .fill(isSelected ? Color.holoPrimary.opacity(0.15) : Color.holoCardBackground)
                .frame(width: 64, height: 64)

            categoryIconGlyph(
                iconName,
                size: 29,
                color: isSelected ? .holoPrimary : .holoTextSecondary
            )

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
            VStack(spacing: 16) {
                Text("选中: \(selectedIcon)")
                    .font(.holoBody)

                IconPickerGrid(selectedIcon: $selectedIcon)
                    .padding()
            }
            .background(Color.holoBackground)
        }
    }

    return PreviewWrapper()
}
