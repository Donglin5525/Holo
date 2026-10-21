import SwiftUI

/// 用确定性事实组成原型的叙事段落；每个带下划线的数字仍回到同一来源。
struct GoalJourneyNarrative: View {
    let snapshot: GoalEvaluationSnapshot
    let onResult: () -> Void
    let onRequirement: (GoalRequirementObservation) -> Void
    let onExecution: (GoalExecutionItem) -> Void
    var body: some View {
        Text(paragraph).goalJourneyText(.story).lineSpacing(10)
            .foregroundStyle(Color.holoToolText).tint(GoalJourneyStyle.action)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "holo-progress" else { return .systemAction }
                if url.host == "result" { onResult() }
                else if let id = UUID(uuidString: url.lastPathComponent) {
                    if url.host == "requirement", let item = snapshot.requirements?.first(where: { $0.id == id }) { onRequirement(item) }
                    if url.host == "execution", let item = snapshot.execution.first(where: { $0.id == id }) { onExecution(item) }
                }
                return .handled
            })
    }
    private var paragraph: AttributedString {
        var text = AttributedString()
        func append(_ value: String) { text.append(AttributedString(value)) }
        func fact(_ value: String, target: String) {
            var part = AttributedString(value)
            part.link = URL(string: "holo-progress://" + target)
            part.foregroundColor = GoalJourneyStyle.action
            part.underlineStyle = .single
            text.append(part)
        }
        let result = snapshot.result
        if result.status == .observed || result.status == .stale {
            if let money = result.moneyValue {
                let accountName = result.sourceLabel.replacingOccurrences(of: "账户「", with: "").replacingOccurrences(of: "」余额", with: "")
                append(result.sourceLabel.hasPrefix("账户「") ? accountName + "已有 " : result.sourceLabel + "为 ")
                fact(Self.money(money), target: "result")
                append("。")
                if let target = result.targetValue {
                    let remaining = Decimal(target) - money
                    append(remaining > 0 ? "\n距离约定还差 " + Self.money(remaining) + "。" : "\n已覆盖这项资金约定。")
                }
            } else if let value = result.value {
                append(result.sourceLabel + "，最近记录为 ")
                fact(GoalMetricEvaluator.formatValue(value) + " " + (result.unit ?? ""), target: "result")
                append("。")
            }
        } else {
            let conditions = (snapshot.requirements ?? []).filter { $0.role == .result }
            if !conditions.isEmpty {
                for (index, item) in conditions.prefix(3).enumerated() {
                    if index > 0 { append("，\n") }
                    append(item.title + " ")
                    fact(item.valueText, target: "requirement/" + item.id.uuidString)
                }
                append("。")
            } else { append(result.status == .unavailable ? "结果来源暂不可用，\n先核对原始记录。" : "真实结果还待验证，\n日常行动分别记录。") }
        }
        let actions = (snapshot.requirements ?? []).filter { $0.role == .action }
        if let action = actions.first {
            append("\n" + action.title + " ")
            let value = action.value.map { GoalMetricEvaluator.formatValue($0) + " " + action.unit } ?? "待记录"
            fact(value, target: "requirement/" + action.id.uuidString)
            append("。")
        } else if let action = snapshot.execution.first(where: { $0.role == .action && $0.entityType == .habit }) {
            append("\n" + action.title + " ")
            let observed = action.habitAggregation == "latest" ? action.habitLatestValue : action.habitWindowSum
            let value = observed.map { GoalMetricEvaluator.formatValue($0) + " " + (action.habitUnit ?? "") } ?? "待记录"
            fact(value, target: "execution/" + action.id.uuidString)
            append("。")
        }
        return text
    }
    static func money(_ value: Decimal) -> String {
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 2
        return "¥" + (formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—")
    }
}

struct GoalJourneyChapter<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content().frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 24)
            .padding(.bottom, 20)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.holoToolBorder).frame(width: 1).padding(.leading, 4).padding(.top, 11)
            }
            .overlay(alignment: .topLeading) { Circle().fill(GoalJourneyStyle.action).frame(width: 9, height: 9).offset(y: 5) }
    }
}
