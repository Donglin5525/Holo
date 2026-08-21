//
//  HoloTodoWidget.swift
//  HoloWidgets
//
//  今日待办 · 招牌视觉「极简清单 + 完成进度」
//

import SwiftUI
import WidgetKit

struct HoloTodoWidget: Widget {
    let kind = HoloWidgetKind.todo.rawValue

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HoloTodoProvider()) { entry in
            HoloTodoWidgetView(entry: entry)
        }
        .configurationDisplayName("今日待办")
        .description("今天还剩什么，桌面看一眼。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct HoloTodoProvider: TimelineProvider {
    func placeholder(in context: Context) -> HoloWidgetEntry<HoloWidgetTodoSnapshot> {
        HoloWidgetEntry(date: Date(), value: .sample(), entitlement: .plusPreview())
    }

    func getSnapshot(in context: Context, completion: @escaping (HoloWidgetEntry<HoloWidgetTodoSnapshot>) -> Void) {
        completion(HoloWidgetEntry(
            date: Date(),
            value: .sample(),
            entitlement: widgetEntitlement(for: context)
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HoloWidgetEntry<HoloWidgetTodoSnapshot>>) -> Void) {
        let store = HoloWidgetSnapshotStore()
        let entitlement = store.readEntitlement() ?? .free()
        let snapshot = entitlement.isPlusActive ? (store.readTodo() ?? .sample()) : .sample()
        let entry = HoloWidgetEntry(date: Date(), value: snapshot, entitlement: entitlement)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 30))))
    }
}

private struct HoloTodoWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: HoloWidgetEntry<HoloWidgetTodoSnapshot>

    private var value: HoloWidgetTodoSnapshot { entry.value }

    var body: some View {
        Group {
            if entry.entitlement.isPlusActive {
                Link(destination: URL(string: "holo://tasks")!) {
                    if value.items.isEmpty {
                        emptyState
                    } else if family == .systemLarge {
                        todoLarge
                    } else {
                        todoMedium
                    }
                }
            } else {
                HoloLockedWidgetView()
            }
        }
        .holoWidgetBackground(colorScheme: colorScheme)
    }

    // MARK: Medium · 3 待办 + 1 已划掉

    private var todoMedium: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 7) {
                ForEach(leadingItems(3, includeCompleted: true)) { item in
                    todoRow(item)
                }
            }
            .padding(.top, 9)
        }
        .padding(15)
    }

    // MARK: Large · 5 待办 + 完成进度

    private var todoLarge: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 10) {
                ForEach(leadingItems(5, includeCompleted: true)) { item in
                    todoRow(item)
                }
            }
            .padding(.top, 10)

            Spacer(minLength: 0)

            HStack(spacing: 9) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(trackTint)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [primaryTint, HoloWidgetBrand.primaryLight],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * progressRatio)
                    }
                }
                .frame(height: 5)

                Text(progressText)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(textSecondary)
            }
            .padding(.top, 10)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(HoloWidgetBrand.hairline(for: colorScheme))
                    .frame(height: 0.8)
            }
        }
        .padding(16)
    }

    // MARK: 零件

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(value.items.isEmpty ? "今日待办" : "今日 · 剩 \(value.pendingCount) 项")
                .font(.system(size: family == .systemLarge ? 15 : 14, weight: .bold))
                .foregroundStyle(textPrimary)
            Spacer()
            if !value.dateText.isEmpty {
                Text(value.dateText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(textSecondary)
            }
        }
    }

    /// 未完成在前（最多 limit），末尾带一条今日已完成（划线样本，若有）
    private func leadingItems(_ limit: Int, includeCompleted: Bool) -> [HoloWidgetTodoItem] {
        var items = Array(value.items.filter { !$0.isCompleted }.prefix(limit))
        if includeCompleted, items.count < limit,
           let completed = value.items.first(where: \.isCompleted) {
            items.append(completed)
        }
        return items
    }

    private func todoRow(_ item: HoloWidgetTodoItem) -> some View {
        HStack(spacing: 9) {
            ZStack {
                if item.isCompleted {
                    Circle().fill(greenTint)
                    Image(systemName: "checkmark")
                        .font(.system(size: family == .systemLarge ? 9 : 8, weight: .heavy))
                        .foregroundStyle(Color.white)
                } else {
                    Circle().strokeBorder(trackTint, lineWidth: 1.7)
                }
            }
            .frame(width: family == .systemLarge ? 21 : 19, height: family == .systemLarge ? 21 : 19)

            Text(item.title)
                .font(.system(size: family == .systemLarge ? 14 : 13, weight: item.isCompleted ? .medium : .semibold))
                .foregroundStyle(item.isCompleted ? textSecondary.opacity(0.7) : textPrimary)
                .strikethrough(item.isCompleted, color: textSecondary.opacity(0.6))
                .lineLimit(1)

            if !item.isCompleted {
                Spacer(minLength: 2)
                if item.isOverdue {
                    Text("逾期")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(roseTint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(roseTint.opacity(0.14))
                        .clipShape(Capsule())
                } else {
                    Circle()
                        .fill(HoloWidgetPriorityDot.color(priority: item.priority, colorScheme: colorScheme))
                        .frame(width: 5, height: 5)
                }
            } else {
                Spacer(minLength: 2)
                Circle().fill(.clear).frame(width: 5, height: 5)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            HoloWidgetIconText.icon("🫧", size: 24)
            Text("今天没有待办")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(textPrimary)
            Text("留白的桌面，留白的一天")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
    }

    private var progressRatio: Double {
        guard value.totalToday > 0 else { return 0 }
        return min(1, Double(value.completedToday) / Double(value.totalToday))
    }

    private var progressText: String {
        "\(value.completedToday) / \(value.totalToday) · \(Int((progressRatio * 100).rounded()))%"
    }

    private var primaryTint: Color { HoloWidgetBrand.primary(for: colorScheme) }
    private var greenTint: Color { HoloWidgetBrand.success(for: colorScheme) }
    private var roseTint: Color { HoloWidgetBrand.domainRose(for: colorScheme) }
    private var textPrimary: Color { HoloWidgetBrand.textPrimary(for: colorScheme) }
    private var textSecondary: Color { HoloWidgetBrand.textSecondary(for: colorScheme) }
    private var trackTint: Color { HoloWidgetBrand.progressTrack(for: colorScheme) }
}
