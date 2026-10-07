//
//  MatterV2PrototypeView.swift
//  Holo
//
//  Matter 战略收敛 R0 静态样机（2026-09-21 方案 §8 R0）。
//
//  - 固定「国庆日本旅行」数据（UC-MATTER-001 标准输出），不接真实仓库、不落库。
//  - 新规划卡 / 新详情页 / Today 去重示意 + 旧线上卡片同屏对照。
//  - 仅 Debug 设置页可达；文案用 verbatim 硬编码，不进翻译词表。
//

#if DEBUG
import SwiftUI

// MARK: - 固定数据（UC-MATTER-001 §5 标准输出）

enum MatterV2PrototypeData {
    static let planTitle = "国庆日本旅行"
    static let answerText = "在出发前完成入境核实、行程分配、机票住宿、摩卡照顾和出行准备。"
    static let departureHint = "10 月 1 日出发"

    static let planSteps: [(id: String, title: String)] = [
        ("t1", "核实护照、签证与入境要求"),
        ("t2", "确定东京和大阪的停留天数"),
        ("t3", "预订往返机票"),
        ("t4", "安排东京与大阪之间的交通"),
        ("t5", "预订东京和大阪住宿"),
        ("t6", "确定摩卡的照顾安排"),
        ("t7", "准备支付、网络和出行资料")
    ]

    static let draft: HoloContextPlanDraft = {
        HoloContextPlanDraft(
            runID: "prototype-run-001",
            draftRevision: 1,
            goalSummary: planTitle,
            answerText: answerText,
            items: planSteps.map { step in
                HoloContextPlanItem(
                    itemID: step.id,
                    title: step.title,
                    kind: .task
                )
            },
            unknowns: [],
            dependencyEdges: []
        )
    }()

