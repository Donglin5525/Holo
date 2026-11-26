//
//  SpendingProjectAppearancePicker.swift
//  Holo
//
//  四合一融合外观选择器：品牌 | 贴纸 | Emoji | 经典图标
//  支持常用订阅品牌原色图标（36 个，含关键词搜索）、抠图贴纸、Emoji 与 Holo 经典单色图标平权切换。
//

import SwiftUI

struct SpendingProjectAppearancePicker: View {
    enum AppearanceTab: String, CaseIterable, Identifiable {
        case brand
        case sticker
        case emoji
        case classic

        var id: String { rawValue }
        var title: String {
            switch self {
            case .brand: String(localized: "品牌")
            case .sticker: String(localized: "贴纸")
            case .emoji: "Emoji"
            case .classic: String(localized: "经典")
            }
        }
    }

    var currentPlacement: ResolvedPlacement = .none
    var currentIcon: String? = nil
    var onSelect: (SpendingProjectAppearanceSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: AppearanceTab
    @State private var brandSearchQuery = ""

    private let brandColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    private let classicColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    init(
        currentPlacement: ResolvedPlacement = .none,
        currentIcon: String? = nil,
        onSelect: @escaping (SpendingProjectAppearanceSelection) -> Void
    ) {
        self.currentPlacement = currentPlacement
        self.currentIcon = currentIcon
        self.onSelect = onSelect

        if case .assetReady = currentPlacement {
            _selectedTab = State(initialValue: .sticker)
        } else if let icon = currentIcon, !icon.isEmpty {
            if icon.hasPrefix("sub_") {
                _selectedTab = State(initialValue: .brand)
            } else {
                _selectedTab = State(initialValue: EmojiCatalog.isEmojiIcon(icon) ? .emoji : .classic)
            }
        } else {
            _selectedTab = State(initialValue: .brand)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("外观类型", selection: $selectedTab) {
                    ForEach(AppearanceTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, HoloSpacing.sm)

                HoloHairlineDivider()

                contentForSelectedTab
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.holoToolBackground)
            .navigationTitle("选择外观")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .holoIconSize(.sm)
                            .foregroundStyle(Color.holoToolTextSecondary)
                    }
                    .accessibilityLabel(Text("关闭"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "恢复默认")) {
                        HapticManager.light()
                        onSelect(.clearToDefault)
                        dismiss()
                    }
                    .font(.holoCaption)
                    .foregroundStyle(Color.holoToolTextSecondary)
                }
            }
        }
        .presentationBackground(Color.holoToolBackground)
    }

    @ViewBuilder
    private var contentForSelectedTab: some View {
        switch selectedTab {
        case .brand:
            brandIconGrid
        case .sticker:
            VisualAppearancePickerView(
                isPushed: true,
                pickerTitle: String(localized: "贴纸"),
                currentPlacement: currentPlacement,
                onRestoreDefault: {
                    onSelect(.clearToDefault)
                    dismiss()
                }
            ) { assetID, presentation in
                onSelect(.sticker(assetID: assetID, presentation: presentation))
                dismiss()
            }
        case .emoji:
            EmojiCatalogGrid(currentIcon: currentIcon ?? "") { emoji in
                HapticManager.light()
                onSelect(.icon(emoji))
                dismiss()
            }
        case .classic:
            classicIconGrid
        }
    }

    private var brandIconGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .holoIconSize(.sm)
                    .foregroundStyle(Color.holoToolTextSecondary)
                TextField("搜索品牌，如 Netflix / 爱奇艺 / Claude", text: $brandSearchQuery)
                    .font(.holoCaption)
                    .foregroundStyle(Color.holoToolText)
                if !brandSearchQuery.isEmpty {
                    Button {
                        brandSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .holoIconSize(.sm)
                            .foregroundStyle(Color.holoToolTextSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.holoToolInset)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
            .padding(.horizontal, HoloSpacing.md)
            .padding(.top, HoloSpacing.sm)
            .padding(.bottom, HoloSpacing.xs)

            ScrollView(showsIndicators: false) {
                let sections = SubscriptionBrandIconCatalog.sections(matching: brandSearchQuery)
                if sections.isEmpty {
                    Text("没有找到匹配的品牌，可以试试 Emoji 或贴纸")
                        .font(.holoCaption)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .padding(.top, 48)
                } else {
                    LazyVStack(alignment: .leading, spacing: HoloSpacing.lg) {
                        ForEach(sections, id: \.category.id) { section in
                            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                                HoloSectionHeader(LocalizedStringKey(section.category.rawValue))
                                LazyVGrid(columns: brandColumns, spacing: 12) {
                                    ForEach(section.items) { brand in
                                        let isSelected = currentIcon == brand.id
                                        Button {
                                            HapticManager.light()
                                            onSelect(.icon(brand.id))
                                            dismiss()
                                        } label: {
                                            VStack(spacing: 6) {
                                                Image(brand.id)
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(width: 46, height: 46)
                                                    .padding(4)
                                                    .background(isSelected ? Color.holoToolAction.opacity(0.10) : Color.holoToolInset)
                                                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
                                                    .overlay {
                                                        if isSelected {
                                                            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                                                                .strokeBorder(Color.holoToolAction, lineWidth: 1.5)
                                                        }
                                                    }
                                                Text(brand.name)
                                                    .font(.holoTinyLabel)
                                                    .foregroundStyle(Color.holoToolTextSecondary)
                                                    .lineLimit(1)
                                            }
                                            .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, HoloSpacing.md)
                }
            }
        }
    }

    private var classicIconGrid: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: HoloSpacing.lg) {
                ForEach(UnifiedIconCatalog.sections) { section in
                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        HoloSectionHeader(LocalizedStringKey(section.title))
                        LazyVGrid(columns: classicColumns, spacing: 10) {
                            ForEach(section.items) { item in
                                let isSelected = currentIcon == item.name
                                Button {
                                    HapticManager.light()
                                    onSelect(.icon(item.name))
                                    dismiss()
                                } label: {
                                    VStack(spacing: 4) {
                                        entityIconGlyph(
                                            item.name,
                                            size: 20,
                                            color: isSelected ? .holoToolAction : .holoToolText
                                        )
                                        .frame(width: 50, height: 50)
                                        .background(isSelected ? Color.holoToolAction.opacity(0.10) : Color.holoToolInset)
                                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
                                        .overlay {
                                            if isSelected {
                                                RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                                                    .strokeBorder(Color.holoToolAction, lineWidth: 1.5)
                                            }
                                        }
                                        Text(item.label)
                                            .font(.holoTinyLabel)
                                            .foregroundStyle(Color.holoToolTextSecondary)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.md)
        }
    }
}
