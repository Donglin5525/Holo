//
//  HoloDomainMemoryObserverSupport.swift
//  Holo
//
//  Memory Observer 调度器：组装观察包 → 调用 LLM → 解析 → 校验 → 应用
//

import Foundation
import OSLog

protocol HoloDomainMemoryLLMClient: Sendable {
    func extract(
        request: HoloDomainObservationRequest,
        domain: HoloMemoryDomain
    ) async throws -> Data
}

#if !HOLO_MEMORY_STANDALONE
struct HoloBackendDomainMemoryLLMClient: HoloDomainMemoryLLMClient {
    func extract(
        request: HoloDomainObservationRequest,
        domain: HoloMemoryDomain
    ) async throws -> Data {
        let provider = HoloBackendAIProvider(baseURL: HoloBackendEnvironment.baseURL)
        // Release Prompt 由后端 purpose 注入；客户端只发送结构化 JSON data。
        let response = try await provider.chat(
            messages: [.user(request.userDataJSON)],
            purpose: .memoryDomainExtraction
        )
        return Data(response.utf8)
    }
}
#endif

struct HoloDomainObservationRunInput: Sendable {
    var package: HoloDomainObservationPackage
    var observationKey: String
    var extractorVersion: Int
    var promptVersion: Int
}

enum HoloDomainObservationRunResult: Equatable, Sendable {
    case succeeded(domain: HoloMemoryDomain, writtenCount: Int)
    case skippedDuplicate(domain: HoloMemoryDomain)
    case rejected(domain: HoloMemoryDomain, count: Int)
    case failed(domain: HoloMemoryDomain)
    case denied(domain: HoloMemoryDomain)
}

struct HoloDomainMemoryObserverExecutor {
    typealias StoreProvider = @Sendable () async throws -> any HoloDomainMemoryObservationStore
    typealias AccessProvider = @Sendable () async -> Bool

    private let client: any HoloDomainMemoryLLMClient
    private let storeProvider: StoreProvider
    private let accessProvider: AccessProvider
    private let logger = Logger(subsystem: HoloLog.subsystem, category: "DomainMemoryObserver")

    init(
        client: any HoloDomainMemoryLLMClient,
        storeProvider: @escaping StoreProvider,
        accessProvider: @escaping AccessProvider
    ) {
        self.client = client
        self.storeProvider = storeProvider
        self.accessProvider = accessProvider
    }

    #if !HOLO_MEMORY_STANDALONE
    static var live: HoloDomainMemoryObserverExecutor {
        HoloDomainMemoryObserverExecutor(
            client: HoloBackendDomainMemoryLLMClient(),
            storeProvider: { try await HoloMemoryRuntime.shared.repository() },
            accessProvider: {
                await MainActor.run {
                    HoloMemoryAccessPolicy.current.extractionDecision(for: .externalAI) == .allowedExternalAI
                }
            }
        )
    }
    #endif

    func run(
        _ inputs: [HoloDomainObservationRunInput],
        now: Date = Date()
    ) async -> [HoloDomainObservationRunResult] {
        var results: [HoloDomainObservationRunResult] = []
        for input in inputs {
            let domain = input.package.domain
            guard await accessProvider() else {
                results.append(.denied(domain: domain))
                continue
            }
            do {
                let store = try await storeProvider()
                if try await store.hasSuccessfulObservation(input.observationKey) {
                    results.append(.skippedDuplicate(domain: domain))
                    continue
                }
                let request = try HoloDomainObservationPackageBuilder.makeRequest(input.package)
                let raw = try await client.extract(request: request, domain: domain)
                let validation = HoloDomainMemoryOutputValidator.decodeAndValidate(
                    raw, against: input.package, now: now,
                    extractorVersion: input.extractorVersion,
                    promptVersion: input.promptVersion
                )
                guard validation.rejections.isEmpty else {
                    logger.warning("领域记忆输出被 Validator 拒绝：domain=\(domain.rawValue, privacy: .public), count=\(validation.rejections.count, privacy: .public)")
                    results.append(.rejected(domain: domain, count: validation.rejections.count))
                    continue
                }
                let upserts = try await HoloDomainMemoryObservationApplier.apply(
                    validation,
                    to: store,
                    observationKey: input.observationKey,
                    domain: domain,
                    extractorVersion: input.extractorVersion,
                    promptVersion: input.promptVersion,
                    completedAt: now
                )
                let written = upserts.filter { $0 == .inserted || $0 == .updated }.count
                results.append(.succeeded(domain: domain, writtenCount: written))
            } catch {
                // 不记录模型原文或用户数据，只保留领域和错误类型。
                logger.error("领域记忆观察失败：domain=\(domain.rawValue, privacy: .public), errorType=\(String(describing: type(of: error)), privacy: .public)")
                results.append(.failed(domain: domain))
            }
        }
        return results
    }
}
