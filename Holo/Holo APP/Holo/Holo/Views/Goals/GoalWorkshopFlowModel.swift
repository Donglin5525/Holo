import Foundation
import Combine

/// 共创页面的操作状态：成功后才发布新内容，失败保留最后有效画面。
@MainActor
final class GoalWorkshopFlowModel: ObservableObject {
    @Published private(set) var session: GoalWorkshopSessionV1?
    @Published private(set) var resumeCandidates: [GoalWorkshopSessionV1] = []
    @Published private(set) var isBusy = false
    @Published private(set) var errorText: String?
    @Published private(set) var needsRestart = false
    @Published private(set) var needsReload = false
    @Published private(set) var sentReplyText: String?
    @Published var replyDraft = ""

    private let coordinator: GoalWorkshopCoordinator
    private let store: GoalWorkshopStore

    init(coordinator: GoalWorkshopCoordinator, store: GoalWorkshopStore) {
        self.coordinator = coordinator
        self.store = store
    }

    convenience init() {
        self.init(coordinator: GoalWorkshopCoordinator(service: GoalWorkshopServiceFactory.make()),
                  store: .shared)
    }

    func bootstrap(_ launch: GoalWorkshopLaunch) async {
        switch launch {
        case .new(let seedText):
            await perform {
                let candidates = try self.store.listResumable()
                if candidates.isEmpty {
                    self.session = try await self.coordinator.start(
                        seedText: seedText ?? "",
                        candidates: GoalWorkshopCandidateBuilder.build()
                    )
                } else {
                    self.resumeCandidates = candidates
                }
            }
        case .existingGoalAdvice(let goalID, _):
            await start(seed: "想调整这个目标", goalID: goalID)
        case .resume(let id):
            await resume(id)
        }
    }

    func startFresh() async {
        await start(seed: "")
    }

    private func start(seed: String, goalID: UUID? = nil) async {
        await perform {
            let refs: [GoalWorkshopContextRef] = goalID.map {
                [GoalWorkshopContextRef(sourceID: "goal-\($0.uuidString)", sourceRevision: 1,
                                        summary: GoalRepository.shared.findGoal(by: $0)?.title ?? "")]
            } ?? []
            self.session = try await self.coordinator.start(seedText: seed, goalID: goalID, contextRefs: refs,
                                                             candidates: GoalWorkshopCandidateBuilder.build())
            self.resumeCandidates = []
        }
    }

    func resume(_ id: UUID) async {
        await perform {
            let restored = try await self.coordinator.loadSession(id)
            self.session = restored
            self.resumeCandidates = []
        }
    }

    func discard(_ id: UUID) async {
        let succeeded = await perform {
            try await self.coordinator.cancel(sessionID: id)
            self.resumeCandidates.removeAll { $0.id == id }
        }
        if succeeded && resumeCandidates.isEmpty {
            await startFresh()
        }
    }