    /// 旧卡实例化需要的 draftJSON（与线上解码口径一致：iso8601）。
    static var draftJSON: String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(draft) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - 新版规划卡（R2 正式组件的视觉骨架：一个主 CTA）

/// 卡片状态机对应 UseCase 派生状态：draftReady → launching → active(launched)。
private enum MatterV2PlanCardPhase: Equatable {
    case draftReady
    case launching
    case launched
}

struct MatterV2PlanCardPreview: View {
    @State private var phase: MatterV2PlanCardPhase = .draftReady
    @State private var showAdjustHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch phase {
            case .draftReady, .launching:
                header
                Text(verbatim: MatterV2PrototypeData.answerText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(verbatim: "计划")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(MatterV2PrototypeData.planSteps, id: \.id) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .strokeBorder(.quaternary, lineWidth: 1.5)
                                .frame(width: 18, height: 18)
                            Text(verbatim: step.title)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if phase == .draftReady {
                    Button {
                        startLaunch()
                    } label: {
                        Text(verbatim: "开始推进")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if showAdjustHint {
                        Text(verbatim: "在对话里继续说，Holo 会生成新的计划卡。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            showAdjustHint = true
                        } label: {
                            Text(verbatim: "调整计划")
                                .font(.footnote)
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Button {
                        // 样机无真实导航
                    } label: {
                        Text(verbatim: "正在建立计划…")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(true)
                }

            case .launched:
                Label {
                    Text(verbatim: "已开始推进「\(MatterV2PrototypeData.planTitle)」")
                        .font(.headline)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text(verbatim: "已建立 \(MatterV2PrototypeData.planSteps.count) 个步骤")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()

                Text(verbatim: "下一步")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(verbatim: MatterV2PrototypeData.planSteps[0].title)
                    .font(.body.weight(.medium))

                Button {
                    // 样机无真实导航
                } label: {
                    Text(verbatim: "打开计划")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var header: some View {
        Text(verbatim: MatterV2PrototypeData.planTitle)
            .font(.title3.weight(.semibold))
    }

    /// 模拟本地原子事务耗时（真实链路 p95 < 1s，纯本地无网络）。
    private func startLaunch() {
        phase = .launching
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            phase = .launched
        }
    }
}

// MARK: - 新版详情页示意（状态 → 下一步 → 计划 → 待确认 → 继续对话）

private struct MatterV2DetailPreview: View {
    /// 演示开关：有待确认问题时才渲染该区块（无 Open Loop 不显示空区块）。
    let showPendingQuestion: Bool
    @State private var completed: Set<String> = []
    @State private var matterCompleted = false
    @State private var showCompletionConfirm = false

    private let steps = MatterV2PrototypeData.planSteps
    private var doneCount: Int { completed.count }
    private var nextStep: (id: String, title: String)? {
        steps.first { !completed.contains($0.id) }
    }
    private var allDone: Bool { completed.count == steps.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            if matterCompleted {
                completedSection
            } else {
                statusSection
                nextActionSection
                planSection
                if showPendingQuestion {
                    pendingQuestionSection
                }
                chatEntry
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: MatterV2PrototypeData.planTitle)
                .font(.title2.weight(.semibold))
            Spacer()
            Text(verbatim: MatterV2PrototypeData.departureHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "当前状态")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(verbatim: "\(doneCount)/\(steps.count) 已完成")
                .font(.subheadline.weight(.medium))
        }
    }

    private var nextActionSection: some View {
        Group {
            if let next = nextStep {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "下一步")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    HStack {
                        Text(verbatim: next.title)
                            .font(.body.weight(.medium))
                        Spacer()
                        Button {
                            // 样机无真实导航
                        } label: {
                            Text(verbatim: "打开任务")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(12)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "准备已完成")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.green)
                    Button {
                        showCompletionConfirm = true
                    } label: {
                        Text(verbatim: "完成这件事")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .alert(
            Text(verbatim: "完成「\(MatterV2PrototypeData.planTitle)」？"),
            isPresented: $showCompletionConfirm
        ) {
            Button {
                matterCompleted = true
            } label: {
                Text(verbatim: "确认完成")
            }
            Button(role: .cancel) {} label: {
                Text(verbatim: "取消")
            }
        } message: {
            Text(verbatim: "计划和完成记录会保留，之后仍可回看。")
        }
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "计划 \(doneCount)/\(steps.count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            ForEach(steps, id: \.id) { step in
                Button {
                    toggle(step.id)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: completed.contains(step.id) ? "checkmark.circle.fill" : "circle")
                            .font(.body)
                            .foregroundStyle(completed.contains(step.id) ? .green : .secondary)
                            .padding(.top, 1)
                        Text(verbatim: step.title)
                            .font(.subheadline)
                            .strikethrough(completed.contains(step.id))
                            .foregroundStyle(completed.contains(step.id) ? .secondary : .primary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var pendingQuestionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "待确认 1")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Text(verbatim: "摩卡由谁照顾")
                    .font(.subheadline)
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var chatEntry: some View {
        Button {
            // 样机无真实导航
        } label: {
            Label {
                Text(verbatim: "继续聊这件事")
            } icon: {
                Image(systemName: "bubble.left.and.bubble.right")
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var completedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(verbatim: "已完成")
                    .font(.headline)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
            Text(verbatim: "\(steps.count)/\(steps.count) 已完成 · 计划和对话保留，可随时回看。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                matterCompleted = false
            } label: {
                Text(verbatim: "重新打开")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
        }
    }

    private func toggle(_ id: String) {
        if completed.contains(id) {
            completed.remove(id)
        } else {
            completed.insert(id)
        }
    }
}

// MARK: - Today 去重示意（S7：T1 已完成，T2 是 Focus，全文只出现一次）

private struct MatterV2TodayPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            focusSection
            agendaSection
            mattersSection
            placeholderSection("保持状态（占位：习惯/健康打卡）")
            placeholderSection("概况（占位：收支/步数）")
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "现在最值得做")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.footnote)
                    .foregroundStyle(.tint)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "确定东京和大阪的停留天数")
                        .font(.body.weight(.semibold))
                    Text(verbatim: "来自：\(MatterV2PrototypeData.planTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private var agendaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "今天的安排")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack {
                Text(verbatim: "给植物浇水")
                    .font(.subheadline)
                Spacer()
                Text(verbatim: "20:00")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(verbatim: "回复工作室邮件")
                    .font(.subheadline)
                Spacer()
                Text(verbatim: "今天")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var mattersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "正在推进")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack {
                Text(verbatim: MatterV2PrototypeData.planTitle)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(verbatim: "1/\(MatterV2PrototypeData.planSteps.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
            }
            Text(verbatim: MatterV2PrototypeData.departureHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func placeholderSection(_ label: String) -> some View {
        HStack {
            Text(verbatim: label)
                .font(.caption)
                .foregroundStyle(.quaternary)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 汇总对照页

struct MatterV2PrototypeView: View {
    @State private var showPendingQuestion = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(verbatim: "固定「国庆日本旅行」数据的静态样机，不写任何真实数据；打开类按钮无跳转。详情页可点圆圈体验完成 → 下一步变化 → 收尾完成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                section("① 新版规划卡（一个主操作）") {
                    MatterV2PlanCardPreview()
                }

                section("② 新版详情页") {
                    MatterV2DetailPreview(showPendingQuestion: showPendingQuestion)
                }
                Toggle(isOn: $showPendingQuestion) {
                    Text(verbatim: "详情演示：显示一条待确认")
                        .font(.caption)
                }
                .tint(.holoPrimary)

                section("③ Today 去重示意（同一行动只出现一次）") {
                    MatterV2TodayPreview()
                }

                section("④ 当前线上卡片（对照）") {
                    if let json = MatterV2PrototypeData.draftJSON {
                        ContextPlanChatCard(
                            draftJSON: json,
                            messageID: UUID(),
                            receipts: PrototypeContextPlanReceiptStore(),
                            onCreateTasks: { _ in [:] }
                        )
                    } else {
                        Text(verbatim: "样机数据构造失败")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(Text(verbatim: "Matter V2 样机"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - 旧卡实例化的内存回执存储（样机专用）

private final class PrototypeContextPlanReceiptStore: ContextPlanReceiptStoring {
    func loadReceipts() -> [String: String] { [:] }
    func saveReceipts(_ receipts: [String: String]) {}
    func loadReceiptsV2() -> [String: HoloContextPlanTaskReceiptV2] { [:] }
    func saveReceiptsV2(_ receipts: [String: HoloContextPlanTaskReceiptV2]) {}
    func loadResolution(runID: String) -> String? { nil }
    func saveResolution(runID: String, resolution: String) {}
}
#endif
