import SwiftUI
#if canImport(UIKit)
#else
import AppKit
#endif
import Combine
import CoreData

@MainActor
final class GoalProgressFactsModel: ObservableObject {
    @Published var state: GoalReviewState?
    @Published var error: String?
    @Published var initialPlan: GoalPlanPayloadV2?
    @Published var recentTransactions: [Transaction] = []
    @Published var recentHabitRecords: [HabitRecord] = []
    @Published var sourceHabit: Habit?
    @Published var sourceAccountName: String?

    func load(_ goal: Goal) {
        guard goal.managedObjectContext != nil, !goal.isDeleted, goal.deletedAt == nil else {
            state = nil
            recentTransactions = []
            recentHabitRecords = []
            sourceHabit = nil
            sourceAccountName = nil
            return
        }
        do {
            let loadedState = try GoalReviewCoordinator.shared.loadState(goal: goal)
            state = loadedState
            initialPlan = GoalPlanRevisionStore.allRevisionRows(goalID: goal.id, in: CoreDataStack.shared.viewContext).first?.planPayloadV2
            loadRecentSourceActivity(for: goal, state: loadedState)
            error = nil
        } catch { self.error = GoalPlanEditService.message(for: error) }
    }

    private func loadRecentSourceActivity(for goal: Goal, state: GoalReviewState) {
        recentTransactions = []
        recentHabitRecords = []
        sourceHabit = nil
        sourceAccountName = nil

        guard goal.isQuantitative else { return }
        switch goal.metricSourceEnum {
        case .habit:
            let habit = GoalMetricEvaluator.sourceHabit(for: goal)
            sourceHabit = habit
            if let habit {
                let records = HabitRepository.shared.getRecords(for: habit, in: nil)
                recentHabitRecords = Array(records.filter { $0.valueDouble != nil }.prefix(3))
            }
        case .ledger:
            let scope = state.plan.payload.resultSource?.ledgerScope ?? goal.ledgerScopePayload
            let accountID = scope?.accountID ?? state.plan.payload.resultSource?.sourceID
            if let accountID, let account = FinanceRepository.shared.findAccount(by: accountID) {
                sourceAccountName = account.name
            } else {
                sourceAccountName = String(localized: "全部账本")
            }
            recentTransactions = fetchRecentTransactions(accountID: accountID, limit: 3)
        case .manual, .healthKit:
            break
        }
    }

    private func fetchRecentTransactions(accountID: UUID?, limit: Int) -> [Transaction] {
        let context = CoreDataStack.shared.viewContext
        let request = Transaction.fetchRequest()
        var predicates: [NSPredicate] = [
            NSPredicate(format: "deletedAt == nil"),
            FinanceTransactionOccurrencePolicy.occurredPredicate()
        ]
        if let accountID {
            predicates.append(NSPredicate(format: "account.id == %@", accountID as CVarArg))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        request.fetchLimit = limit
        request.relationshipKeyPathsForPrefetching = ["category", "account"]
        return DuplicateRowFilter.deduplicatingCopies((try? context.fetch(request)) ?? [])
    }
}

enum GoalFactsPresentation {
    static func progress(_ result: GoalResultObservation) -> GoalJourneyProgress? {
        guard result.status == .observed || result.status == .stale,
              let fraction = result.progressFraction else { return nil }
        return GoalJourneyProgress(value: result.moneyValue.map { NSDecimalNumber(decimal: $0).doubleValue } ?? result.value,
            target: result.targetValue, evaluatedFraction: fraction)
    }
    static func progress(_ item: GoalRequirementObservation) -> GoalJourneyProgress? {
        guard item.state != .unavailable, item.state != .missing,
              item.requirement.metric != .taskCompletion else { return nil }
        switch item.requirement.comparison {
        case .reach: return GoalJourneyProgress(value: item.value, target: item.requirement.target)
        case .stayBelow: return GoalJourneyProgress(value: item.value, target: item.requirement.target, kind: .allowance)
        case .trendDown, .trendUp: return nil // 没有基线，不能用当前值/目标值冒充改善比例。
        }
    }
    static func evidence(_ item: GoalRequirementObservation) -> String {
        guard item.expectedDays > 0, item.confirmedDays > 0 || item.requirement.comparison == .stayBelow else { return "" }
        return "\(item.confirmedDays) / \(item.expectedDays) 天已明确确认"
    }
    static func result(_ snapshot: GoalEvaluationSnapshot) -> String {
        let r = snapshot.result
        guard r.status == .observed || r.status == .stale else {
            if r.status == .notApplicable {
                let conditions = (snapshot.requirements ?? []).filter { $0.role == .result }
                if !conditions.isEmpty { return conditions.prefix(2).map { "\($0.title) \($0.valueText)" }.joined(separator: " · ") }
                return "行动分别记录，成果待确认"
            }
            return r.status == .unavailable ? "结果来源暂不可用" : "结果待记录"
        }
        if let money = r.moneyValue {
            return GoalJourneyNarrative.money(money) + (r.targetValue.map { " / " + GoalJourneyNarrative.money(Decimal($0)) } ?? "")
                + (r.status == .stale ? " · 观测已过期" : "")
        }
        let number = r.value.map { GoalMetricEvaluator.formatValue($0) }
        let target = r.targetValue.map { " / " + GoalMetricEvaluator.formatValue($0) } ?? ""
        return (number ?? "待记录") + target + (r.unit.map { " " + $0 } ?? "") + (r.status == .stale ? " · 观测已过期" : "")
    }
}

enum GoalOriginalSourceSelection: Identifiable {
    case habit(HabitSourceRoute), account(UUID), task(UUID), manual(UUID), budget(UUID?), ledger
    var id: String { String(describing: self) }
}

struct GoalOriginalSourceSheet: View {
    let selection: GoalOriginalSourceSelection
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        switch selection {
        case .habit(let route): HabitSourceDetailView(route: route)
        case .account(let id):
            NavigationStack {
                if let account = FinanceRepository.shared.findAccount(by: id) {
                    AccountDetailView(account: account)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
                } else { Text("账户已删除或暂不可用") }
            }
        case .task(let id):
            if let task = TodoRepository.shared.findTask(by: id) { TaskDetailView(task: task, repository: .shared) }
            else { Text("任务已删除或暂不可用") }
        case .manual(let id):
            if let goal = GoalRepository.shared.findGoal(by: id) { GoalMetricLogSheet(goal: goal) }
            else { Text("目标已删除") }
        case .budget(let id): BudgetDetailView(anchoredAccountId: id)
        case .ledger: FinanceView()
        }
    }
}

