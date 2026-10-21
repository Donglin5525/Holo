import SwiftUI
import CoreData

struct HabitSourceRoute: Identifiable {
    var habitID: UUID
    var start: Date
    var endExclusive: Date
    var recordNotBefore: Date?
    var metric: GoalRequirementMetric?
    init(habitID: UUID, start: Date, endExclusive: Date, recordNotBefore: Date? = nil, metric: GoalRequirementMetric? = nil) {
        self.recordNotBefore = recordNotBefore; self.metric = metric
        self.habitID = habitID; self.start = start
        let endDay = Calendar.current.startOfDay(for: endExclusive)
        self.endExclusive = endExclusive == endDay ? endExclusive : Calendar.current.date(byAdding: .day, value: 1, to: endDay) ?? endExclusive
    }
    var id: String { "\(habitID)|\(start.timeIntervalSince1970)|\(endExclusive.timeIntervalSince1970)" }

    static func recent(_ id: UUID, now: Date = Date()) -> Self {
        let today = HabitRepository.shared.findHabit(by: id)?.currentDay(now: now) ?? Calendar.current.startOfDay(for: now)
        return Self(habitID: id, start: Calendar.current.date(byAdding: .day, value: -6, to: today) ?? today,
                    endExclusive: Calendar.current.date(byAdding: .day, value: 1, to: today) ?? now)
    }
}

/// 习惯原模块的同窗来源明细；目标和今天只传对象及范围，不维护另一份总数。
struct HabitSourceDetailView: View {
    let route: HabitSourceRoute
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var model = HabitModuleViewModel()
    @ObservedObject private var goals = GoalRepository.shared
    @State private var rows: [RecordRow] = []
    @State private var habit: Habit?
    @State private var confirmations: [Date: HabitDailyConfirmationFact] = [:]
    @State private var showDays = false
    @State private var editor: Editor?
    @State private var error: String?
    @State private var deleteID: UUID?

    private struct RecordRow: Identifiable {
        var id: UUID; var day: Date; var moment: Date; var createdAt: Date; var value: Double?; var note: String; var completed: Bool
    }
    private enum Editor: Identifiable {
        case record(UUID), numeric, retro, confirmation(Date)
        var id: String { String(describing: self) }
    }

