//
//  CalendarSourcePickerView.swift
//  Holo
//
//  「显示的日历」独立选择页：按来源分组（Holo 专属 → 账户 → 订阅垫底），
//  组头带全选/全不选，勾选沿用系统日历 App 的轻量对勾。
//

import SwiftUI
import EventKit

struct CalendarSourcePickerView: View {
    @StateObject private var store = ScheduleStore.shared

    var body: some View {
        Group {
            if store.availableCalendars.isEmpty {
                VStack {
                    Text("未找到可用日历")
                        .font(.system(size: 13))
                        .foregroundColor(.holoTextSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: HoloSpacing.md) {
                        explainCard

                        ForEach(groups) { group in
                            groupSection(group)
                        }
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.vertical, HoloSpacing.md)
                }
            }
        }
        .background(Color.holoBackground)
        .navigationTitle("显示的日历")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Text("已选 \(selectedCount)/\(store.availableCalendars.count)")
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .onAppear {
            if store.authorizationStatus == .fullAccess {
                store.refreshCalendars()
            }
        }
    }

    // MARK: - 顶部说明（AI 可读性告知，从设置页移到勾选发生处）

    private var explainCard: some View {
        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundColor(.holoPrimary)
                .padding(.top, 3)

            Text("勾选的日历会显示在 Holo 日历页；对话与周规划时 AI 也只读取这些日历来安排时间。日程数据仅在本机与当次 AI 请求中使用。")
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HoloSpacing.md)
        .background(Color.holoPrimary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - 分组

    private struct CalendarGroup: Identifiable {
        enum Kind { case holo, account, subscribed }
        let id: String
        let title: String
        let kind: Kind
        var items: [ScheduleCalendarInfo]
    }

    /// Store 已按「Holo → 账户 → 订阅」语义排序，同一来源连续，按连续段切组即可
    private var groups: [CalendarGroup] {
        var result: [CalendarGroup] = []
        for info in store.availableCalendars {
            let id: String
            let title: String
            let kind: CalendarGroup.Kind
            if info.isHolo {
                id = "holo"; title = "Holo 专属"; kind = .holo
            } else if info.isSubscribed {
                id = "subscribed"; title = "订阅"; kind = .subscribed
            } else {
                id = "account:\(info.sourceTitle)"; title = info.sourceTitle; kind = .account
            }
            if let last = result.indices.last, result[last].id == id {
                result[last].items.append(info)
            } else {
                result.append(CalendarGroup(id: id, title: title, kind: kind, items: [info]))
            }
        }
        return result
    }

    private var selectedCount: Int {
        store.availableCalendars.filter(\.isSelected).count
    }

    private func groupSection(_ group: CalendarGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(group.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)

                Text("· \(group.items.count)")
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary.opacity(0.7))

                if group.kind == .subscribed {
                    Text("· 默认不勾选")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary.opacity(0.7))
                }

                Spacer()

                // 组级全选/全不选（Holo 组只有一项，不设）
                if group.kind != .holo {
                    let allSelected = group.items.allSatisfy(\.isSelected)
                    Button {
                        store.setSelection(group.items.map(\.id), selected: !allSelected)
                    } label: {
                        Text(allSelected ? "全不选" : "全选")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.holoPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(group.items) { info in
                    calendarRow(info)
                    if info.id != group.items.last?.id {
                        Divider().padding(.leading, HoloSpacing.md)
                    }
                }
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
    }

    private func calendarRow(_ info: ScheduleCalendarInfo) -> some View {
        Button {
            store.toggleCalendarSelection(info.id)
        } label: {
            HStack(spacing: HoloSpacing.md) {
                Circle()
                    .fill(info.color)
                    .frame(width: 9, height: 9)

                Text(info.title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)

                if info.isHolo {
                    Text("任务同步写入")
                        .font(.system(size: 10))
                        .foregroundColor(.holoTextSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.holoTextSecondary.opacity(0.1))
                        .clipShape(Capsule())
                }

                Spacer()

                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(info.isSelected ? .holoPrimary : .holoTextSecondary.opacity(0.25))
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
