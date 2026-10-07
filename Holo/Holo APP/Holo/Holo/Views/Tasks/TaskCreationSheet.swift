//
//  TaskCreationSheet.swift
//  Holo
//
//  添加任务页（2026-10-06 任务重构方案 §5；2026-10-07 东林拍板重排+紧急分体系）：
//  ① 内容卡＝标题（附件回形针入口）＋描述＋检查清单（与描述同卡）；
//  ② 安排卡＝时间＋清单两行（时间前移：先设日期，紧急分自动折算立刻有依据）；
//  ③ 轻重缓急卡＝默认收起一行摘要，点开是 P 档双滑杆编辑器（重要×2＋紧急=3–9 分）。
//  减法：状态、目标、分步推进、延期、实际用时属编辑期能力，不进新建。
//  只有标题必填；一份草稿一次保存。
//

import SwiftUI
import PhotosUI

struct TaskCreationSheet: View {

    @ObservedObject var repository: TodoRepository

    @Environment(\.dismiss) private var dismiss

    @StateObject private var draft: TaskCreationDraft

    // MARK: 时间（截止·全天·提醒·重复，与详情同一弹窗编辑）

    @State private var selectedReminders: Set<TaskReminder> = []
    @State private var hasRepeat = false
    @State private var repeatType: RepeatType = .daily
    @State private var selectedWeekdays: Set<Weekday> = []
    @State private var monthDay: Int = 1
    @State private var monthWeekOrdinal: Int = 1
    @State private var monthWeekday: Weekday? = nil
    @State private var monthlyRepeatMode: MonthlyRepeatMode = .dayOfMonth
    @State private var endConditionType: EndConditionType = .never
    @State private var repeatEndDate: Date? = nil
    @State private var repeatEndCount: Int = 10
    @State private var showTimeSheet = false

    // MARK: 轻重缓急（默认收起，点开 P 档滑杆）

    @State private var isClassificationExpanded = false

    // MARK: 检查清单（创建期先收集标题，随主任务同一次保存）

    @State private var checkItemTitles: [String] = []
    @State private var newCheckItemTitle = ""
    @FocusState private var isNewCheckItemFocused: Bool

    // MARK: 附件（标题行回形针入口，缩略图条挂在标题下方）

    @State private var pendingImages: [UIImage] = []
    @State private var showPhotoPicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []

    // MARK: 清单与弹层

    @State private var showListPicker = false
    @State private var showDismissConfirm = false
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    /// 首次保存已建成的任务：后续步骤（重复/附件）失败重试时跳过重建，杜绝重复任务（R11）
    @State private var createdTask: TodoTask? = nil

    init(
        repository: TodoRepository,
        context: TaskCreationContext = TaskCreationContext()
    ) {
        self.repository = repository
        _draft = StateObject(wrappedValue: TaskCreationDraft(context: context))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    if draft.context.sourceQuadrant != nil {
                        sourceBanner
                    }
                    contentCard
                    scheduleCard
                    classificationCard
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, HoloSpacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.holoBackground)
            .navigationTitle(String(localized: "添加任务"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { handleCancel() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                saveBar
            }
            .onAppear {
                // 冒烟/UITest 通道：带参启动直达展开态（模拟器无头走查用，见 docs 踩坑录）
                if ProcessInfo.processInfo.arguments.contains("-holo-smoke-expand-classification") {
                    isClassificationExpanded = true
                }
            }
            .sheet(isPresented: $showTimeSheet) {
                TaskDatePickerSheet(
                    dueDate: $draft.dueDate,
                    isAllDay: Binding(
                        get: { draft.dueIsAllDay },
                        set: { draft.dueIsAllDay = $0; draft.markEdited() }
                    ),
                    hasDueDate: Binding(
                        get: { draft.hasDueDate },
                        set: { draft.hasDueDate = $0; draft.markEdited() }
                    ),
                    selectedReminders: $selectedReminders,
                    hasRepeat: $hasRepeat,
                    repeatType: $repeatType,
                    selectedWeekdays: $selectedWeekdays,
                    monthDay: $monthDay,
                    monthWeekOrdinal: $monthWeekOrdinal,
                    monthWeekday: $monthWeekday,
                    monthlyRepeatMode: $monthlyRepeatMode,
                    endConditionType: $endConditionType,
                    repeatEndDate: $repeatEndDate,
                    repeatEndCount: $repeatEndCount
                )
            }
            .sheet(isPresented: $showListPicker) {
                TaskCreationListPickerSheet(repository: repository, draft: draft)
                    .presentationDetents([.medium, .large])
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $selectedPhotos,
                maxSelectionCount: max(0, 9 - pendingImages.count),
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: selectedPhotos) { _, newItems in
                loadPhotos(newItems)
            }
            .onChange(of: selectedReminders) { _, _ in
                draft.markEdited()
            }
            .onChange(of: hasRepeat) { _, _ in
                draft.markEdited()
            }
            .alert(String(localized: "未保存的修改"), isPresented: $showDismissConfirm) {
                Button(String(localized: "继续编辑"), role: .cancel) {}
                Button(String(localized: "放弃修改"), role: .destructive) { dismiss() }
            } message: {
                Text("已有输入的内容还没有保存，确定要关闭吗？")
            }
            .alert(
                String(localized: "没有保存成功"),
                isPresented: Binding(
                    get: { saveErrorMessage != nil },
                    set: { if !$0 { saveErrorMessage = nil } }
                )
            ) {
                Button(String(localized: "重试")) { save() }
                Button(String(localized: "知道了"), role: .cancel) {}
            } message: {
                Text(saveErrorMessage ?? String(localized: "请重试"))
            }
        }
    }

