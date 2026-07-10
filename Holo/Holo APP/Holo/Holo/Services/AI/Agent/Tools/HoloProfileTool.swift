//
//  HoloProfileTool.swift
//  Holo
//
//  只暴露 HoloProfile 的结构化字段，不返回原始 Markdown。
//

import Foundation

struct HoloProfileToolSnapshot: Codable, Equatable, Sendable {
    var preferredName: String?
    var language: String?
    var timezone: String?
    var city: String?
    var profession: String?
    var communicationStyle: [String]
    var currentFocus: [String]
    var lifeContext: [String]
    var healthHabitContext: [String]
    var sensitiveBoundaries: [String]

    var isEmpty: Bool {
        [preferredName, language, timezone, city, profession].compactMap { $0 }.isEmpty
            && communicationStyle.isEmpty
            && currentFocus.isEmpty
            && lifeContext.isEmpty
            && healthHabitContext.isEmpty
            && sensitiveBoundaries.isEmpty
    }
}

protocol HoloProfileDataSource: Sendable {
    func snapshot() async -> HoloProfileToolSnapshot?
}

struct HoloProfileTool: HoloDataTool {

    let descriptor = HoloToolDescriptor(
        name: "profile",
        description: "用户主动维护的个人档案（基础资料 / 当前关注 / 沟通偏好 / 敏感边界）",
        supportedQueries: ["profile_summary", "current_focus", "preference_boundaries"],
        supportedTimeRanges: [],
        outputMetrics: [
            "profile.field.count",
            "profile.focus.count",
            "profile.communication_style.count",
            "profile.sensitive_boundary.count"
        ],
        sensitivityPolicy: "sensitive"
    )

    private let dataSource: HoloProfileDataSource

    init(dataSource: HoloProfileDataSource) {
        self.dataSource = dataSource
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult {
        descriptor.supportedQueries.contains(request.query)
            ? .valid
            : .invalid(reason: "不支持的档案查询：\(request.query)")
    }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        guard let snapshot = await dataSource.snapshot(), !snapshot.isEmpty else {
            return result(
                request,
                status: .empty,
                metrics: [],
                events: [],
                warnings: [HoloToolWarning(code: "NO_PROFILE_DATA", message: "用户尚未填写可供 AI 使用的个人档案")]
            )
        }

        switch request.query {
        case "profile_summary":
            return profileSummary(request, snapshot: snapshot)
        case "current_focus":
            return currentFocus(request, snapshot: snapshot)
        case "preference_boundaries":
            return preferenceBoundaries(request, snapshot: snapshot)
        default:
            return result(
                request,
                status: .error,
                metrics: [],
                events: [],
                warnings: [],
                error: HoloToolError(
                    code: HoloToolErrorCode.invalidParams,
                    message: "不支持的档案查询：\(request.query)",
                    recoverable: true
                )
            )
        }
    }
}

private extension HoloProfileTool {

    func profileSummary(
        _ request: HoloToolRequest,
        snapshot: HoloProfileToolSnapshot
    ) -> HoloDataToolResult {
        let fields: [(String, String?)] = [
            ("称呼", snapshot.preferredName),
            ("语言", snapshot.language),
            ("时区", snapshot.timezone),
            ("城市", snapshot.city),
            ("职业", snapshot.profession)
        ]
        let available = fields.compactMap { label, value -> (String, String)? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return (label, value)
        }
        guard !available.isEmpty else {
            return result(
                request,
                status: .empty,
                metrics: [],
                events: [],
                warnings: [HoloToolWarning(code: "NO_PROFILE_SUMMARY", message: "档案中没有基础资料")]
            )
        }
        return result(
            request,
            metrics: [metric("profile.field.count", Double(available.count), unit: "项")],
            events: available.enumerated().map { index, field in
                event(id: "profile-field-\(index)", key: "profile.field", excerpt: "\(field.0)：\(field.1)")
            }
        )
    }

    func currentFocus(
        _ request: HoloToolRequest,
        snapshot: HoloProfileToolSnapshot
    ) -> HoloDataToolResult {
        let items = snapshot.currentFocus.map { ("当前关注", $0) }
            + snapshot.lifeContext.map { ("生活上下文", $0) }
            + snapshot.healthHabitContext.map { ("健康与习惯目标", $0) }
        guard !items.isEmpty else {
            return result(
                request,
                status: .empty,
                metrics: [],
                events: [],
                warnings: [HoloToolWarning(code: "NO_PROFILE_FOCUS", message: "档案中没有当前关注或目标")]
            )
        }
        return result(
            request,
            metrics: [metric("profile.focus.count", Double(items.count), unit: "项")],
            events: items.enumerated().map { index, item in
                event(id: "profile-focus-\(index)", key: "profile.focus.item", excerpt: "\(item.0)：\(item.1)")
            }
        )
    }

    func preferenceBoundaries(
        _ request: HoloToolRequest,
        snapshot: HoloProfileToolSnapshot
    ) -> HoloDataToolResult {
        guard !snapshot.communicationStyle.isEmpty || !snapshot.sensitiveBoundaries.isEmpty else {
            return result(
                request,
                status: .empty,
                metrics: [],
                events: [],
                warnings: [HoloToolWarning(code: "NO_PROFILE_PREFERENCES", message: "档案中没有沟通偏好或敏感边界")]
            )
        }
        let styleEvents = snapshot.communicationStyle.enumerated().map { index, value in
            event(id: "profile-style-\(index)", key: "profile.communication_style", excerpt: "沟通偏好：\(value)")
        }
        let boundaryEvents = snapshot.sensitiveBoundaries.enumerated().map { index, value in
            event(id: "profile-boundary-\(index)", key: "profile.sensitive_boundary", excerpt: "敏感边界：\(value)")
        }
        return result(
            request,
            metrics: [
                metric("profile.communication_style.count", Double(snapshot.communicationStyle.count), unit: "项"),
                metric("profile.sensitive_boundary.count", Double(snapshot.sensitiveBoundaries.count), unit: "项")
            ],
            events: styleEvents + boundaryEvents
        )
    }

    func result(
        _ request: HoloToolRequest,
        status: HoloToolResultStatus = .success,
        metrics: [HoloMetric],
        events: [HoloEvidenceEvent],
        warnings: [HoloToolWarning] = [],
        error: HoloToolError? = nil
    ) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id,
            tool: request.tool,
            status: status,
            coverage: nil,
            metrics: metrics,
            events: events,
            warnings: warnings,
            error: error,
            sensitivity: .sensitive
        )
    }

    func metric(_ key: String, _ value: Double, unit: String) -> HoloMetric {
        HoloMetric(metricKey: key, value: value, unit: unit, baselineValue: nil, comparison: nil)
    }

    func event(id: String, key: String, excerpt: String) -> HoloEvidenceEvent {
        HoloEvidenceEvent(id: id, occurredAt: nil, metricKey: key, metricValue: nil, excerpt: excerpt)
    }
}
