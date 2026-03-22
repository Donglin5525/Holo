//
//  MemoryDetailView.swift
//  Holo
//
//  记忆详情视图
//  展示单条记忆的详细信息
//

import SwiftUI

/// 记忆详情视图
struct MemoryDetailView: View {

    // MARK: - Properties

    let memory: MemoryItem

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    // 顶部类型标签
                    typeHeader

                    // 主要信息卡片
                    mainInfoCard

                    // 详细信息
                    detailSection

                    // 备注（如果有）
                    if let note = memory.note, !note.isEmpty {
                        noteSection(note)
                    }
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground)
            .navigationTitle("详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                    .foregroundColor(.holoPrimary)
                }
            }
        }
    }

    // MARK: - Subviews

    /// 类型头部
    @ViewBuilder
    private var typeHeader: some View {
        HStack {
            Image(systemName: memory.type.icon)
                .font(.system(size: 14))
                .foregroundColor(.white)

            Text(memory.type.displayName)
                .font(.holoLabel)
                .foregroundColor(.white)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
        .background(memory.color)
        .cornerRadius(HoloRadius.md)
    }

    /// 主要信息卡片
    @ViewBuilder
    private var mainInfoCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题
            Text(memory.title)
                .font(.holoTitle)
                .foregroundColor(.holoTextPrimary)

            // 金额（仅交易类型）
            if memory.type == .transaction, let amount = memory.formattedAmount {
                Text(amount)
                    .font(.holoAmount)
                    .foregroundColor(memory.amount ?? 0 >= 0 ? .holoSuccess : .holoError)
            }

            // 副标题
            if let subtitle = memory.subtitle {
                Text(subtitle)
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HoloSpacing.lg)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    /// 详细信息区域
    @ViewBuilder
    private var detailSection: some View {
        VStack(spacing: 0) {
            // 创建时间
            detailRow(
                icon: "calendar",
                title: "日期",
                value: memory.formattedFullDateTime
            )

            Divider()
                .padding(.leading, 44)

            // 相对时间
            detailRow(
                icon: "clock",
                title: "记录于",
                value: memory.formattedRelativeDate + " " + memory.formattedTime
            )

            // 类型特定信息
            switch memory.type {
            case .transaction:
                Divider()
                    .padding(.leading, 44)
                detailRow(
                    icon: "tag",
                    title: "分类",
                    value: memory.title
                )
            case .habitRecord:
                EmptyView()
            case .task:
                EmptyView()
            }
        }
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    /// 详情行
    @ViewBuilder
    private func detailRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.holoPrimary)
                .frame(width: 24)

            Text(title)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .frame(width: 60, alignment: .leading)

            Text(value)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()
        }
        .padding(HoloSpacing.md)
    }

    /// 备注区域
    @ViewBuilder
    private func noteSection(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Image(systemName: "note.text")
                    .font(.system(size: 14))
                    .foregroundColor(.holoPrimary)

                Text("备注")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            Text(note)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }
}

// MARK: - Preview

#Preview {
    let sampleMemory = MemoryItem(
        id: UUID(),
        type: .transaction,
        date: Date(),
        title: "餐饮",
        subtitle: "午餐 · 现金账户",
        icon: "icon_food",
        colorHex: "#13A4EC",
        amount: 35.5,
        note: "公司楼下便当，味道还不错",
        createdAt: Date(),
        sourceId: UUID()
    )

    return MemoryDetailView(memory: sampleMemory)
}