    // MARK: - 来源提示

    /// 来自象限的来源提示（§5.2 末段）
    private var sourceBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.holoPrimary)
            Text(String(localized: "来自「\(draft.context.sourceQuadrant?.displayTitle ?? "")」，已预填分类，可调整"))
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoPrimary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous))
    }

    // MARK: - 内容卡：标题（附件入口）＋描述＋检查清单

    private var contentCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField(String(localized: "想做什么？"), text: Binding(
                    get: { draft.title },
                    set: { draft.title = $0; draft.markEdited() }
                ))
                .font(.system(size: 22, weight: .bold))
                attachButton
            }
            .padding(HoloSpacing.md)

            if !pendingImages.isEmpty {
                attachStrip
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.bottom, HoloSpacing.sm)
            }

            Rectangle().fill(Color.holoDivider).frame(height: 0.5).padding(.leading, HoloSpacing.md)

            TextField(String(localized: "描述（可选）"), text: Binding(
                get: { draft.note },
                set: { draft.note = $0; draft.markEdited() }
            ), axis: .vertical)
            .lineLimit(1...4)
            .font(.holoBody)
            .padding(HoloSpacing.md)

            Rectangle().fill(Color.holoDivider).frame(height: 0.5).padding(.leading, HoloSpacing.md)

            checklistArea
                .padding(HoloSpacing.md)
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }

    /// 标题行回形针：附件入口；有附件时红点角标
    private var attachButton: some View {
        Button {
            showPhotoPicker = true
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.holoBackground))
                .overlay(alignment: .topTrailing) {
                    if !pendingImages.isEmpty {
                        Circle()
                            .fill(Color.holoPrimary)
                            .frame(width: 9, height: 9)
                            .offset(x: 2, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "添加附件")))
    }

    /// 附件缩略图条（有附件才出现在标题下方）
    private var attachStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingImages.indices, id: \.self) { index in
                    Image(uiImage: pendingImages[index])
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                pendingImages.remove(at: index)
                                draft.markEdited()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                    .shadow(radius: 2)
                                    .frame(width: 24, height: 24, alignment: .topTrailing)
                            }
                            .buttonStyle(.plain)
                        }
                }
                if pendingImages.count < 9 {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundColor(Color.holoDivider)
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: "plus")
                                    .font(.system(size: 14))
                                    .foregroundColor(.holoTextSecondary)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 46)
    }

    // MARK: 检查清单（与描述同卡；标题收集，随主任务一次保存）

    private var checklistArea: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("检查清单")
                    .font(.holoTinyLabel.weight(.semibold))
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Text(checkItemTitles.isEmpty ? String(localized: "可选") : String(localized: "\(checkItemTitles.count) 项"))
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextPlaceholder)
            }

            VStack(spacing: 0) {
                ForEach(checkItemTitles.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        Circle()
                            .strokeBorder(Color.holoTextPlaceholder, lineWidth: 1.2)
                            .frame(width: 15, height: 15)
                        Text(checkItemTitles[index])
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Spacer()
                        Button {
                            checkItemTitles.remove(at: index)
                            draft.markEdited()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.holoTextPlaceholder.opacity(0.7))
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 8)
                    if index < checkItemTitles.count - 1 {
                        Rectangle().fill(Color.holoDivider).frame(height: 0.5).padding(.leading, 23)
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                    TextField(String(localized: "添加一项"), text: $newCheckItemTitle)
                        .font(.holoBody)
                        .focused($isNewCheckItemFocused)
                        .onSubmit(addCheckItem)
                    if !newCheckItemTitle.isEmpty {
                        Button(action: addCheckItem) {
                            Text("添加")
                                .font(.holoCaption.weight(.semibold))
                                .foregroundColor(.holoPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - 安排卡：时间＋清单（时间前移：先设日期，紧急分自动折算立刻有依据）

    private var scheduleCard: some View {
        VStack(spacing: 0) {
            scheduleRow(
                title: String(localized: "时间"),
                value: timeSummary,
                valueProminent: draft.hasDueDate
            ) {
                showTimeSheet = true
            }
            Rectangle().fill(Color.holoDivider).frame(height: 0.5).padding(.leading, HoloSpacing.md)
            scheduleRow(
                title: String(localized: "清单"),
                value: currentListName,
                valueProminent: false
            ) {
                showListPicker = true
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }

    private func scheduleRow(
        title: String,
        value: String,
        valueProminent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Text(value)
                    .font(.holoCaption)
                    .foregroundColor(valueProminent ? .holoTextPrimary : .holoTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextPlaceholder)
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 轻重缓急（默认收起；展开＝P 档双滑杆编辑器，2026-10-07）

    private var classificationCard: some View {
        VStack(spacing: 0) {
            Button {
                HapticManager.selection()
                withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                    isClassificationExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text("轻重缓急")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Spacer()
                    Text(classificationSummaryText)
                        .font(.holoCaption)
                        .foregroundColor(draft.importance == .unknown ? .holoTextSecondary : draft.previewQuadrant.tintColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextPlaceholder)
                        .rotationEffect(.degrees(isClassificationExpanded ? 180 : 0))
                }
                .padding(HoloSpacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(String(localized: "展开调整重要性、紧急度与紧急分")))

            if isClassificationExpanded {
                Rectangle().fill(Color.holoDivider).frame(height: 0.5).padding(.horizontal, HoloSpacing.md)
                TaskClassificationLeverEditor(
                    importance: Binding(
                        get: { draft.importance },
                        set: { draft.importance = $0; draft.markEdited() }
                    ),
                    urgencyMode: Binding(
                        get: { draft.urgencyMode },
                        set: { draft.urgencyMode = $0; draft.markEdited() }
                    ),
                    effectiveDue: draft.effectiveDueForPreview
                )
                .padding(HoloSpacing.md)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }

    /// 收起态摘要：P 档 · 紧急分 · 去向（未判断 → 收进待整理）
    private var classificationSummaryText: String {
        if draft.importance == .unknown {
            return String(localized: "未判断 · 收进待整理")
        }
        let score = draft.urgencyScore.map { "\($0)" } ?? "—"
        return "\(draft.importance.displayTitle) · \(String(localized: "紧急分")) \(score) · \(draft.previewQuadrant.displayTitle)"
    }

    // MARK: - 底部保存（去向信息已并入轻重缓急卡，保存条只留主按钮）

    private var saveBar: some View {
        Button {
            save()
        } label: {
            Text("添加任务")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                        .fill(draft.canSave && !isSaving ? Color.holoPrimary : Color.holoPrimary.opacity(0.35))
                )
        }
        .buttonStyle(.plain)
        .disabled(!draft.canSave || isSaving)
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, HoloSpacing.sm)
        .padding(.bottom, HoloSpacing.sm)
        .background(.ultraThinMaterial)
    }

    // MARK: - 数据与格式

    private var currentList: TodoList? {
        draft.listID.flatMap { repository.findList(by: $0) }
    }

    private var currentListName: String {
        currentList?.name ?? String(localized: "收件箱")
    }

    private var timeSummary: String {
        guard draft.hasDueDate else { return String(localized: "无截止") }
        var parts = [Self.formatDue(draft.dueDate, isAllDay: draft.dueIsAllDay)]
        if !selectedReminders.isEmpty {
            parts.append(String(localized: "\(selectedReminders.count) 个提醒"))
        }
        if hasRepeat {
            parts.append(repeatType.displayTitle)
        }
        return parts.joined(separator: " · ")
    }

    static func formatDue(_ date: Date, isAllDay: Bool) -> String {
        let calendar = TaskAnalyticsPeriod.makeCalendar()
        if calendar.isDateInToday(date) {
            return isAllDay ? String(localized: "今天") : String(localized: "今天") + " " + Self.timeString(date)
        }
        if calendar.isDateInTomorrow(date) {
            return isAllDay ? String(localized: "明天") : String(localized: "明天") + " " + Self.timeString(date)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate(isAllDay ? "M月d日" : "M月d日 HH:mm")
        return formatter.string(from: date)
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - 动作

    private func addCheckItem() {
        let trimmed = newCheckItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        checkItemTitles.append(trimmed)
        newCheckItemTitle = ""
        draft.markEdited()
        isNewCheckItemFocused = true
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task { @MainActor in
            selectedPhotos = []
            for item in items {
                let outcome = await PhotoLibraryImageLoader.loadImageData(from: item)
                guard case .data(let data) = outcome, let image = UIImage(data: data) else { continue }
                pendingImages.append(image)
            }
            draft.markEdited()
        }
    }

    private func handleCancel() {
        if draft.isBlank && checkItemTitles.isEmpty && pendingImages.isEmpty && selectedReminders.isEmpty && !hasRepeat {
            dismiss()
        } else {
            showDismissConfirm = true
        }
    }

    private func save() {
        guard let title = draft.submitTitle, !isSaving else { return }
        isSaving = true
        let quadrant = draft.previewQuadrant
        Task { @MainActor in
            do {
                // 主任务 + 检查清单同一次保存（原子）。
                // 重试续跑：首次已建成则不再重建（避免失败重试产生重复任务，R11）
                let task: TodoTask
                if let createdTask {
                    task = createdTask
                } else {
                    task = try repository.createTask(
                        title: title,
                        description: draft.note.isEmpty ? nil : draft.note,
                        list: currentList,
                        importance: draft.importance,
                        urgencyMode: draft.urgencyMode,
                        dueDate: draft.hasDueDate ? draft.dueDate : nil,
                        isAllDay: draft.hasDueDate && draft.dueIsAllDay,
                        reminders: selectedReminders.isEmpty ? nil : selectedReminders,
                        checkItemTitles: checkItemTitles.isEmpty ? nil : checkItemTitles
                    )
                    createdTask = task
                }

                // 重复规则（有截止日才有意义，与详情同一套规则创建）
                if hasRepeat && draft.hasDueDate {
                    _ = try repository.createRepeatRule(
                        type: repeatType,
                        for: task,
                        weekdays: repeatType == .custom ? Array(selectedWeekdays) : nil,
                        untilDate: endConditionType == .onDate ? repeatEndDate : nil
                    )
                    if repeatType == .monthly, let rule = task.repeatRule {
                        try repository.updateRepeatRuleMonthlyParams(
                            rule,
                            monthDay: monthlyRepeatMode == .dayOfMonth ? monthDay : nil,
                            monthWeekOrdinal: monthlyRepeatMode == .nthWeekday ? monthWeekOrdinal : nil,
                            monthWeekday: monthlyRepeatMode == .nthWeekday ? monthWeekday : nil,
                            untilCount: endConditionType == .afterCount ? repeatEndCount : nil
                        )
                    }
                }

                // 附件（任务已建，逐张落库）
                for image in pendingImages {
                    try await repository.addAttachment(image: image, to: task)
                }

                HapticManager.success()
                isSaving = false
                dismiss()
                // 统一创建回执：首页展开定位、容器切回任务页（底部+/统计页入口同样生效）
                NotificationCenter.default.post(
                    name: .taskExperienceCreated,
                    object: nil,
                    userInfo: ["id": task.id, "quadrant": quadrant]
                )
            } catch {
                // 失败保留草稿可重试；已建成的主任务在重试中续跑不重建（§5.4/R11）
                isSaving = false
                saveErrorMessage = String(localized: "没有保存成功，请重试")
            }
        }
    }
}

// MARK: - 清单选择弹层

private struct TaskCreationListPickerSheet: View {
    @ObservedObject var repository: TodoRepository
    @ObservedObject var draft: TaskCreationDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    draft.listID = nil
                    draft.markEdited()
                    dismiss()
                } label: {
                    HStack {
                        Text("收件箱")
                            .foregroundColor(.holoTextPrimary)
                        Spacer()
                        if draft.listID == nil {
                            Image(systemName: "checkmark")
                                .foregroundColor(.holoPrimary)
                        }
                    }
                }
                .buttonStyle(.plain)

                ForEach(repository.allActiveLists(), id: \.id) { list in
                    Button {
                        draft.listID = list.id
                        draft.markEdited()
                        dismiss()
                    } label: {
                        HStack {
                            Circle()
                                .fill(Color(hex: list.color ?? "#007AFF"))
                                .frame(width: 8, height: 8)
                            Text(list.name)
                                .foregroundColor(.holoTextPrimary)
                            Spacer()
                            if draft.listID == list.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.holoPrimary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(String(localized: "选择清单"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
            }
        }
    }
}
