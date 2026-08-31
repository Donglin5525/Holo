//
//  CalendarEventDetailSheet.swift
//  Holo
//
//  日历事件只读详情（按 CalendarEvent 展示模块/标题/副信息/时间）
//  P3：想法事件额外展示「相关观点」（经 Thought.topics 间接体现观点维度）
//

import SwiftUI
import CoreData

struct CalendarEventGroup: Identifiable {
    let id = UUID()
    let events: [CalendarEvent]

    var title: String {
        guard let first = events.first else { return "记录明细" }
        let hour = Calendar.current.component(.hour, from: first.date)
        let moduleCount = Set(events.map(\.module)).count
        if moduleCount == 1, let module = events.first?.module {
            return "\(hour):00 \(module.displayName) +\(events.count)"
        }
        return "\(hour):00 记录 +\(events.count)"
    }
}

struct CalendarEventDetailSheet: View {
    let event: CalendarEvent
    @Environment(\.dismiss) private var dismiss
    @State private var isOpeningOrigin = false
    @State private var originOpenError: String?
    /// 原始实体已删除（详情打开时后台回查，直接呈现删除态而非点击才报错）
    @State private var originDeleted = false

    /// 当前事件是否支持「在原模块打开」
    private var supportsOpenInModule: Bool {
        event.module == .finance
            || event.module == .habit
            || event.module == .todo
            || event.module == .thought
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.md) {
                    moduleHeader
                    infoCard
                    if let topics = event.relatedTopics, !topics.isEmpty {
                        topicsCard(topics)
                    }
                    if supportsOpenInModule {
                        if originDeleted {
                            deletedOriginCard
                        } else {
                            openInModuleButton
                        }
                    }
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
            .task {
                await checkOriginAlive()
            }
        }
        .alert("无法打开原记录", isPresented: Binding(
            get: { originOpenError != nil },
            set: { if !$0 { originOpenError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(originOpenError ?? "")
        }
    }

    /// 详情打开时后台回查来源存活性：删除的记录不伪造「可打开」入口（统一浏览方案 §7.5）
    private func checkOriginAlive() async {
        let originID = event.originID
        let context = CoreDataStack.shared.newBackgroundContext()
        let exists: Bool = await context.perform {
            (try? context.existingObject(with: originID)) != nil
        }
        originDeleted = !exists
    }

    // MARK: - 原记录已删除态

    private var deletedOriginCard: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "trash.slash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.holoTextPlaceholder)
            Text("原记录已删除")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.sm)
        .padding(.horizontal, HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(Color.holoNestedCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.6), lineWidth: 1)
        )
    }

    // MARK: - 在原模块打开

    private var openInModuleButton: some View {
        Button {
            openInOriginModule()
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                if isOpeningOrigin {
                    ProgressView()
                        .tint(event.module.color)
                } else {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 14, weight: .semibold))
                }
                Text("在\(event.module.displayName)模块打开")
                    .font(.holoBody)
                    .fontWeight(.medium)
            }
            .foregroundColor(event.module.color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, HoloSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(event.module.color.opacity(0.1))
            )
        }
        .disabled(isOpeningOrigin)
    }

    /// 经 CalendarEventOriginResolver 回查实体 UUID，再借助 DeepLinkState 跳转到对应模块详情。
    private func openInOriginModule() {
        guard !isOpeningOrigin else { return }
        isOpeningOrigin = true

        CalendarEventOriginResolver.resolve(event) { target in
            isOpeningOrigin = false
            guard let target else {
                originOpenError = "原记录可能已被删除，或当前版本暂时无法打开。"
                return
            }
            dismiss()
            // 下一轮再触发跳转，确保 sheet dismiss 已开始、不被遮盖
            DispatchQueue.main.async {
                DeepLinkState.shared.navigate(to: target)
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

    // MARK: - P3 相关观点（仅想法事件）

    private func topicsCard(_ topics: [String]) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: 5) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoPurple)
                Text("相关观点")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HoloSpacing.xs) {
                    ForEach(topics, id: \.self) { topic in
                        Text(topic)
                            .font(.holoLabel)
                            .foregroundColor(.holoPurple)
                            .padding(.horizontal, HoloSpacing.sm)
                            .padding(.vertical, 4)
                            .background(Color.holoPurple.opacity(0.10))
                            .clipShape(Capsule())
                            // 观点名称来自数据，横向展示时保持胶囊完整宽度
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
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

struct CalendarEventGroupDetailSheet: View {
    let group: CalendarEventGroup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    ForEach(sortedEvents) { event in
                        eventRow(event)
                    }
                }
                .padding(HoloSpacing.md)
            }
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle(group.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var sortedEvents: [CalendarEvent] {
        group.events.sorted { $0.date < $1.date }
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            Image(systemName: event.module.iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(event.module.color)
                .frame(width: 28, height: 28)
                .background(event.module.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.timeText(for: event.date))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.holoTextSecondary)
                    Text(event.title)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(2)
                }
                if let detail = event.detail {
                    Text(detail)
                        .font(.holoCaption)
                        .foregroundColor(event.module.color)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(HoloSpacing.sm)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.75), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // 想法行直达想法详情（与卡片直跳一致）；其他模块维持纯列表展示
            guard event.module == .thought else { return }
            CalendarEventOriginResolver.resolve(event) { target in
                guard let target else { return }
                dismiss()
                DispatchQueue.main.async {
                    DeepLinkState.shared.navigate(to: target)
                }
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func timeText(for date: Date) -> String {
        timeFormatter.string(from: date)
    }
}
