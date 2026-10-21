import SwiftUI

/// 本次已确认原型的局部视觉契约，不改变 App 其他页面的品牌样式。
enum GoalJourneyStyle {
    static let action = Color("GoalJourneyAction")
    static let inset = Color("GoalJourneyInset")
    static let pageInset: CGFloat = 22
}

enum GoalJourneyType {
    case title, story, heading, amount, row, rowValue, body, supporting, metadata, detail
    var size: CGFloat {
        switch self {
        case .title: 30
        case .story: 25
        case .heading: 22
        case .amount: 31
        case .row: 16
        case .rowValue: 17
        case .body: 15
        case .supporting: 14
        case .metadata: 13
        case .detail: 12
        }
    }
    var weight: Font.Weight {
        switch self {
        case .title, .heading, .amount, .rowValue: .medium
        default: .regular
        }
    }
}

private struct GoalJourneyTextModifier: ViewModifier {
    let type: GoalJourneyType
    @ScaledMetric private var size: CGFloat
    init(_ type: GoalJourneyType) { self.type = type; _size = ScaledMetric(wrappedValue: type.size) }
    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: type.weight))
            .tracking(type == .title ? -1 : type == .story ? -0.6 : 0)
    }
}

extension View {
    func goalJourneyText(_ type: GoalJourneyType) -> some View { modifier(GoalJourneyTextModifier(type)) }
}

struct GoalJourneyPrimaryStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.goalJourneyText(.body).fontWeight(.medium)
            .foregroundStyle(Color.holoToolOnAction)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 12)
            .background(GoalJourneyStyle.action.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: 14))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

struct GoalJourneySourceRow: View {
    let title: String
    let value: String
    var note: String = ""
    var identifier: String = ""
    var progress: GoalJourneyProgress? = nil
    var evidence: String = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            if let progress {
                GoalJourneyMetricLabel(title: title, value: value, note: note,
                    progress: progress, evidence: evidence, showsChevron: true)
                    .padding(.vertical, 18).contentShape(Rectangle())
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.holoToolBorder).frame(height: 0.5) }
            } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).goalJourneyText(.row).foregroundStyle(Color.holoToolText)
                    if !note.isEmpty { Text(note).goalJourneyText(.detail).foregroundStyle(Color.holoToolTextSecondary) }
                    if !evidence.isEmpty { Text(evidence).goalJourneyText(.detail).foregroundStyle(Color.holoToolTextSecondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(value).goalJourneyText(.rowValue).monospacedDigit()
                    .foregroundStyle(Color.holoToolText).multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Color.holoToolTextSecondary)
            }
            .padding(.vertical, 13).frame(minHeight: 68)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(Color.holoToolBorder).frame(height: 0.5) }
            }
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
            .accessibilityValue(value + (progress.map { "，" + $0.label } ?? ""))
    }
}

/// 今天摘要与长卷共用的数值、进度和覆盖说明；整行跳转仍由外层原入口负责。
struct GoalJourneyMetricLabel: View {
    let title: String
    let value: String
    var note: String = ""
    var progress: GoalJourneyProgress?
    var evidence: String = ""
    var compact = false
    var showsChevron = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 9) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Text(title).goalJourneyText(compact ? .supporting : .row)
                    Spacer(minLength: 8)
                    valueLabel.fixedSize(horizontal: true, vertical: false)
                    if showsChevron { chevron }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).goalJourneyText(compact ? .supporting : .row)
                    HStack { valueLabel; Spacer(minLength: 0); if showsChevron { chevron } }
                }
            }.foregroundStyle(Color.holoToolText)
            if let progress {
                HoloProgress(value: progress.fraction,
                    color: progress.exceeded ? .holoToolError : GoalJourneyStyle.action,
                    lineWidth: compact ? 4 : 6, trackColor: Color.holoToolBorder.opacity(0.6))
                    .accessibilityLabel(title + (progress.kind == .allowance ? "上限占用" : "达标进度"))
                    .accessibilityValue(value + "，" + progress.label)
                    .accessibilityIdentifier("goal-metric-progress-" + title)
            }
            if !compact {
                HStack(alignment: .top, spacing: 12) {
                    Text(note).frame(maxWidth: .infinity, alignment: .leading)
                    if let progress { Text(progress.label).monospacedDigit() }
                }.goalJourneyText(.detail).foregroundStyle(Color.holoToolTextSecondary)
            } else if progress?.kind == .allowance {
                Text(progress?.label ?? "").goalJourneyText(.detail).foregroundStyle(Color.holoToolTextSecondary)
            }
            if !evidence.isEmpty { Text(evidence).goalJourneyText(.detail).foregroundStyle(Color.holoToolTextSecondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var valueLabel: some View {
        Text(value).goalJourneyText(compact ? .supporting : .rowValue).monospacedDigit()
    }
    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Color.holoToolTextSecondary)
    }
}

/// 长卷的编辑动线也沿用同一排版，字段仍写回既有原模块与计划服务。
struct GoalJourneyFormSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).goalJourneyText(.body).foregroundStyle(Color.holoToolTextSecondary)
            content
        }.padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GoalJourneyField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).goalJourneyText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
            content.goalJourneyText(.row).foregroundStyle(Color.holoToolText)
                .padding(12).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.holoToolBorder, lineWidth: 0.5) }
        }
    }
}