/// 目标详情主内容区：单页自然流（Hero 进度卡 → 数据源/记录明细 → 本目标推进步骤 → AI 复盘）。
struct GoalProgressScrollSection: View {
    @ObservedObject var goal: Goal
    var closedLoopEnabled: Bool = HoloAIFeatureFlags.goalClosedLoopEnabled
    var onOpenLinkedEntity: (DeepLinkTarget) -> Void = { _ in }
    var onNewTask: () -> Void = {}
    var onNewHabit: () -> Void = {}
    var onLinkExisting: () -> Void = {}
    var onOpenPlanEditor: () -> Void = {}

    @StateObject private var model = GoalProgressFactsModel()
    @State private var source: GoalOriginalSourceSelection?
    @State private var report: ChatMessageViewData?
    @State private var actionError: String?

    private let changes = Publishers.Merge3(
        NotificationCenter.default.publisher(for: .habitDataDidChange),
        NotificationCenter.default.publisher(for: .financeDataDidChange),
        NotificationCenter.default.publisher(for: .todoDataDidChange)
    )

    var body: some View {
        if goal.managedObjectContext == nil || goal.isDeleted || goal.deletedAt != nil {
            EmptyView()
        } else {
        VStack(alignment: .leading, spacing: HoloSpacing.lg) {
            heroCard

            if let error = model.error {
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text(error).goalJourneyText(.supporting).foregroundStyle(Color.holoToolError)
                    Button("重新读取") { model.load(goal) }.frame(minHeight: 44)
                }
            } else if let state = model.state {
                factsSection(state)
                stepsSection(state)
                if closedLoopEnabled {
                    GoalAnalysisSection(goal: goal, onOpenLinkedEntity: onOpenLinkedEntity)
                } else {
                    legacyReportsSection(state)
                }
            } else {
                ProgressView("正在读取")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HoloSpacing.xl)
            }
        }
        .sheet(item: $source, onDismiss: { model.load(goal) }) { item in
            GoalOriginalSourceSheet(selection: item)
        }
        #if canImport(UIKit)
        .fullScreenCover(item: $report) { message in
            ReportDetailRoute(message: message, chatViewModel: nil, onDismiss: { model.load(goal) })
        }
        #else
        .sheet(item: $report) { message in
            ReportDetailRoute(message: message, chatViewModel: nil, onDismiss: { model.load(goal) })
        }
        #endif
        .alert("操作失败", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task {
            await CoreDataStack.shared.waitUntilReady()
            model.load(goal)
        }
        .onReceive(changes.debounce(for: .milliseconds(100), scheduler: RunLoop.main)) { _ in model.load(goal) }
        .onReceive(NotificationCenter.default.publisher(for: .goalDataDidChange)) { _ in model.load(goal) }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in model.load(goal) }
        #else
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.load(goal) }
        #endif
        }
    }

    // MARK: - Hero 进度卡

    private var heroCard: some View {
        let metric = GoalMetricEvaluator.evaluate(goal: goal)
        let snapshot = model.state?.snapshot
        return VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(alignment: .top, spacing: HoloSpacing.md) {
                Text(goal.displayIcon)
                    .font(.system(size: 22))
                    .frame(width: 44, height: 44)
                    .background(goal.goalDomain.badgeColor.opacity(0.12), in: RoundedRectangle(cornerRadius: HoloRadius.md))

                VStack(alignment: .leading, spacing: 4) {
                    Text(goal.title)
                        .goalJourneyText(.heading)
                        .foregroundStyle(Color.holoToolText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(heroSourceBadgeText ?? goal.goalDomain.displayName)
                        if let deadlineText = deadlineBadgeText {
                            Text("·")
                            Text(deadlineText)
                        }
                    }
                    .goalJourneyText(.metadata)
                    .foregroundStyle(isOverdue ? Color.holoToolWarning : Color.holoToolTextSecondary)
                }

                Spacer(minLength: 0)

                if goal.goalStatus != .active {
                    statusPill
                }
            }

            if goal.isQuantitative {
                quantitativeHeroBlock(snapshot: snapshot, metric: metric)
            } else {
                processHeroBlock
            }

            heroPrimaryAction(snapshot: snapshot)
        }
        .padding(HoloSpacing.lg)
        .holoSurface()
    }

    @ViewBuilder
    private func quantitativeHeroBlock(snapshot: GoalEvaluationSnapshot?, metric: GoalMetricProgress?) -> some View {
        let progress = snapshot.flatMap { GoalFactsPresentation.progress($0.result)?.fraction } ?? metric?.progress
        let pct = progress.map { Int(($0 * 100).rounded()) }
        let headline = heroHeadline(snapshot: snapshot, metric: metric)
        let subline = heroSubline(snapshot: snapshot, metric: metric)

        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.holoToolText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Spacer(minLength: 8)
                if let pct {
                    Text("\(pct)%")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(GoalJourneyStyle.action)
                        .padding(.horizontal, HoloSpacing.sm)
                        .padding(.vertical, 4)
                        .background(GoalJourneyStyle.action.opacity(0.10), in: Capsule())
                }
            }

            HoloProgress(
                value: progress,
                color: GoalJourneyStyle.action,
                shape: .bar,
                lineWidth: 6,
                trackColor: Color.holoToolBorder.opacity(0.6)
            )

            if let subline {
                Text(subline)
                    .goalJourneyText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
        }
    }

    @ViewBuilder
    private var processHeroBlock: some View {
        let tasks = goal.sortedTasks
        let taskCount = tasks.count
        let doneCount = tasks.filter(\.completed).count
        let habitCount = goal.sortedHabits.count
        if taskCount > 0 {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text("已完成 \(doneCount) / \(taskCount) 项")
                        .goalJourneyText(.rowValue)
                        .monospacedDigit()
                        .foregroundStyle(Color.holoToolText)
                    Spacer()
                    if habitCount > 0 {
                        Text("\(habitCount) 个习惯")
                            .goalJourneyText(.metadata)
                            .foregroundStyle(Color.holoToolTextSecondary)
                    }
                }
                HoloProgress(
                    value: Double(doneCount) / Double(max(taskCount, 1)),
                    color: GoalJourneyStyle.action,
                    shape: .bar,
                    lineWidth: 6,
                    trackColor: Color.holoToolBorder.opacity(0.6)
                )
            }
        } else if habitCount > 0 {
            Text("\(habitCount) 个关联习惯")
                .goalJourneyText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
        }
    }

    @ViewBuilder
    private func heroPrimaryAction(snapshot: GoalEvaluationSnapshot?) -> some View {
        if goal.goalStatus != .active {
            Button {
                do {
                    try GoalRepository.shared.updateStatus(goal, status: .active)
                    GoalNotificationService.broadcastGoalDataChange()
                } catch {
                    actionError = error.localizedDescription
                }
            } label: {
                Text("恢复进行中")
            }
            .buttonStyle(GoalJourneyPrimaryStyle())
        } else if goal.isQuantitative {
            switch goal.metricSourceEnum {
            case .ledger:
                Button {
                    openLedgerSource(snapshot: snapshot)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wallet.bifold")
                        Text("去财务记一笔")
                    }
                }
                .buttonStyle(GoalJourneyPrimaryStyle())
            case .habit:
                if let habit = GoalMetricEvaluator.sourceHabit(for: goal) {
                    Button {
                        let start = snapshot?.windowStart ?? Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
                        let end = snapshot?.windowEndExclusive ?? Date()
                        source = .habit(HabitSourceRoute(habitID: habit.id, start: start, endExclusive: end))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle")
                            Text("去记录「\(habit.name)」")
                        }
                    }
                    .buttonStyle(GoalJourneyPrimaryStyle())
                } else {
                    Text("数据源习惯已不可用")
                        .goalJourneyText(.metadata)
                        .foregroundStyle(Color.holoToolWarning)
                }
            case .manual:
                Button {
                    source = .manual(goal.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text(goal.goalKindEnum == .target ? String(localized: "记当前数值") : String(localized: "记一笔"))
                    }
                }
                .buttonStyle(GoalJourneyPrimaryStyle())
            case .healthKit:
                Button {
                    Task { await GoalHealthKitCache.shared.refreshIfNeeded(for: goal) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "heart.fill")
                        Text("同步苹果健康数据")
                    }
                }
                .buttonStyle(GoalJourneyPrimaryStyle())
            }
        } else {
            Button {
                onNewTask()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("添加任务")
                }
            }
            .buttonStyle(GoalJourneyPrimaryStyle())
        }
    }

    // MARK: - 数据源与记录

    @ViewBuilder
    private func factsSection(_ state: GoalReviewState) -> some View {
        let resultRequirements = (state.snapshot.requirements ?? []).filter { $0.role == .result }
        let hasMultiSourcePlan = !resultRequirements.isEmpty || !state.snapshot.constraints.isEmpty
        let hasResultRow = state.snapshot.result.sourceKind != nil

        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            if hasMultiSourcePlan {
                if hasResultRow {
                    GoalJourneySourceRow(
                        title: state.snapshot.result.moneyValue != nil
                            ? (state.snapshot.result.sourceLabel.hasPrefix("全账本") ? "净结余变化" : state.snapshot.result.sourceLabel)
                            : state.snapshot.result.sourceLabel,
                        value: GoalFactsPresentation.result(state.snapshot),
                        note: state.snapshot.result.sourceLabel,
                        identifier: "goal-result-source",
                        progress: GoalFactsPresentation.progress(state.snapshot.result)
                    ) {
                        openResult(state)
                    }
                }

                ForEach(resultRequirements) { item in
                    GoalJourneySourceRow(
                        title: item.title,
                        value: item.valueText,
                        note: (item.requirement.calendarMonth ? "本月" : "最近\(item.requirement.windowDays)天") + " · " + roleName(item.role),
                        identifier: "goal-source-" + item.title,
                        progress: GoalFactsPresentation.progress(item),
                        evidence: GoalFactsPresentation.evidence(item)
                    ) { openRequirement(item) }
                }
            } else if goal.isQuantitative {
                switch goal.metricSourceEnum {
                case .ledger:
                    recentLedgerActivitySection(state)
                case .habit:
                    recentHabitActivitySection(state)
                case .manual:
                    manualLogsSection
                case .healthKit:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func recentLedgerActivitySection(_ state: GoalReviewState) -> some View {
        let accountLabel = model.sourceAccountName ?? state.snapshot.result.sourceLabel
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("\(accountLabel) · 最近记录")
                    .goalJourneyText(.supporting)
                    .foregroundStyle(Color.holoToolTextSecondary)
                Spacer()
                Button {
                    openResult(state)
                } label: {
                    HStack(spacing: 2) {
                        Text("账户明细")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                    }
                    .goalJourneyText(.metadata)
                    .foregroundStyle(GoalJourneyStyle.action)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("goal-result-source")
            }

            if model.recentTransactions.isEmpty {
                Text("暂无入账记录，去财务记一笔后会自动同步到这里")
                    .goalJourneyText(.supporting)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HoloSpacing.md)
                    .holoSurface()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.recentTransactions.enumerated()), id: \.element.id) { index, tx in
                        let title: String = {
                            if let note = tx.note, !note.isEmpty { return note }
                            return tx.category?.name ?? (tx.transactionType == .income ? String(localized: "收入") : String(localized: "支出"))
                        }()
                        HStack(spacing: HoloSpacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                    .goalJourneyText(.row)
                                    .foregroundStyle(Color.holoToolText)
                                    .lineLimit(1)
                                Text(GoalListCard.dayText(tx.date))
                                    .goalJourneyText(.metadata)
                                    .foregroundStyle(Color.holoToolTextSecondary)
                            }
                            Spacer()
                            Text(tx.formattedAmountWithSign)
                                .goalJourneyText(.rowValue)
                                .monospacedDigit()
                                .foregroundStyle(tx.transactionType == .income ? Color.holoToolSuccess : Color.holoToolText)
                        }
                        .padding(.horizontal, HoloSpacing.md)
                        .padding(.vertical, 12)
                        if index < model.recentTransactions.count - 1 {
                            Rectangle()
                                .fill(Color.holoToolBorder.opacity(0.6))
                                .frame(height: 0.5)
                                .padding(.leading, HoloSpacing.md)
                        }
                    }
                }
                .holoSurface()
            }
        }
    }

    @ViewBuilder
    private func recentHabitActivitySection(_ state: GoalReviewState) -> some View {
        let habitTitle = model.sourceHabit?.name ?? state.snapshot.result.sourceLabel
        let unitSuffix = model.sourceHabit?.unitText.isEmpty == false ? " \(model.sourceHabit!.unitText)" : (goal.metricUnit.map { " \($0)" } ?? "")
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("\(habitTitle) · 最近同步记录")
                    .goalJourneyText(.supporting)
                    .foregroundStyle(Color.holoToolTextSecondary)
                Spacer()
                Button {
                    openResult(state)
                } label: {
                    HStack(spacing: 2) {
                        Text("查看习惯")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                    }
                    .goalJourneyText(.metadata)
                    .foregroundStyle(GoalJourneyStyle.action)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("goal-result-source")
            }

            if model.recentHabitRecords.isEmpty {
                Text("还没有数值记录，点上方按钮去记一次")
                    .goalJourneyText(.supporting)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HoloSpacing.md)
                    .holoSurface()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.recentHabitRecords.enumerated()), id: \.element.id) { index, record in
                        let valueText = record.valueDouble.map { GoalMetricEvaluator.formatValue($0) + unitSuffix } ?? "--"
                        HStack(spacing: HoloSpacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.note.flatMap { $0.isEmpty ? nil : $0 } ?? habitTitle)
                                    .goalJourneyText(.row)
                                    .foregroundStyle(Color.holoToolText)
                                    .lineLimit(1)
                                Text(record.formattedDate)
                                    .goalJourneyText(.metadata)
                                    .foregroundStyle(Color.holoToolTextSecondary)
                            }
                            Spacer()
                            Text(valueText)
                                .goalJourneyText(.rowValue)
                                .monospacedDigit()
                                .foregroundStyle(GoalJourneyStyle.action)
                        }
                        .padding(.horizontal, HoloSpacing.md)
                        .padding(.vertical, 12)
                        if index < model.recentHabitRecords.count - 1 {
                            Rectangle()
                                .fill(Color.holoToolBorder.opacity(0.6))
                                .frame(height: 0.5)
                                .padding(.leading, HoloSpacing.md)
                        }
                    }
                }
                .holoSurface()
            }
        }
    }

    @ViewBuilder
    private var manualLogsSection: some View {
        let logs = GoalRepository.shared.getMetricLogs(for: goal)
        let unitSuffix = goal.metricUnit.map { " \($0)" } ?? ""
        if !logs.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                HStack {
                    Text("记录明细")
                        .goalJourneyText(.supporting)
                        .foregroundStyle(Color.holoToolTextSecondary)
                    Spacer()
                    Text("\(logs.count) 条")
                        .goalJourneyText(.metadata)
                        .foregroundStyle(Color.holoToolTextSecondary)
                }
                .padding(.top, HoloSpacing.xs)

                VStack(spacing: 0) {
                    ForEach(logs, id: \.id) { log in
                        HStack(spacing: HoloSpacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(goal.goalKindEnum == .target ? "" : "+ ")\(GoalMetricEvaluator.formatValue(log.value))\(unitSuffix)")
                                    .goalJourneyText(.rowValue)
                                    .monospacedDigit()
                                    .foregroundStyle(Color.holoToolText)
                                Text(GoalMetricEvaluator.displayDateFormatter.string(from: log.date) + (log.note.map { $0.isEmpty ? "" : " · \($0)" } ?? ""))
                                    .goalJourneyText(.metadata)
                                    .foregroundStyle(Color.holoToolTextSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                do {
                                    try GoalRepository.shared.deleteMetricLog(log, for: goal)
                                    GoalNotificationService.broadcastGoalDataChange()
                                } catch {
                                    actionError = error.localizedDescription
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.holoToolTextSecondary)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, HoloSpacing.md)
                        .padding(.vertical, 4)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.holoToolBorder).frame(height: 0.5).padding(.leading, HoloSpacing.md)
                        }
                    }
                }
                .holoSurface()
            }
        }
    }

    // MARK: - 推进步骤（仅本目标下的任务、习惯与约束；直接新建而非平铺全库）

    @ViewBuilder
    private func stepsSection(_ state: GoalReviewState) -> some View {
        let tasks = goal.sortedTasks
        let habits = goal.sortedHabits
        let requirements = (state.snapshot.requirements ?? []).filter { $0.role != .result }
        let configured = Set((state.snapshot.requirements ?? []).map(\.id)).union(state.snapshot.constraints.map(\.id))
        let executions = state.snapshot.execution.filter { !configured.contains($0.id) }
        let constraints = state.snapshot.constraints
        let hasPlanSteps = !requirements.isEmpty || !executions.isEmpty || !constraints.isEmpty
        let hasAnyStep = !tasks.isEmpty || !habits.isEmpty || hasPlanSteps

        if !hasAnyStep && goal.isQuantitative {
            // 量化目标尚未拆解步骤时只留一行克制入口，不占大块空白
            HStack {
                addStepMenu(label: String(localized: "+ 拆解任务或习惯"))
                Spacer()
            }
        } else {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                HStack {
                    Text("推进步骤")
                        .goalJourneyText(.body)
                        .foregroundStyle(Color.holoToolTextSecondary)
                    Spacer()
                    addStepMenu(label: String(localized: "+ 添加"))
                }

                if !hasAnyStep {
                    Button(action: onNewTask) {
                        HStack(spacing: HoloSpacing.sm) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(GoalJourneyStyle.action)
                            Text("添加第一个任务")
                                .goalJourneyText(.supporting)
                                .foregroundStyle(Color.holoToolText)
                            Spacer()
                        }
                        .padding(HoloSpacing.md)
                        .holoSurface()
                    }
                    .buttonStyle(HoloPressStyle())
                } else {
                    if !tasks.isEmpty || !habits.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(tasks.renderable, id: \.id) { task in
                                taskStepRow(task)
                            }
                            ForEach(habits.renderable, id: \.id) { habit in
                                habitStepRow(habit, snapshot: state.snapshot)
                            }
                        }
                        .holoSurface()
                    }

                    ForEach(requirements) { item in
                        GoalJourneySourceRow(
                            title: item.title,
                            value: item.valueText,
                            note: (item.requirement.calendarMonth ? "本月" : "最近\(item.requirement.windowDays)天") + " · " + (item.role == .constraint ? item.stateText : roleName(item.role)),
                            identifier: "goal-source-" + item.title,
                            progress: GoalFactsPresentation.progress(item),
                            evidence: GoalFactsPresentation.evidence(item)
                        ) { openRequirement(item) }
                    }

                    ForEach(executions.filter { $0.entityType != .task && $0.entityType != .habit }) { item in
                        GoalJourneySourceRow(title: item.title, value: executionValue(item), note: roleName(item.role), identifier: "goal-source-" + item.title) {
                            open(entityType: item.entityType, id: item.entityID, start: state.snapshot.windowStart, end: state.snapshot.windowEndExclusive)
                        }
                    }

                    ForEach(constraints) { item in
                        GoalJourneySourceRow(
                            title: item.title,
                            value: item.observedValue.map { "\($0) / \(item.limitValue) \(item.unit ?? "")" } ?? "待确认",
                            note: item.windowLabel + " · " + (item.isBreached == true ? "已超约定" : "进行中"),
                            identifier: "goal-source-" + item.title,
                            progress: item.isUnavailable ? nil : GoalJourneyProgress(value: item.observedValue.map { NSDecimalNumber(decimal: $0).doubleValue }, target: NSDecimalNumber(decimal: item.limitValue).doubleValue, kind: .allowance),
                            evidence: item.expectedDays.map { "\(item.confirmedDays ?? 0) / \($0) 天已明确确认" } ?? ""
                        ) {
                            if item.kind == .budget { source = .budget(state.plan.payload.budgetRule?.accountID) }
                            else if let rule = state.plan.payload.constraints.first(where: { $0.bindingID == item.id }) {
                                open(entityType: .habit, id: rule.habitID, start: item.windowStart ?? state.snapshot.windowStart, end: item.windowEndExclusive ?? state.snapshot.windowEndExclusive)
                            } else {
                                onOpenPlanEditor()
                            }
                        }
                    }
                }
            }
        }
    }

    private func addStepMenu(label: String) -> some View {
        Menu {
            Button {
                onNewTask()
            } label: {
                Label("新建任务", systemImage: "checklist")
            }
            Button {
                onNewHabit()
            } label: {
                Label("新建习惯", systemImage: "checkmark.circle")
            }
            Divider()
            Button {
                onLinkExisting()
            } label: {
                Label("关联已有任务或习惯", systemImage: "link")
            }
        } label: {
            Text(label)
                .goalJourneyText(.supporting)
                .foregroundStyle(GoalJourneyStyle.action)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
    }

    private func taskStepRow(_ task: TodoTask) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Button {
                do {
                    try TodoRepository.shared.toggleTaskCompletion(task)
                    GoalNotificationService.broadcastGoalDataChange()
                    HapticManager.light()
                } catch {
                    actionError = error.localizedDescription
                }
            } label: {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(task.completed ? GoalJourneyStyle.action : Color.holoToolBorder)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                source = .task(task.id)
            } label: {
                HStack {
                    Text(task.title)
                        .goalJourneyText(.row)
                        .foregroundStyle(task.completed ? Color.holoToolTextSecondary : Color.holoToolText)
                        .strikethrough(task.completed)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.holoToolTextSecondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, HoloSpacing.md)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.holoToolBorder.opacity(0.6)).frame(height: 0.5).padding(.leading, 48)
        }
    }

    private func habitStepRow(_ habit: Habit, snapshot: GoalEvaluationSnapshot) -> some View {
        Button {
            source = .habit(HabitSourceRoute(habitID: habit.id, start: snapshot.windowStart, endExclusive: snapshot.windowEndExclusive))
        } label: {
            HStack(spacing: HoloSpacing.md) {
                habit.iconImage(size: 17)
                    .foregroundStyle(GoalJourneyStyle.action)
                    .frame(width: 32, height: 44)
                Text(habit.name)
                    .goalJourneyText(.row)
                    .foregroundStyle(Color.holoToolText)
                    .lineLimit(1)
                Spacer()
                Text("习惯")
                    .goalJourneyText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            .padding(.horizontal, HoloSpacing.md)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("goal-source-" + habit.name)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.holoToolBorder.opacity(0.6)).frame(height: 0.5).padding(.leading, 48)
        }
    }

    @ViewBuilder
    private func legacyReportsSection(_ state: GoalReviewState) -> some View {
        let reports = state.history.filter { ($0.status == .completed || $0.status == .stale) && $0.reportMessageID != nil }
        if !reports.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("历史回顾")
                    .goalJourneyText(.supporting)
                    .foregroundStyle(Color.holoToolTextSecondary)
                ForEach(reports) { saved in
                    Button("\(GoalAnalysisSection.dayText(saved.snapshotCutoffAt)) 的回顾 ↗") {
                        if let id = saved.reportMessageID { report = ChatMessageRepository.shared.loadMessageViewData(id: id) }
                    }
                    .goalJourneyText(.supporting)
                    .foregroundStyle(GoalJourneyStyle.action)
                    .frame(minHeight: 44)
                }
            }
        }
    }

    // MARK: - Helpers

    private var heroSourceBadgeText: String? {
        guard goal.isQuantitative else { return nil }
        switch goal.metricSourceEnum {
        case .habit:
            if let habit = model.sourceHabit {
                return String(localized: "同步习惯：\(habit.name)")
            }
            return nil
        case .ledger:
            if let name = model.sourceAccountName {
                return String(localized: "同步账户：\(name)")
            }
            return nil
        case .manual:
            return goal.goalDomain.displayName
        case .healthKit:
            if let kind = goal.healthMetricKindEnum {
                return String(localized: "苹果健康：\(kind.displayName)")
            }
            return String(localized: "苹果健康")
        }
    }

    private var isOverdue: Bool {
        guard goal.goalStatus == .active, let deadline = goal.deadline else { return false }
        return deadline < Calendar.current.startOfDay(for: Date())
    }

    private var deadlineBadgeText: String? {
        guard let deadline = goal.deadline else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: deadline)).day ?? 0
        if days > 0 { return String(localized: "\(GoalListCard.dayText(deadline)) 截止 · 剩 \(days) 天") }
        if days == 0 { return String(localized: "今天截止") }
        return String(localized: "\(GoalListCard.dayText(deadline)) 截止 · 逾期 \(-days) 天")
    }

    private var statusPill: some View {
        let isDone = goal.goalStatus == .completed
        return Text(goal.goalStatus.displayName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isDone ? Color.holoToolSuccess : Color.holoToolTextSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background((isDone ? Color.holoToolSuccess.opacity(0.12) : Color.holoToolBorder.opacity(0.5)), in: Capsule())
    }

    private func heroHeadline(snapshot: GoalEvaluationSnapshot?, metric: GoalMetricProgress?) -> String {
        if let snapshot {
            if let money = snapshot.result.moneyValue {
                let targetText = snapshot.result.targetValue.map { " / " + GoalJourneyNarrative.money(Decimal($0)) } ?? ""
                return GoalJourneyNarrative.money(money) + targetText
            }
            if let value = snapshot.result.value {
                let unit = snapshot.result.unit.map { " \($0)" } ?? ""
                let targetText = snapshot.result.targetValue.map { " / " + GoalMetricEvaluator.formatValue($0) } ?? ""
                return GoalMetricEvaluator.formatValue(value) + targetText + unit
            }
        }
        if let metric {
            let unit = goal.metricUnit.map { " \($0)" } ?? ""
            if goal.goalKindEnum == .target {
                return "\(GoalMetricEvaluator.formatValue(metric.currentValue))\(unit) · 目标 \(GoalMetricEvaluator.formatValue(goal.metricTargetValueDouble ?? 0))"
            }
            return "\(GoalMetricEvaluator.formatValue(metric.currentValue)) / \(GoalMetricEvaluator.formatValue(goal.metricTargetValueDouble ?? 0))\(unit)"
        }
        return goal.metricTargetValueDouble.map { "0 / \(GoalMetricEvaluator.formatValue($0))\(goal.metricUnit.map { " \($0)" } ?? "")" } ?? "待记录"
    }

    private func heroSubline(snapshot: GoalEvaluationSnapshot?, metric: GoalMetricProgress?) -> String? {
        if let metric {
            if metric.isAchieved { return String(localized: "已达成") }
            if goal.goalKindEnum == .target, let baseline = goal.baselineValueDouble {
                let target = goal.metricTargetValueDouble ?? 0
                let verb = target < baseline ? String(localized: "已减") : String(localized: "已增")
                let unit = goal.metricUnit.map { " \($0)" } ?? ""
                return "\(verb) \(GoalMetricEvaluator.formatValue(abs(baseline - metric.currentValue)))\(unit) / 共 \(GoalMetricEvaluator.formatValue(abs(target - baseline)))\(unit)"
            }
            if let forecast = metric.forecast {
                let dateText = GoalMetricEvaluator.displayDateFormatter.string(from: forecast.predictedDate)
                return String(localized: "按当前节奏预计 \(dateText) 达成")
            }
        }
        if let money = snapshot?.result.moneyValue, let target = snapshot?.result.targetValue {
            let rem = Decimal(target) - money
            return rem > 0 ? String(localized: "还差 \(GoalJourneyNarrative.money(rem))") : String(localized: "已达成")
        }
        return nil
    }

    private func openLedgerSource(snapshot: GoalEvaluationSnapshot?) {
        let scope = model.state?.plan.payload.resultSource?.ledgerScope ?? goal.ledgerScopePayload
        if let accountID = scope?.accountID {
            source = .account(accountID)
        } else if let sourceID = model.state?.plan.payload.resultSource?.sourceID {
            source = .account(sourceID)
        } else {
            source = .ledger
        }
    }

    private func openRequirement(_ item: GoalRequirementObservation) {
        open(entityType: item.entityType, id: item.entityID, start: item.windowStart, end: item.windowEndExclusive, notBefore: item.recordNotBefore, metric: item.requirement.metric)
    }

    private func openResult(_ state: GoalReviewState) {
        guard let result = state.plan.payload.resultSource else {
            if goal.metricSourceEnum == .manual { source = .manual(goal.id) }
            else if goal.metricSourceEnum == .ledger { openLedgerSource(snapshot: state.snapshot) }
            return
        }
        switch result.sourceType {
        case .manual: source = .manual(goal.id)
        case .habit:
            let isLatest = result.aggregation != .sum
            let start = isLatest ? min(state.snapshot.result.observedAt ?? state.snapshot.windowStart, state.snapshot.windowStart) : state.snapshot.windowStart
            open(entityType: .habit, id: result.sourceID, start: start, end: state.snapshot.windowEndExclusive, metric: isLatest ? .latest : .sum)
        case .ledger:
            if let id = result.ledgerScope?.accountID { source = .account(id) } else { source = .ledger }
        }
    }

    private func open(entityType: GoalPlanBindingEntityType, id: UUID?, start: Date, end: Date, notBefore: Date? = nil, metric: GoalRequirementMetric? = nil) {
        guard let id else {
            HoloToastCenter.shared.show("来源已删除或解绑", type: .info)
            return
        }
        switch entityType {
        case .habit: source = .habit(HabitSourceRoute(habitID: id, start: start, endExclusive: end, recordNotBefore: notBefore, metric: metric))
        case .task: source = .task(id)
        case .account: source = .account(id)
        case .budget: source = .budget(nil)
        case .fundSchedule: onOpenPlanEditor()
        }
    }

    private func roleName(_ role: GoalPlanBindingRole) -> String {
        switch role { case .result: return "目标成果"; case .action: return "行动"; case .constraint: return "上限"; case .context: return "参考" }
    }

    private func executionValue(_ item: GoalExecutionItem) -> String {
        if item.isUnavailable { return "来源不可用" }
        if let done = item.taskCompleted { return done ? "已完成" : "待办" }
        if item.habitAggregation == "sum", let sum = item.habitWindowSum { return "累计 \(GoalMetricEvaluator.formatValue(sum)) \(item.habitUnit ?? "")" }
        if let latest = item.habitLatestValue { return "最新 \(GoalMetricEvaluator.formatValue(latest)) \(item.habitUnit ?? "")" }
        return item.habitRecordedDays.map { $0 == 0 ? "尚无记录" : "\($0) 天有记录" } ?? "待记录"
    }
}