    var body: some View {
        NavigationStack {
            List {
                Group {
                if let habit, !habit.isDeleted, habit.deletedAt == nil {
                    sourceHeader(habit)
                    if habit.isBadHabit || habit.isCheckInType || habit.isCountType {
                        sourceTabs
                    }
                    if showDays {
                        ForEach(days(habit).reversed(), id: \.self) { day in
                            GoalJourneySourceRow(title: GoalAnalysisSection.dayText(day) + (day == habit.currentDay() ? " · 今天" : ""),
                                value: "确认", note: dayStatus(day), identifier: "habit-source-day-\(Int(day.timeIntervalSince1970))") {
                                editor = .confirmation(day)
                            }
                        }
                    } else {
                        if rows.isEmpty {
                            Text(habit.isMeasureType ? "这个范围还没有记录，可以记录一次真实测量。" : "这个范围还没有记录。可以记录一次真实发生，或在每日确认中核对这一天。")
                                .goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
                                .padding(.vertical, 16)
                        }
                        ForEach(rows) { row in
                            sourceRecord(row, habit: habit)
                                .swipeActions { Button("删除", role: .destructive) { deleteID = row.id } }
                                .contextMenu { Button("删除这条记录", role: .destructive) { deleteID = row.id } }
                        }
                    }
                    VStack(spacing: 0) {
                        Button(habit.isCheckInType ? (HabitRepository.shared.findTodayCheckInRecord(for: habit)?.isCompleted == true ? "撤回今天的打卡" : "记录今天已做到") : "记录本次数值") {
                            if habit.isCheckInType {
                                Task { let saved = await model.record(kind: .toggleCheckIn, habitId: route.habitID); reload(); if !saved { error = "没有保存成功，请重试" } }
                            } else { editor = .numeric }
                        }.buttonStyle(GoalJourneyPrimaryStyle()).disabled(habit.isPaused || habit.isArchived)
                        if !habit.isBadHabit {
                            Button("补录过去的记录") { editor = .retro }
                                .goalJourneyText(.supporting).foregroundStyle(GoalJourneyStyle.action)
                                .frame(maxWidth: .infinity, minHeight: 44).disabled(habit.isPaused || habit.isArchived)
                        }
                    }.padding(.top, 16)
                    if !usages.isEmpty {
                        Text("被这些目标使用").goalJourneyText(.body).foregroundStyle(Color.holoToolTextSecondary).padding(.top, 20).padding(.bottom, 6)
                        ForEach(usages) { usage in
                            NavigationLink {
                                GoalDetailView(goal: usage.goal, onOpenLinkedEntity: { DeepLinkState.shared.navigate(to: $0) }, onDeleteRequested: { id in
                                    do { try goals.deleteGoal(id: id) } catch { self.error = error.localizedDescription }
                                })
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(usage.goal.title).goalJourneyText(.row).foregroundStyle(Color.holoToolText)
                                    Text(usage.detail).goalJourneyText(.detail).foregroundStyle(Color.holoToolTextSecondary)
                                }.padding(.vertical, 13).frame(minHeight: 68, alignment: .leading)
                            }.accessibilityIdentifier("habit-source-goal-" + usage.goal.id.uuidString)
                        }
                        Text("一次记录，分别按各目标的约定读取。修改原记录后，相关目标一起重算。")
                            .goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary).padding(.vertical, 12)
                    }
                } else {
                    Text("来源已删除或暂不可用，请返回核对关联。")
                }
                if let error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).goalJourneyText(.supporting).foregroundStyle(Color.holoToolError)
                        Button("重新读取") { reload() }.frame(minHeight: 44)
                    }
                }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: GoalJourneyStyle.pageInset, bottom: 0, trailing: GoalJourneyStyle.pageInset))
            }
            .listStyle(.plain).environment(\.defaultMinListRowHeight, 0)
            .listRowSpacing(0)
            .scrollContentBackground(.hidden)
            .background(Color.holoToolBackground)
            .tint(GoalJourneyStyle.action)
            .navigationTitle(habit?.name ?? "习惯来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $editor) { target in editorView(target) }
            .confirmationDialog("删除这条原记录？", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
                Button("删除这条记录", role: .destructive) {
                    guard let id = deleteID else { return }; deleteID = nil
                    Task { let saved = await model.record(kind: .deleteRecord(recordId: id), habitId: route.habitID); reload(); if !saved { error = "没有删除成功，请重试" } }
                }
            } message: { Text("读取这条记录的目标都会重算，历史报告保留当时内容。") }
        }
        .onAppear { goals.loadGoals(); model.refresh(); reload() }
        .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .goalDataDidChange)) { _ in goals.loadGoals() }
    }

    private func sourceHeader(_ habit: Habit) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("习惯 · 原模块明细").goalJourneyText(.metadata).foregroundStyle(Color.holoToolTextSecondary).padding(.top, 8)
            Text("\(GoalAnalysisSection.dayText(route.start))–\(GoalAnalysisSection.dayText(route.endExclusive.addingTimeInterval(-1)))")
                .goalJourneyText(.heading).padding(.top, 7)
            Text(summary(habit)).goalJourneyText(.amount).monospacedDigit().padding(.top, 12).accessibilityIdentifier("habit-source-summary")
            Text(route.metric == .eventCount ? "次数按原记录条数计算；点某条改数值，误记请删除那一条。" : (route.metric == .latest || (route.metric == nil && habit.isMeasureType)) ? "显示最新一次真实测量。" : "汇总由下面的原始记录计算；修改具体记录后会重新计算。")
                .goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary).lineSpacing(5).padding(.vertical, 11)
            if habit.isBadHabit {
                Text("\(confirmations.values.filter { $0.isValid && $0.status != .asOf }.count) / \(days(habit).count) 天已明确确认；其余只显示已记录量。")
                    .goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary).padding(.bottom, 11)
            }
        }.foregroundStyle(Color.holoToolText)
    }

    private var sourceTabs: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 24))
        return layout {
            sourceTab("记录明细", days: false)
            sourceTab("每日确认", days: true)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
        }.overlay(alignment: .bottom) { Rectangle().fill(Color.holoToolBorder).frame(height: 0.5) }
    }
    private func sourceTab(_ title: String, days: Bool) -> some View {
        Button { showDays = days } label: {
            Text(title).goalJourneyText(.body).foregroundStyle(showDays == days ? GoalJourneyStyle.action : Color.holoToolTextSecondary)
                .frame(minHeight: 48)
                .fixedSize(horizontal: true, vertical: false)
                .overlay(alignment: .bottom) { if showDays == days { Rectangle().fill(GoalJourneyStyle.action).frame(height: 2) } }
        }.buttonStyle(.plain).accessibilityAddTraits(showDays == days ? .isSelected : [])
    }
    private func sourceRecord(_ row: RecordRow, habit: Habit) -> some View {
        Button { editor = .record(row.id) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(GoalAnalysisSection.dayText(row.day) + " · 原始记录").goalJourneyText(.detail).foregroundStyle(Color.holoToolTextSecondary)
                    Text(row.value.map { HabitPresentationProjector.formatValue($0) + " " + habit.unitText } ?? (row.completed ? "已完成" : "已撤回"))
                        .goalJourneyText(.rowValue).monospacedDigit().foregroundStyle(Color.holoToolText)
                    if !row.note.isEmpty { Text(row.note).goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text("编辑").goalJourneyText(.supporting).foregroundStyle(GoalJourneyStyle.action)
            }.padding(.vertical, 14).frame(minHeight: 78)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.holoToolBorder).frame(height: 0.5) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("habit-source-record-" + row.id.uuidString)
    }

    private struct Usage: Identifiable {
        let goal: Goal
        let detail: String
        var id: UUID { goal.id }
    }
    /// 反向关联只读当前版本，不为了展示来源页给其他目标新建计划。
    private var usages: [Usage] {
        goals.goals.compactMap { goal in
            guard !goal.isDeleted, goal.deletedAt == nil else { return nil }
            let payload: GoalPlanPayloadV2
            if let row = GoalPlanRevisionStore.latestRevisionRow(goalID: goal.id, in: CoreDataStack.shared.viewContext) {
                switch row.planPayloadDecodeResult {
                case .current(let plan): payload = plan
                case .legacyDecisionSummary, .empty: payload = GoalPlanResolver.legacyBaselinePayload(goal: goal, legacySummary: nil, now: Date())
                case .unsupportedFuture, .corrupted: return nil
                }
            } else { payload = GoalPlanResolver.legacyBaselinePayload(goal: goal, legacySummary: nil, now: Date()) }
            guard let binding = GoalPlanResolver.resolveBindings(goal: goal, payload: payload, at: Date()).first(where: {
                $0.binding.entityType == .habit && $0.binding.entityID == route.habitID
            })?.binding else { return nil }
            return Usage(goal: goal, detail: GoalPlanEditPresentation.summary(binding))
        }
    }

    @ViewBuilder private func editorView(_ target: Editor) -> some View {
        switch target {
        case .record(let id):
            if let record = record(id), let habit {
                HabitRecordEditSheet(record: record, kind: habit.isCheckInType ? .checkIn : habit.isMeasureType ? .measure : .count, unit: habit.unit) { value, note in
                    await model.record(kind: .updateRecord(recordId: id, value: value, note: note), habitId: route.habitID)
                }
            }
        case .numeric:
            if let snapshot = model.todayRows.first(where: { $0.id == route.habitID }) {
                HabitMeasureInputSheet(snapshot: snapshot) { value, note in
                    await model.record(kind: .addNumeric(value: value), habitId: route.habitID, note: note)
                }
            }
        case .retro:
            if let habit { HabitRetroactiveSheet(context: HabitRetroactiveSheetContext(habit: habit, preselectedDay: nil, mode: habit.isCheckInType ? .sign : .backfill)) }
        case .confirmation(let day):
            if let habit { HabitDayConfirmationSheet(habit: habit, day: day) }
        }
    }

    private func record(_ id: UUID) -> HabitRecord? {
        let request = HabitRecord.fetchRequest(); request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
        return try? HabitRepository.shared.context.fetch(request).first
    }
    private func reload() {
        let repo = HabitRepository.shared
        habit = repo.findHabit(by: route.habitID)
        guard let habit else { rows = []; return }
        let lastDay = Calendar.current.startOfDay(for: route.endExclusive.addingTimeInterval(-1))
        do {
        rows = try repo.fetchRecords(for: habit, from: route.start, through: lastDay).filter { ($0.isRetroactive || $0.date <= Date()) && $0.date >= (route.recordNotBefore ?? .distantPast) }.map {
            RecordRow(id: $0.id, day: $0.attributedDay(dayEndMinutes: habit.dayEndMinutes), moment: $0.date, createdAt: $0.createdAt, value: $0.valueDouble, note: $0.note ?? "", completed: $0.isCompleted)
        }.sorted { $0.moment == $1.moment ? $0.createdAt > $1.createdAt : $0.moment > $1.moment }
            confirmations = [:]
            for day in days(habit) { confirmations[day] = try repo.dailyConfirmation(for: habit, on: day) }
            error = nil
        } catch { self.error = "暂时无法读取完整来源，请重试；当前保留上次读取内容" }
    }
    private func summary(_ habit: Habit) -> String {
        if rows.isEmpty {
            let displayUnit = route.metric == .eventCount ? "次" : route.metric == .recordedDays ? "天" : habit.unitText
            if confirmations.values.contains(where: { $0.isValid && $0.status == .asOf }) { return "截至现在 0 \(displayUnit) · 今天仍在进行" }
            let confirmed = confirmations.values.filter { $0.isValid && $0.status != .asOf }
            if confirmed.contains(where: { $0.status == .none }) { return "0 \(displayUnit) · \(confirmed.count) 天已确认，其余待核对" }
            if !confirmed.isEmpty { return "0 天做到 · \(confirmed.count) 天已确认" }
            return "尚未记录"
        }
        let eligible = habit.isCheckInType ? rows.filter(\.completed) : rows
        if habit.isCheckInType, eligible.isEmpty, !confirmations.values.contains(where: { $0.isValid }) { return "尚未记录完成情况" }
        if route.metric == .eventCount { return "\(eligible.count) 次" }
        if route.metric == .recordedDays || (route.metric == nil && habit.isCheckInType) { return "\(Set(eligible.map(\.day)).count) 天有记录" }
        let values = rows.compactMap(\.value)
        let latest = route.metric == .latest || (route.metric == nil && habit.isMeasureType)
        let value = latest ? values.first : values.isEmpty ? nil : values.reduce(0, +)
        return value.map { HabitPresentationProjector.formatValue($0) + " " + habit.unitText } ?? "尚无测量"
    }
    private func days(_ habit: Habit) -> [Date] {
        var day = Calendar.current.startOfDay(for: max(route.start, habit.createdAt))
        let end = min(route.endExclusive, habit.currentDay().addingTimeInterval(1))
        var result: [Date] = []
        while day < end {
            result.append(day)
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: day) else { break }; day = next
        }
        return result
    }
    private func dayStatus(_ day: Date) -> String {
        if let fact = confirmations[day] { return fact.isValid ? fact.status.title : "记录已变化，待重核" }
        return rows.contains { $0.day == day } ? "有记录，待确认" : "尚未记录"
    }
}

