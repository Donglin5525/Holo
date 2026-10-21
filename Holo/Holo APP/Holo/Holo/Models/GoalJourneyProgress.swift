import Foundation

/// 每个指标保留自己的量纲；上限占用与达标进度不能混为一种完成率。
struct GoalJourneyProgress: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case achievement, allowance }
    let fraction: Double
    let kind: Kind
    let exceeded: Bool

    init?(value: Double?, target: Double?, kind: Kind = .achievement, evaluatedFraction: Double? = nil) {
        guard let value, value.isFinite, let target, target.isFinite,
              evaluatedFraction != nil || target > 0 else { return nil }
        let raw = evaluatedFraction ?? value / target
        guard raw.isFinite else { return nil }
        fraction = min(max(raw, 0), 1)
        self.kind = kind
        exceeded = kind == .allowance && value > target
    }

    var label: String {
        let percent = Int((fraction * 100).rounded())
        switch kind {
        case .achievement: return "\(percent)%"
        case .allowance: return exceeded ? "已超上限" : "上限已用 \(percent)%"
        }
    }
}
