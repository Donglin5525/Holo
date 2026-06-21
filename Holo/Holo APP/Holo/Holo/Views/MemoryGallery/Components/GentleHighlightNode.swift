import SwiftUI

struct GentleHighlightNode: View {
    let data: HighlightData

    var body: some View {
        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.holoPrimary)
                .frame(width: 32, height: 32)
                .background(Color.holoPrimary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                Text(subtitle)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoGlassBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.45), lineWidth: 1)
        )
    }

    private var title: String {
        switch data.category {
        case .spendingAnomaly:
            return "这天的外出支出比较集中"
        case .streakAchievement:
            return "有一个习惯节奏被稳稳接住"
        case .taskCompletion:
            return "有一件重要事情被推进了"
        case .habitPerfect:
            return "这天的习惯完成得比较完整"
        }
    }

    private var subtitle: String {
        switch data.category {
        case .spendingAnomaly:
            return "具体金额和对比留在详情里看。"
        case .streakAchievement, .habitPerfect:
            return data.subtitle ?? "这是一段值得回看的稳定记录。"
        case .taskCompletion:
            return data.subtitle ?? "这件事让本期行动线更清楚了一点。"
        }
    }

    private var iconName: String {
        switch data.category {
        case .spendingAnomaly:
            return "fork.knife"
        case .streakAchievement, .habitPerfect:
            return "sparkle"
        case .taskCompletion:
            return "checkmark.circle.fill"
        }
    }
}