struct HabitDayConfirmationSheet: View {
    let habit: Habit
    let day: Date
    @Environment(\.dismiss) private var dismiss
    @State private var status: HabitDailyConfirmationStatus?
    @State private var error: String?
    @State private var saving = false
    private var choices: [HabitDailyConfirmationStatus] {
        if habit.isCheckInType && !habit.isBadHabit { return day >= habit.currentDay() ? [.met] : [.met, .notMet] }
        return day >= habit.currentDay() ? [.asOf] : [.none, .complete]
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("习惯 · " + habit.name).goalJourneyText(.metadata).foregroundStyle(Color.holoToolTextSecondary)
                    Text(GoalAnalysisSection.dayText(day) + "\n实际是什么情况？").goalJourneyText(.title)
                    GoalJourneyField(title: "事实状态") {
                        Picker("实际情况", selection: $status) {
                            Text("请选择实际情况").tag(Optional<HabitDailyConfirmationStatus>.none)
                            ForEach(choices, id: \.self) { choice in Text(choice.title).tag(Optional(choice)) }
                        }.labelsHidden()
                    }
                    Text("确认只说明这一天的事实。缺记录不当失败，今天未结束时不提前判断整日达成。")
                        .goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary).lineSpacing(5)
                    if let error { Text(error).foregroundStyle(Color.holoToolError) }
                    Button("保存确认") { save(status) }.buttonStyle(GoalJourneyPrimaryStyle()).disabled(status == nil || saving)
                    Button("撤回这一天的确认", role: .destructive) { save(.withdrawn) }
                        .goalJourneyText(.supporting).frame(maxWidth: .infinity, minHeight: 44).disabled(saving)
                }.padding(GoalJourneyStyle.pageInset)
            }.background(Color.holoToolBackground).foregroundStyle(Color.holoToolText).tint(GoalJourneyStyle.action)
            .navigationTitle("每日确认").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .medium)).foregroundColor(.holoToolTextSecondary) }
                            .accessibilityLabel(Text("关闭")).disabled(saving) } }
        }.interactiveDismissDisabled(saving)
    }
    private func save(_ value: HabitDailyConfirmationStatus?) {
        guard let value, !saving else { return }; saving = true
        defer { saving = false }
        do { try HabitRepository.shared.confirmDay(habitID: habit.id, day: day, status: value); dismiss() }
        catch { self.error = "没有保存。请核对原打卡记录；实际做到请先记录，没做到时请先撤回该日误记。" }
    }
}
