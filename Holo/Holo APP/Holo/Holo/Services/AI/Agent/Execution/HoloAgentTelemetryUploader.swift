//
//  HoloAgentTelemetryUploader.swift
//  Holo
//
//  Agent 遥测事件批量上报（2026-08-30 锁屏事故止血包）
//  本地 HoloAgentEventStore 只在手机上留证据，出障时远端一片空白、排查靠推演。
//  在 App 前台化/冷启动时把 watermark 之后的事件批量上报后端（≤100 条/批），
//  事件 id 全局唯一且服务端 INSERT OR IGNORE——失败重试不会产生重复行。
//  事件本身即非敏感技术字段（HoloAgentObservability 隐私契约），上报不再过滤。
//

import Foundation
import os.log

nonisolated
final class HoloAgentTelemetryUploader {

    static let shared = HoloAgentTelemetryUploader()

    private let logger = Logger(subsystem: "com.holo.app", category: "AgentTelemetry")
    private let baseURL: String
    private let apiClient: APIClient
    private let deviceIdProvider: () -> String
    private let watermarkDefaultsKey = "holo.agent.telemetry.uploadWatermarkMs"
    private let maxBatchSize = 100

    init(
        baseURL: String = HoloBackendEnvironment.baseURL,
        apiClient: APIClient = .shared,
        deviceIdProvider: @escaping () -> String = { HoloBackendDeviceIdentity.shared.deviceId }
    ) {
        self.baseURL = baseURL
        self.apiClient = apiClient
        self.deviceIdProvider = deviceIdProvider
    }

    /// 增量上报；无新事件/失败均静默（下次前台化再试），绝不影响调用方主流程。
    func uploadIfNeeded() async {
        let events: [HoloAgentTelemetryEvent]
        do {
            events = try await HoloAgentEventStore.shared.load()
        } catch {
            logger.error("读取本地遥测事件失败，跳过本轮上报")
            return
        }
        let watermarkMs = UserDefaults.standard.double(forKey: watermarkDefaultsKey)
        let pending = events
            .filter { $0.timestamp.timeIntervalSince1970 * 1000 >= watermarkMs }
            .sorted { $0.timestamp < $1.timestamp }
            .prefix(maxBatchSize)
        guard !pending.isEmpty else { return }

        let request = APIRequest(
            baseURL: baseURL,
            path: "/v1/ai/agent/telemetry",
            method: .post,
            headers: [
                "X-Holo-Device-Id": deviceIdProvider()
            ],
            body: TelemetryUploadRequest(events: pending.map(Payload.init))
        )
        do {
            let response: TelemetryUploadResponse = try await apiClient.send(request)
            guard response.ok else {
                logger.error("遥测上报被拒绝，保留 watermark 待重试")
                return
            }
            // 推进 watermark +1ms：取数用 >=，推进越过一个毫秒避免同刻新事件被跳过。
            let lastMs = pending.last!.timestamp.timeIntervalSince1970 * 1000
            UserDefaults.standard.set(lastMs + 1, forKey: watermarkDefaultsKey)
            logger.info("遥测上报成功 accepted=\(response.accepted, privacy: .public)")
        } catch {
            logger.error("遥测上报失败（下次前台化重试）：\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - 上报契约（字段与后端 normalizeAgentTelemetryEvent 一一对应）

    private struct TelemetryUploadRequest: Encodable {
        let events: [Payload]
    }

    private struct Payload: Encodable {
        let id: String
        let name: String
        let timestampMs: Int64
        let jobID: String?
        let jobType: String?
        let trigger: String?
        let state: String?
        let waitReason: String?
        let generation: Int?
        let checkpointRevision: Int?
        let leaseKind: String?
        let round: Int?
        let durationMilliseconds: Int?
        let errorCode: String?
        let requestID: String?
        let promptRevision: Int?
        let agentProtocolVersion: Int?
        let toolSchemaVersion: Int?
        let contractViolationCount: Int?
        let contractRepairCount: Int?

        init(_ event: HoloAgentTelemetryEvent) {
            self.id = event.id
            self.name = event.name.rawValue
            self.timestampMs = Int64(event.timestamp.timeIntervalSince1970 * 1000)
            self.jobID = event.jobID
            self.jobType = event.jobType?.rawValue
            self.trigger = event.trigger?.rawValue
            self.state = event.state?.rawValue
            self.waitReason = event.waitReason?.rawValue
            self.generation = event.generation
            self.checkpointRevision = event.checkpointRevision
            self.leaseKind = event.leaseKind?.rawValue
            self.round = event.round
            self.durationMilliseconds = event.durationMilliseconds
            self.errorCode = event.errorCode
            self.requestID = event.requestID
            self.promptRevision = event.promptRevision
            self.agentProtocolVersion = event.agentProtocolVersion
            self.toolSchemaVersion = event.toolSchemaVersion
            self.contractViolationCount = event.contractViolationCount
            self.contractRepairCount = event.contractRepairCount
        }
    }

    private struct TelemetryUploadResponse: Decodable {
        let ok: Bool
        let accepted: Int
    }
}