    func reply(_ text: String) async {
        guard let session, !isBusy else { return }
        sentReplyText = text
        defer { sentReplyText = nil }
        let succeeded = await perform {
            self.session = try await self.coordinator.reply(sessionID: session.id, text: text)
        }
        if succeeded && replyDraft.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            replyDraft = ""
        }
    }

    func continueUnderstanding() async {
        await reply("继续")
    }

    func skipQuestion() async {
        guard let session else { return }
        await perform {
            let updated = try await self.coordinator.skip(sessionID: session.id)
            self.session = updated
            if updated.questioningSkipped {
                self.session = try await self.coordinator.requestOptions(sessionID: updated.id)
            }
        }
    }

    func requestRoutes() async {
        guard let session else { return }
        await perform {
            self.session = try await self.coordinator.requestOptions(sessionID: session.id)
        }
    }

    func choose(_ optionID: String) async {
        guard let session else { return }
        await perform {
            self.session = try await self.coordinator.choose(sessionID: session.id, optionID: optionID)
        }
    }

    func generatePlan() async {
        guard let session else { return }
        await perform {
            self.session = try await self.coordinator.generatePlan(sessionID: session.id)
        }
    }

    func goBack() async {
        guard let session else { return }
        await perform {
            var previous = session
            try previous.goBack()
            try self.store.saveIfRevisionMatches(previous, expectedRevision: Int64(session.revision))
            self.session = previous
        }
    }

    func reloadCurrent() async {
        guard let id = session?.id else { return }
        await resume(id)
    }

    func restartFromScratch() async {
        guard let session else { await startFresh(); return }
        if session.phase.isTerminal { await startFresh(); return }
        let succeeded = await perform {
            if try self.store.load(id: session.id) != nil {
                try await self.coordinator.cancel(sessionID: session.id)
            }
        }
        if succeeded { await startFresh() }
    }

    @discardableResult
    func correct(factID: String, text: String) async -> Bool {
        guard let session else { return false }
        return await perform {
            self.session = try await self.coordinator.correctFact(sessionID: session.id, factID: factID, text: text)
        }
    }

    /// 目标和回执已由提交服务一起保存，只重读回执，不重复写入数据库。
    func finishAfterSave(goalID: UUID) async {
        guard let session else { return }
        errorText = nil
        needsRestart = false
        needsReload = false
        do {
            let saved = try await coordinator.loadSession(session.id)
            guard saved.phase == .saved, saved.appliedGoalID == goalID else {
                throw GoalWorkshopCoordinatorError.sessionUnavailable(session.id)
            }
            self.session = saved
        } catch {
            // 保存成功是确认页提供的真实结果；回读失败不能让用户再次提交。
            var saved = session
            saved.phase = .saved
            saved.appliedGoalID = goalID
            self.session = saved
            errorText = String(localized: "目标已保存，暂时无法读取规划进度。可关闭此页，在我的目标中查看。")
        }
    }

    @discardableResult
    private func perform(_ operation: () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorText = nil
        needsRestart = false
        needsReload = false
        defer { isBusy = false }
        do {
            try await operation()
            return true
        } catch {
            present(error)
            return false
        }
    }

    private func present(_ error: Error) {
        if let storeError = error as? GoalWorkshopStoreError {
            switch storeError {
            case .revisionConflict:
                errorText = String(localized: "规划进度已变化，请重新读取后继续。")
                needsReload = session != nil
            case .incompatiblePayload:
                errorText = String(localized: "这份规划由较新版本的 Holo 创建，请更新 App 后继续。")
            case .corruptedPayload:
                errorText = String(localized: "暂时无法读取这份规划，原记录已保留。请稍后重试。")
            }
            return
        }
        if let coordinatorError = error as? GoalWorkshopCoordinatorError {
            switch coordinatorError {
            case .quotaExhaustedMidFlow:
                errorText = String(localized: "服务暂时繁忙，请稍后继续。")
            case .sessionUnavailable:
                errorText = String(localized: "这份规划已无法继续，请重新开始。")
                needsRestart = true
            case .duplicateInFlight:
                errorText = String(localized: "上一条还在处理，请稍等。")
            case .invalidModelOutput:
                errorText = String(localized: "这次没有生成可用的结果，请重试。")
            case .requestBudgetExhausted:
                errorText = String(localized: "这次规划已达到处理上限，可以重新开始。")
                needsRestart = true
            }
            return
        }
        if let apiError = error as? APIError,
           case .serverError(let message) = apiError,
           message == HoloAIDataProcessingConsent.requiredMessage {
            errorText = String(localized: "请先在「设置 → HoloAI 数据授权」开启授权，再回来继续。")
        } else if error is URLError {
            errorText = String(localized: "暂时无法连接服务，请检查网络后重试。")
        } else {
            errorText = String(localized: "操作未完成，请稍后重试。")
        }
    }
}
