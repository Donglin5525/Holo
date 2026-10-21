import SwiftUI
import Combine
import CoreData

@MainActor
final class GoalProgressFactsModel: ObservableObject {
    @Published var state: GoalReviewState?
    @Published var error: String?
    @Published var initialPlan: GoalPlanPayloadV2?
    func load(_ goal: Goal) {
        guard goal.managedObjectContext != nil, !goal.isDeleted, goal.deletedAt == nil else { state = nil; return }
        do {
            state = try GoalReviewCoordinator.shared.loadState(goal: goal)
            initialPlan = GoalPlanRevisionStore.allRevisionRows(goalID: goal.id, in: CoreDataStack.shared.viewContext).first?.planPayloadV2
            error = nil
        } catch { self.error = GoalPlanEditService.message(for: error) }
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

/// 长卷只组织来源事实与已保存的约定；不复制原模块的记录表单。
struct GoalProgressScrollSection: View {
    @ObservedObject var goal: Goal
    var onOpenReview: (() -> Void)? = nil
    @StateObject private var model = GoalProgressFactsModel()
    @State private var time: Double = 2
    @State private var folded = false
    @State private var showPlan = false
    @State private var source: GoalOriginalSourceSelection?
    @State private var report: ChatMessageViewData?
    @AppStorage("holo.today.focusGoalID") private var focusGoalID = ""
    private let changes = Publishers.Merge3(NotificationCenter.default.publisher(for: .habitDataDidChange),
        NotificationCenter.default.publisher(for: .financeDataDidChange), NotificationCenter.default.publisher(for: .todoDataDidChange))

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("进展长卷").goalJourneyText(.metadata).foregroundStyle(Color.holoToolTextSecondary).padding(.bottom, 7)
            Text(goal.title).goalJourneyText(.title).foregroundStyle(Color.holoToolText).padding(.bottom, 20)
            Text("拨动时间 · " + ["目标约定", "早期回顾", "当前进展"][Int(time)])
                .goalJourneyText(.metadata).foregroundStyle(Color.holoToolTextSecondary)
            Slider(value: $time, in: 0...2, step: 1).tint(GoalJourneyStyle.action).frame(minHeight: 44)
                .accessibilityLabel("拨动长卷时间")
                .accessibilityValue(["目标约定", "早期回顾", "当前进展"][Int(time)])
            HStack { Text("约定"); Spacer(); Text("回顾"); Spacer(); Text("现在") }
                .goalJourneyText(.detail).foregroundStyle(Color.holoToolTextSecondary)
            Button(folded ? "合上对照" : "对折看变化") { folded.toggle() }
                .goalJourneyText(.body).foregroundStyle(GoalJourneyStyle.action).frame(minHeight: 44).padding(.vertical, 10)
            if let error = model.error {
                Text(error).goalJourneyText(.supporting).foregroundStyle(Color.holoToolError)
                Button("重新读取") { model.load(goal) }.frame(minHeight: 44)
            }
            if let state = model.state {
                if folded { comparison(state).padding(.bottom, 14) }
                if Int(time) == 0 { initial(state) }
                else if Int(time) == 1 { history(state) }
                else { current(state) }
            } else if model.error == nil { ProgressView("正在读取进展").padding(.vertical, 20) }
        }
        .sheet(item: $source, onDismiss: { model.load(goal) }) { item in GoalOriginalSourceSheet(selection: item) }
        .sheet(isPresented: $showPlan, onDismiss: { model.load(goal) }) { GoalPlanEditorSheet(goal: goal) }
        .fullScreenCover(item: $report) { message in ReportDetailRoute(message: message, chatViewModel: nil, onDismiss: { model.load(goal) }) }
        .task { await CoreDataStack.shared.waitUntilReady(); model.load(goal) }
        .onReceive(changes.debounce(for: .milliseconds(100), scheduler: RunLoop.main)) { _ in model.load(goal) }
        .onReceive(NotificationCenter.default.publisher(for: .goalDataDidChange)) { _ in model.load(goal) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in model.load(goal) }
    }

