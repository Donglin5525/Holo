//
//  TaskSplitSheet.swift
//  Holo
//
//  「拆成几步」入口行 + 确认页（2026-10-11 拆开瘦身定稿）
//
//  - 行式入口与「加入今天」同语言：嵌卡内次级入口不做整宽按钮
//  - 确认页一屏：AI 拆解（唯一一次调用）→ 可改可删可加 → 「行，按这个来」落库
//  - 天生等待步带点亮时钟，两态开关：AI 标的可点掉，没标的可补标
//

import SwiftUI

// MARK: - 行式入口

struct TaskSplitEntryRow: View {

    /// 已有子任务数（0=首次拆解文案；>0=补拆文案）
    var existingStepCount: Int
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.caption)
                .foregroundStyle(Color.holoToolAI)
            Text(existingStepCount == 0
                 ? String(localized: "不知道从哪儿下手？拆成小步慢慢来")
                 : String(localized: "再拆一拆，看看还缺哪几步"))
                .font(.caption)
                .foregroundStyle(Color.holoTextSecondary)
            Spacer(minLength: 4)
            Button(action: action) {
                Text("拆成几步")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.holoToolAI)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.holoToolAI.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("taskSplitEntryButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(Color.holoToolBackground.opacity(0.5))
        )
    }
}

// MARK: - 确认页

struct TaskSplitSheet: View {

    let task: TodoTask
    /// 确认落库（宿主负责写库与刷新；sheet 自行关闭）
    let onConfirm: ([TaskSplitStepDraft]) -> Void

    enum Phase: Equatable {
        case loading
        case clarification(question: String, answers: [String])
        case drafts
        case cannotHelp(String)
        case failed
        /// taskSplit 月池用尽（档位限制非出错）：免费版给升级入口，Plus 只报重置
        case quotaExhausted(message: String, upgradeAvailable: Bool)
    }

    @State private var phase: Phase = .loading
    @State private var drafts: [TaskSplitStepDraft] = []
    @State private var userAnswer: String?
    @State private var clarificationAnswer: String = ""
    /// 本轮拆解的额度动作 ID：澄清追问回答后的再生成复用同一个，
    /// 后端 taskSplit 月池按它幂等计量——「5 次/月」按拆一次任务计，不按 AI 调用次数计
    @State private var flowUsageActionID = UUID().uuidString
    @Environment(\.dismiss) private var dismiss

    private var existingStepCount: Int {
        (task.checkItems?.allObjects as? [CheckItem] ?? []).count
    }

