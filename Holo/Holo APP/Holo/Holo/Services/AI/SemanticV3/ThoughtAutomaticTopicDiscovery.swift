import Foundation
import CoreData
import CryptoKit
import OSLog

/// 自动形成主题：向量仅提出候选，模型必须逐条给出原文证据；用户无需逐个确认。
actor ThoughtAutomaticTopicDiscovery {
    static let shared = ThoughtAutomaticTopicDiscovery()
    private var running = false
    private var lastSignature = ""
    private var nextAttempt = Date.distantPast
    private(set) var statusMessage: String?
    private let logger = Logger(subsystem: "com.holo.Holo", category: "ThoughtAutoTopics")

    func retryNow() {
        nextAttempt = .distantPast
        lastSignature = ""
        statusMessage = nil
    }

    func process(store: ThoughtSemanticStore, index: any LocalSemanticIndex) async {
        guard !running, ThoughtSemanticFeatureFlags.discoveryEnabled, Date() >= nextAttempt,
              await MainActor.run(body: { HoloAIDataProcessingConsent.shared.isGranted }) else { return }
        running = true
        defer { running = false }
        let generation = ThoughtSemanticFeatureFlags.consentGeneration
        let context = CoreDataStack.shared.newBackgroundContext()
        do {
            let rows = try await store.loadAllActiveVectors(modelVersion: ThoughtSemanticStore.defaultModelVersion)
            let orphanIDs = await context.perform {
                let request = Thought.fetchRequest()
                request.predicate = NSPredicate(format: "deletedAt == nil AND isArchived == NO")
                return ((try? context.fetch(request)) ?? []).filter {
                    ThoughtTopicLinkProjection.effectiveTopics(for: $0).filter(\.isVisibleTopic).isEmpty
                }.map { $0.id.uuidString }.sorted()
            }
            // 主题形成或用户手动归属后，剩余未归类集合也会改变；不只等下一条新笔记才继续发现。
            let signature = rows.map { "\($0.id)|\($0.key)" }.sorted().joined(separator: "|") + ":orphans:" + orphanIDs.joined(separator: "|")
            guard signature != lastSignature else { return }
            try await ThoughtTopicClusterEngine.discover(context: context, store: store, index: index)
            let clusters = try await store.clusters(states: ["suggested", "ready"])
            statusMessage = clusters.isEmpty ? nil : "正在核对可形成的新主题。"
            // 每轮至多两次模型调用，后续节拍继续剩余；不阻塞新笔记处理。
            for cluster in clusters.prefix(2) {
                let snapshots: [(id: UUID, text: String, hash: String)] = await context.perform {
                    let request = Thought.fetchRequest()
                    request.predicate = NSPredicate(format: "id IN %@ AND deletedAt == nil AND isArchived == NO", cluster.memberIDs)
                    request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
                    return ((try? context.fetch(request)) ?? []).filter {
                        ThoughtTopicLinkProjection.effectiveTopics(for: $0).filter(\.isVisibleTopic).isEmpty
                    }.prefix(8).map { ($0.id, ThoughtIndexV2Policy.redactedText(forUpload: $0.content), ThoughtSemanticText.contentHash( $0.content)) }
                }
                guard snapshots.count >= 3 else { continue }
                let representatives = snapshots.map {
                    ThoughtTopicNameRequestDTO.Representative(ref: $0.id.uuidString,
                        text: ThoughtSemanticText.prefix($0.text, maxUTF16: 8_000))
                }
                let request = ThoughtTopicNameRequestDTO(schemaVersion: 2, operationId: UUID().uuidString,
                    engineVersion: ThoughtTopicVerifier.engineVersion, representatives: representatives)
                let provider = await MainActor.run { HoloBackendAIProvider() }
                let response = try await provider.topicName(request)
                guard response.schemaVersion == 2, response.operationId == request.operationId else {
                    throw ThoughtTopicVerifierError.responseContractViolation(reason: "topic_envelope")
                }
                if response.outcome == "no_topic" {
                    statusMessage = "已核对候选笔记，当前证据不足以形成新主题。"
                    try await store.upsertCluster(id: cluster.id, fingerprint: cluster.fingerprint, memberIDs: cluster.memberIDs,
                        state: "no_topic", cohesion: cluster.cohesion, name: nil, dismissedUntil: nil)
                    continue
                }
                guard response.outcome == "topic", !response.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      response.name.utf16.count <= 32, let definition = response.definition, !definition.isEmpty,
                      definition.utf16.count <= 240, let members = response.members, (3...8).contains(members.count) else {
                    throw ThoughtTopicVerifierError.responseContractViolation(reason: "topic_shape")
                }
                let byRef = Dictionary(representatives.map { ($0.ref, $0.text) }, uniquingKeysWith: { first, _ in first })
                var seen = Set<String>(), uniqueTexts = Set<String>()
                for member in members {
                    guard let text = byRef[member.ref], seen.insert(member.ref).inserted,
                          uniqueTexts.insert(text.trimmingCharacters(in: .whitespacesAndNewlines)).inserted,
                          ThoughtSemanticText.quoteMatches(member.quote, text: text, range: member.rangeUTF16) else {
                        throw ThoughtTopicVerifierError.responseContractViolation(reason: "topic_member_evidence")
                    }
                }
                let consent = await MainActor.run { HoloAIDataProcessingConsent.shared.isGranted }
                guard consent, ThoughtSemanticFeatureFlags.discoveryEnabled,
                      generation == ThoughtSemanticFeatureFlags.consentGeneration else { return }
                let created = try await context.perform { () -> Bool in
                    context.refreshAllObjects()
                    guard generation == ThoughtSemanticFeatureFlags.consentGeneration, ThoughtSemanticFeatureFlags.discoveryEnabled else { return false }
                    var valid: [(Thought, ThoughtTopicNameResponseDTO.Member)] = []
                    for member in members {
                        guard let snapshot = snapshots.first(where: { $0.id.uuidString == member.ref }) else { return false }
                        let thoughtRequest = Thought.fetchRequest()
                        thoughtRequest.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil AND isArchived == NO", snapshot.id as CVarArg)
                        guard let thought = try context.fetch(thoughtRequest).first,
                              ThoughtSemanticText.contentHash( thought.content) == snapshot.hash,
                              ThoughtTopicLinkProjection.effectiveTopics(for: thought).filter(\.isVisibleTopic).isEmpty else { return false }
                        valid.append((thought, member))
                    }
                    let topicRequest = Topic.fetchRequest()
                    let topics = try context.fetch(topicRequest)
                    let key = TopicRepository.normalizedKey(title: response.name)
                    let rejectionRequest = ThoughtTagConvergenceRejection.fetchRequest()
                    rejectionRequest.predicate = NSPredicate(format: "expiresAt > %@", Date() as CVarArg)
                    let rejections = try context.fetch(rejectionRequest)
                    guard !rejections.contains(where: { TopicRepository.normalizedKey(title: $0.topicTitle) == key }) else { return false }
                    // 用户隐藏/删除的同名主题不能被 AI 重新创建；已有主题交给关联执行器核对。
                    if topics.contains(where: { TopicRepository.normalizedKey(title: $0.title) == key }) { return false }
                    guard let topic = NSEntityDescription.insertNewObject(forEntityName: "Topic", into: context) as? Topic else { return false }
                    topic.id = UUID(); topic.title = response.name; topic.summary = definition
                    topic.statusEnum = .active; topic.titleSource = "ai"; topic.originClusterFingerprint = cluster.fingerprint
                    topic.confidence = 0; topic.thoughtCount = 0; topic.createdAt = Date(); topic.updatedAt = Date(); topic.topicRevision = 1
                    for (thought, member) in valid {
                        let hash = ThoughtSemanticText.contentHash( thought.content)
                        _ = ThoughtTopicLinkProjection.recordAIV3Decision(thought: thought, topic: topic, basisTextHash: hash,
                            decisionTier: "high", engineVersion: ThoughtTopicVerifier.engineVersion,
                            consentGeneration: generation, evidenceRange: member.rangeUTF16)
                    }
                    try context.save()
                    NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
                    return true
                }
                try await store.upsertCluster(id: cluster.id, fingerprint: cluster.fingerprint, memberIDs: cluster.memberIDs,
                    state: created ? "converted" : "awaiting_relation", cohesion: cluster.cohesion,
                    name: response.name, dismissedUntil: nil)
                statusMessage = created ? "已自动形成新主题：\(response.name)" : "正在核对与已有主题的关系。"
                await ThoughtSemanticChangeFeed.shared.reconcileAllThoughts()
            }
            if clusters.count <= 2 { lastSignature = signature }
            nextAttempt = Date().addingTimeInterval(60)
        } catch {
            statusMessage = ThoughtSemanticRetryPolicy.userMessage(for: ThoughtSemanticRetryPolicy.code(error))
            nextAttempt = Date().addingTimeInterval(ThoughtSemanticRetryPolicy.delay(error, attempt: 1))
            logger.error("主题发现稍后恢复：\(error.localizedDescription)")
        }
    }
}