    private func initial(_ state: GoalReviewState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GoalJourneyChapter {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.initialPlan?.intent.originalWish ?? goal.summary ?? goal.title).goalJourneyText(.story).lineSpacing(10)
                    Text(model.initialPlan?.intent.successCriteria ?? "最初没有单独保存成功条件，按现有记录继续核对。")
                        .goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
                }
            }.padding(.top, 18)
            Button("回到当前进展") { time = 2 }.buttonStyle(GoalJourneyPrimaryStyle())
        }
    }
    private func history(_ state: GoalReviewState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            let reports = state.history.filter { ($0.status == .completed || $0.status == .stale) && $0.reportMessageID != nil }
            GoalJourneyChapter {
                VStack(alignment: .leading, spacing: 12) {
                    Text(reports.isEmpty ? "还没有保存过回顾。" : "过去的回顾，保留当时的事实与约定。")
                        .goalJourneyText(.story).lineSpacing(10)
                    Text("更正来源会刷新当前事实，已保存的报告保留生成时内容。")
                        .goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
                }
            }.padding(.top, 18)
            ForEach(reports) { saved in
                Button("\(GoalAnalysisSection.dayText(saved.snapshotCutoffAt)) 的回顾 ↗") {
                    if let id = saved.reportMessageID { report = ChatMessageRepository.shared.loadMessageViewData(id: id) }
                }.goalJourneyText(.supporting).foregroundStyle(GoalJourneyStyle.action).frame(minHeight: 44)
            }
            Button("回到当前进展") { time = 2 }.buttonStyle(GoalJourneyPrimaryStyle())
        }
    }
    private func comparison(_ state: GoalReviewState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最初约定").goalJourneyText(.detail).foregroundStyle(Color.holoToolTextSecondary)
                    Text(model.initialPlan?.intent.successCriteria ?? "未单独保存").goalJourneyText(.supporting)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Color.holoToolBorder).frame(width: 1)
                VStack(alignment: .trailing, spacing: 6) {
                    Text("当前记录").goalJourneyText(.detail).foregroundStyle(Color.holoToolTextSecondary)
                    Text(GoalFactsPresentation.result(state.snapshot)).goalJourneyText(.supporting)
                }.frame(maxWidth: .infinity, alignment: .trailing)
            }.fixedSize(horizontal: false, vertical: true)
            Text("历史观测以保存的报告为准，不补画缺失的历史。")
                .goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
        }.padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(Color.holoToolBorder).frame(height: 0.5) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color.holoToolBorder).frame(height: 0.5) }
    }
    private func current(_ state: GoalReviewState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GoalJourneyChapter {
                VStack(alignment: .leading, spacing: 12) {
                    GoalJourneyNarrative(snapshot: state.snapshot, onResult: { openResult(state) },
                        onRequirement: openRequirement, onExecution: { item in
                            open(entityType: item.entityType, id: item.entityID, start: state.snapshot.windowStart, end: state.snapshot.windowEndExclusive)
                        })
                    Text(GoalFactsPresentation.result(state.snapshot))
                        .goalJourneyText(.supporting).lineSpacing(5).foregroundStyle(Color.holoToolTextSecondary)
                }
            }.padding(.top, 18)
            sectionTitle("想达成什么")
            if state.snapshot.result.sourceKind != nil {
                GoalJourneySourceRow(title: state.snapshot.result.moneyValue != nil ? (state.snapshot.result.sourceLabel.hasPrefix("全账本") ? "净结余变化" : "目标资金") : state.snapshot.result.sourceLabel,
                    value: GoalFactsPresentation.result(state.snapshot), note: "必要成果 · " + state.snapshot.result.sourceLabel, identifier: "goal-result-source",
                    progress: GoalFactsPresentation.progress(state.snapshot.result)) { openResult(state) }
            }
            ForEach((state.snapshot.requirements ?? []).filter { $0.role == .result }) { item in requirementRow(item) }
            if state.snapshot.result.sourceKind == nil && !(state.snapshot.requirements ?? []).contains(where: { $0.role == .result }) {
                Text(state.snapshot.successCriteria ?? "成果待确认，行动分别记录。")
                    .goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary).padding(.vertical, 12)
            }
            sectionTitle("为此做的安排", trailing: "调整约定") { showPlan = true }
            ForEach((state.snapshot.requirements ?? []).filter { $0.role != .result }) { item in requirementRow(item) }
            let configured = Set((state.snapshot.requirements ?? []).map(\.id)).union(state.snapshot.constraints.map(\.id))
            ForEach(state.snapshot.execution.filter { !configured.contains($0.id) }) { item in
                GoalJourneySourceRow(title: item.title, value: executionValue(item), note: roleName(item.role), identifier: "goal-source-" + item.title) {
                    open(entityType: item.entityType, id: item.entityID, start: state.snapshot.windowStart, end: state.snapshot.windowEndExclusive)
                }
            }
            ForEach(state.snapshot.constraints) { item in
                GoalJourneySourceRow(title: item.title, value: item.observedValue.map { "\($0) / \(item.limitValue) \(item.unit ?? "")" } ?? "待确认",
                    note: item.windowLabel + " · " + (item.isBreached == true ? "已超约定" : "完整情况待确认"), identifier: "goal-source-" + item.title,
                    progress: item.isUnavailable ? nil : GoalJourneyProgress(value: item.observedValue.map { NSDecimalNumber(decimal: $0).doubleValue }, target: NSDecimalNumber(decimal: item.limitValue).doubleValue, kind: .allowance),
                    evidence: item.expectedDays.map { "\(item.confirmedDays ?? 0) / \($0) 天已明确确认" } ?? "") {
                    if item.kind == .budget { source = .budget(state.plan.payload.budgetRule?.accountID) }
                    else if let rule = state.plan.payload.constraints.first(where: { $0.bindingID == item.id }) {
                        open(entityType: .habit, id: rule.habitID, start: item.windowStart ?? state.snapshot.windowStart, end: item.windowEndExclusive ?? state.snapshot.windowEndExclusive)
                    }
                }
            }
            Button { showPlan = true } label: { HStack(spacing: 8) { Text("调整本目标约定"); Image(systemName: "arrow.triangle.branch") } }
                .buttonStyle(GoalJourneyPrimaryStyle()).padding(.top, 16)
            Button("查看回顾与历史 ↗") { if let onOpenReview { onOpenReview() } else { time = 1 } }
                .goalJourneyText(.supporting).foregroundStyle(GoalJourneyStyle.action).frame(maxWidth: .infinity, minHeight: 44)
            Button(focusGoalID == goal.id.uuidString ? "今天正在关注这个目标" : "设为今天关注的目标") {
                focusGoalID = goal.id.uuidString
                NotificationCenter.default.post(name: .goalDataDidChange, object: goal.id)
                HapticManager.light()
            }.goalJourneyText(.supporting).foregroundStyle(GoalJourneyStyle.action).frame(maxWidth: .infinity, minHeight: 44)
        }
    }
    private func sectionTitle(_ title: String, trailing: String? = nil, action: @escaping () -> Void = {}) -> some View {
        HStack {
            Text(title).goalJourneyText(.body).foregroundStyle(Color.holoToolTextSecondary)
            Spacer()
            if let trailing { Button(trailing, action: action).goalJourneyText(.supporting).foregroundStyle(GoalJourneyStyle.action).frame(minHeight: 44) }
        }.padding(.top, 20).padding(.bottom, 6)
    }
    private func requirementRow(_ item: GoalRequirementObservation) -> some View {
        GoalJourneySourceRow(title: item.title, value: item.valueText,
            note: (item.requirement.calendarMonth ? "本月" : "最近\(item.requirement.windowDays)天") + " · " + (item.role == .constraint ? item.stateText : roleName(item.role)),
            identifier: "goal-source-" + item.title, progress: GoalFactsPresentation.progress(item),
            evidence: GoalFactsPresentation.evidence(item)) { openRequirement(item) }
    }
    private func openRequirement(_ item: GoalRequirementObservation) {
        open(entityType: item.entityType, id: item.entityID, start: item.windowStart, end: item.windowEndExclusive, notBefore: item.recordNotBefore, metric: item.requirement.metric)
    }
    private func openResult(_ state: GoalReviewState) {
        guard let result = state.plan.payload.resultSource else { return }
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
        guard let id else { return }
        switch entityType {
        case .habit: source = .habit(HabitSourceRoute(habitID: id, start: start, endExclusive: end, recordNotBefore: notBefore, metric: metric))
        case .task: source = .task(id)
        case .account: source = .account(id)
        case .budget: source = .budget(nil)
        case .fundSchedule: showPlan = true
        }
    }
    private func roleName(_ role: GoalPlanBindingRole) -> String {
        switch role { case .result: return "必要成果条件"; case .action: return "行动方法"; case .constraint: return "限制"; case .context: return "参考背景" }
    }
    private func executionValue(_ item: GoalExecutionItem) -> String {
        if item.isUnavailable { return "来源不可用" }
        if let done = item.taskCompleted { return done ? "已完成" : "待办" }
        if item.habitAggregation == "sum", let sum = item.habitWindowSum { return "累计 \(GoalMetricEvaluator.formatValue(sum)) \(item.habitUnit ?? "")" }
        if let latest = item.habitLatestValue { return "最新 \(GoalMetricEvaluator.formatValue(latest)) \(item.habitUnit ?? "")" }
        return item.habitRecordedDays.map { $0 == 0 ? "尚无记录" : "\($0) 天有记录" } ?? "待记录"
    }
}
