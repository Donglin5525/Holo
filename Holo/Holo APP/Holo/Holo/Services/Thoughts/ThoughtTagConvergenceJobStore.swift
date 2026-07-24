//
//  ThoughtTagConvergenceJobStore.swift
//  Holo
//
//  观点主题归纳的轻量持久化 job 记录。
//  用于 App 被系统杀死后，冷启动恢复一次未完成的自动归纳。
//

import Foundation

struct ThoughtTagConvergenceJobRecord: Codable, Equatable {
    enum Status: String, Codable {
        case pending
        case running
    }

    let id: UUID
    var status: Status
    var autoApply: Bool
    var createdAt: Date
    var updatedAt: Date
}

/// 待用户确认的主题建议必须跨冷启动保留，否则“已发现”角标会在进程结束后丢失。
struct ThoughtTagConvergenceSuggestionRecord: Codable, Equatable {
    let inputSignature: String
    let suggestions: [ConvergenceSuggestion]
}

final class ThoughtTagConvergenceJobStore {
    static let shared = ThoughtTagConvergenceJobStore()

    private let userDefaults: UserDefaults
    private let storageKey = "holo.thoughtTagConvergence.pendingJob"
    private let lastCompletedInputSignatureKey = "holo.thoughtTagConvergence.lastCompletedInputSignature"
    private let pendingSuggestionsKey = "holo.thoughtTagConvergence.pendingSuggestions"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func upsert(autoApply: Bool, status: ThoughtTagConvergenceJobRecord.Status = .pending, now: Date = Date()) {
        var record = load() ?? ThoughtTagConvergenceJobRecord(
            id: UUID(),
            status: status,
            autoApply: autoApply,
            createdAt: now,
            updatedAt: now
        )
        record.status = status
        record.autoApply = autoApply
        record.updatedAt = now
        save(record)
    }

    func markRunning(now: Date = Date()) {
        guard var record = load() else { return }
        record.status = .running
        record.updatedAt = now
        save(record)
    }

    func load() -> ThoughtTagConvergenceJobRecord? {
        guard let data = userDefaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(ThoughtTagConvergenceJobRecord.self, from: data)
    }

    func clear() {
        userDefaults.removeObject(forKey: storageKey)
    }

    func lastCompletedInputSignature() -> String? {
        userDefaults.string(forKey: lastCompletedInputSignatureKey)
    }

    func markInputCompleted(signature: String) {
        userDefaults.set(signature, forKey: lastCompletedInputSignatureKey)
    }

    func savePendingSuggestions(_ suggestions: [ConvergenceSuggestion], inputSignature: String) {
        guard !suggestions.isEmpty,
              let data = try? JSONEncoder().encode(
                ThoughtTagConvergenceSuggestionRecord(
                    inputSignature: inputSignature,
                    suggestions: suggestions
                )
              ) else {
            clearPendingSuggestions()
            return
        }
        userDefaults.set(data, forKey: pendingSuggestionsKey)
    }

    func loadPendingSuggestions() -> ThoughtTagConvergenceSuggestionRecord? {
        guard let data = userDefaults.data(forKey: pendingSuggestionsKey) else { return nil }
        return try? JSONDecoder().decode(ThoughtTagConvergenceSuggestionRecord.self, from: data)
    }

    func clearPendingSuggestions() {
        userDefaults.removeObject(forKey: pendingSuggestionsKey)
    }

    private func save(_ record: ThoughtTagConvergenceJobRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}
