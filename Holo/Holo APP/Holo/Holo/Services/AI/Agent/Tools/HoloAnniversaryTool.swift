//
//  HoloAnniversaryTool.swift
//  Holo
//
//  纪念日数据集（P2：作为「新数据零提示词接入」的首个实战——注册即被模型认识）。
//  固定查询 list_events 供倒计时/日期问答；动态数据集 anniversary.events 供 dynamicPlan 查询。
//

import Foundation

struct HoloAnniversaryToolRecord: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var nextDate: Date
    var daysUntil: Int
    var repeatYearly: Bool
}

protocol HoloAnniversaryDataSource: Sendable {
    func activeAnniversaries() async -> [HoloAnniversaryToolRecord]
}

/// 生产数据源：主线程读 AnniversaryRepository（viewContext 直读模式，与仓库层约定一致）
struct HoloDefaultAnniversaryDataSource: HoloAnniversaryDataSource {
    func activeAnniversaries() async -> [HoloAnniversaryToolRecord] {
        await MainActor.run {
            let reference = Date()
            return AnniversaryRepository.shared.activeAnniversaries.map { anniversary in
                HoloAnniversaryToolRecord(
                    id: anniversary.id,
                    title: anniversary.title,
                    nextDate: anniversary.nextOccurrenceDate(reference: reference),
                    daysUntil: anniversary.daysFromToday(reference: reference),
                    repeatYearly: anniversary.repeatYearly
                )
            }
        }
    }
}

struct HoloAnniversaryTool: HoloDataTool {

    let descriptor = HoloToolDescriptor(
        name: "anniversary",
        description: "纪念日/生日等固定事件：下次发生日期与倒计时（如 妈妈生日还有多久）",
        supportedQueries: ["list_events"],
        supportedTimeRanges: ["recent"],
        outputMetrics: [
            "anniversary.event.count",
            "anniversary.days_until"
        ],
        sensitivityPolicy: "normal"
    )

    private let dataSource: HoloAnniversaryDataSource

    init(dataSource: HoloAnniversaryDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        descriptor.supportedQueries.contains(request.query)
            ? .valid
            : .invalid(reason: "不支持的纪念日查询：\(request.query)")
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        let records = await dataSource.activeAnniversaries()
            .sorted { abs($0.daysUntil) < abs($1.daysUntil) }
        guard !records.isEmpty else {
            return HoloDataToolResult(
                toolRequestID: request.id,
                tool: request.tool,
                status: .empty,
                coverage: nil,
                metrics: [],
                events: [],
                warnings: [HoloToolWarning(code: "NO_ANNIVERSARY_DATA", message: "没有已保存的纪念日")],
                error: nil,
                sensitivity: .normal
            )
        }
        let reference = Date()
        let events = records.enumerated().map { index, record in
            HoloEvidenceEvent(
                id: "anniversary-\(index)",
                occurredAt: reference,
                metricKey: "anniversary.days_until",
                metricValue: Double(record.daysUntil),
                excerpt: "\(record.title)：\(record.daysUntil) 天后（\(record.repeatYearly ? "每年" : "")\(record.nextDate)）"
            )
        }
        return HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: .success,
            coverage: nil,
            metrics: [
                HoloMetric(metricKey: "anniversary.event.count", value: Double(records.count), unit: "个", baselineValue: nil, comparison: nil)
            ],
            events: events,
            warnings: [],
            error: nil,
            sensitivity: .normal
        )
    }
}