    private var validDraftCount: Int {
        drafts.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    var body: some View {
        Group {
            switch phase {
            case .loading: loadingContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .clarification(let question, let answers): clarificationContent(question, answers)
            case .drafts: draftsContent
            case .cannotHelp(let reason): cannotHelpContent(reason).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .quotaExhausted(let message, let upgradeAvailable): quotaExhaustedContent(message, upgradeAvailable).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed: failedContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.holoCardBackground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            await run()
        }
        .onDisappear {
            TaskSplitService.shared.cancel(taskID: task.id)
        }
    }

    // MARK: 加载

    private var loadingContent: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("琢磨怎么拆…")
                .font(.holoBody.weight(.medium))
            Text(existingStepCount > 0
                 ? String(localized: "结合已有 \(existingStepCount) 步，看看还缺什么")
                 : String(localized: "看看这个任务该怎么一步步走"))
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .padding(.vertical, 60)
        .padding(.horizontal, 20)
    }

    // MARK: 先问一句（AI 反问）

    private func clarificationContent(_ question: String, _ answers: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("先问一句")
                .font(.holoHeading)
                .frame(maxWidth: .infinity)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.holoAI))
                Text(question)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(Color.holoAI.opacity(0.1)))

            VStack(spacing: 8) {
                ForEach(answers, id: \.self) { answer in
                    Button {
                        userAnswer = answer
                        restart()
                    } label: {
                        Text(verbatim: answer)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: HoloRadius.md)
                                    .fill(Color.holoNestedCardBackground)
                            )
                    }
                    .buttonStyle(.plain)
                }

                TextField("或者自己回答", text: $clarificationAnswer)
                    .font(.holoBody)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.md)
                            .fill(Color.holoNestedCardBackground)
                    )
                    .submitLabel(.done)

                Button {
                    userAnswer = clarificationAnswer
                    restart()
                } label: {
                    Text("按这个继续")
                        .font(.holoBody.weight(.medium))
                        .foregroundColor(.holoPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .disabled(clarificationAnswer.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    // MARK: 确认页（可编辑草稿）：标题区顶铺 + 中部可滚 + 按钮沉底

    private var draftsContent: some View {
        VStack(spacing: 0) {
            // 标题区（居左，与说明/步骤同一轴线；右上关闭）
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("拆成这 \(validDraftCount) 步")
                        .font(.holoHeading)
                    Text("不对就改，缺了就加")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                Spacer(minLength: 12)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.holoToolBackground.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("关闭"))
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Label {
                        Text("带时钟的是天生要等的步骤（AI 标的），点一下可去掉或补标")
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary.opacity(0.8))
                    } icon: {
                        Image(systemName: "clock")
                            .font(.holoTinyLabel)
                            .foregroundColor(.orange)
                    }
                    .padding(.bottom, 4)

                    ForEach($drafts) { $draft in
                        draftRow($draft)
                        if draft.id != drafts.last?.id {
                            Divider().padding(.horizontal, 2)
                        }
                    }

                    Button {
                        drafts.append(TaskSplitStepDraft(title: ""))
                    } label: {
                        Label("加一步", systemImage: "plus")
                            .font(.holoBody)
                            .foregroundColor(.holoPrimary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .padding(.horizontal, 20)
            }

            // 主按钮沉底：系统安全区之上
            Button {
                confirm()
            } label: {
                Text(validDraftCount > 0
                     ? String(localized: "行，按这个来（\(validDraftCount) 步）")
                     : String(localized: "至少留一步"))
                    .font(.holoBody.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.md)
                            .fill(validDraftCount > 0 ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .disabled(validDraftCount == 0)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .accessibilityIdentifier("taskSplitConfirmButton")
        }
    }

    /// 步骤行：长文字多行换行（无省略号），折行悬挂对齐首行文字；
    /// 序号/时钟/×钉在第一行（top 对齐 + 光学补偿），右侧图标列全程一条直线
    private func draftRow(_ draft: Binding<TaskSplitStepDraft>) -> some View {
        let index = drafts.firstIndex(where: { $0.id == draft.wrappedValue.id }).map { $0 + 1 } ?? 0
        return HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(index)")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .frame(width: 16, alignment: .center)
                .padding(.top, 12)

            TextField("这一步做什么", text: draft.title, axis: .vertical)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .lineSpacing(2)
                .padding(.vertical, 11)

            Button {
                draft.wrappedValue.isWaiting.toggle()
            } label: {
                Image(systemName: draft.wrappedValue.isWaiting ? "clock.fill" : "clock")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(draft.wrappedValue.isWaiting ? .orange : .holoTextSecondary.opacity(0.6))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 7)
            .accessibilityLabel(draft.wrappedValue.isWaiting
                                ? Text("这步已标为等待，点一下去掉")
                                : Text("把这一步标为等待"))

            Button {
                drafts.removeAll { $0.id == draft.wrappedValue.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextSecondary.opacity(0.55))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 7)
            .accessibilityLabel(Text("删除这步"))
        }
    }

    private func confirm() {
        let valid = drafts.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !valid.isEmpty else { return }
        onConfirm(valid)
        dismiss()
    }

    // MARK: 帮不上 / 失败

    private func cannotHelpContent(_ reason: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Color.holoToolAI)
            Text(reason)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
            Button("知道了") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(30)
    }

    private var failedContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title2)
                .foregroundColor(.holoTextSecondary)
            Text("没拆出来，网络或服务开小差了")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            HStack(spacing: 12) {
                Button {
                    phase = .loading
                    Task { await run() }
                } label: {
                    Text("再试一次")
                        .font(.holoBody)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.holoPrimary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                Button("先自己加") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(30)
    }

    // MARK: 额度用尽（档位限制，非出错）

    private func quotaExhaustedContent(_ message: String, _ upgradeAvailable: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Color.holoToolAI)
            Text(message)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
            if upgradeAvailable {
                Button {
                    HoloPlusActionCoordinator.shared.requirePlus(context: .taskSplit)
                } label: {
                    Text("了解 Holo Plus")
                        .font(.holoBody.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.holoPrimary))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("taskSplitQuotaUpgradeButton")
            } else {
                Button("知道了") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(30)
    }

    // MARK: 运行

    private func restart() {
        guard let answer = userAnswer, !answer.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        phase = .loading
        Task { await run() }
    }

    private func run() async {
        guard case .loading = phase else { return }
        // 本地额度预检：快照未就绪（nil）放行，后端 429 兜底；月池用尽直接落额度卡，不浪费一次请求
        if let snapshot = HoloEntitlementState.shared.quotas["taskSplit"], snapshot.remaining <= 0 {
            phase = .quotaExhausted(
                message: HoloQuotaError.taskSplitExhaustedMessage(isPlusActive: HoloEntitlementState.shared.isPlusActive),
                upgradeAvailable: !HoloEntitlementState.shared.isPlusActive
            )
            return
        }
        let outcome = await TaskSplitService.shared.split(task: task, userAnswer: userAnswer, usageActionId: flowUsageActionID)
        switch outcome {
        case .steps(let newDrafts):
            drafts = newDrafts
            phase = .drafts
        case .clarification(let question, let answers):
            phase = .clarification(question: question, answers: answers)
        case .cannotHelp(let reason):
            phase = .cannotHelp(reason)
        case .quotaExhausted(let message, let upgradeAvailable):
            phase = .quotaExhausted(message: message, upgradeAvailable: upgradeAvailable)
        case nil:
            phase = .failed
        }
    }
}
