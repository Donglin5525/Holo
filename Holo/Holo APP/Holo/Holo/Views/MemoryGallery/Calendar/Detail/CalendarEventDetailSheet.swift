//
//  CalendarEventDetailSheet.swift
//  Holo
//
//  日历事件只读详情（按 CalendarEvent 展示模块/标题/副信息/时间）
//  「在 X 模块打开」跳转原模块编辑页留 P1B（需各模块详情路由）。
//

import SwiftUI

struct CalendarEventDetailSheet: View {
    let event: CalendarEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.md) {
                    moduleHeader
                    infoCard
                }
                .padding(HoloSpacing.md)
            }
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle("详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    // MARK: - 模块标识

    private var moduleHeader: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: event.module.iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(event.module.color)
                .frame(width: 36, height: 36)
                .background(event.module.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
            Text(event.module.displayName)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
            Spacer()
        }
    }

    // MARK: - 信息卡

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text(event.title)
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            if let detail = event.detail {
                Text(detail)
                    .font(.holoBody)
                    .foregroundColor(event.module.color)
            }

            Divider()

            HStack {
                Text("时间")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Text(fullDateTime)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPrimary)
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    private var fullDateTime: String {
        Self.formatter.string(from: event.date)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
