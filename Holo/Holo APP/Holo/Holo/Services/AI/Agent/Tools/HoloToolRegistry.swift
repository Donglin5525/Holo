//
//  HoloToolRegistry.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 2.2 工具注册中心
//  登记所有可用 HoloDataTool，供 Executor 查找，并汇总为 LLM 可读的 Prompt 描述。
//

import Foundation

nonisolated enum HoloAgentToolCoverage {
    static let requiredToolNames = [
        "conversation",
        "finance",
        "goal",
        "habit",
        "health",
        "insight",
        "memory",
        "profile",
        "task",
        "thought"
    ]

    static func missingToolNames(in tools: [HoloDataTool]) -> [String] {
        let registered = Set(tools.map { $0.descriptor.name })
        return requiredToolNames.filter { !registered.contains($0) }
    }
}

actor HoloToolRegistry {

    private var tools: [String: HoloDataTool]

    /// 同步构造：用预设工具列表初始化（供 Factory 同步装配生产 runtime）。
    /// register() 保留，供运行时动态注册。
    init(tools: [HoloDataTool] = []) {
        var dict: [String: HoloDataTool] = [:]
        for tool in tools {
            dict[tool.descriptor.name] = tool
        }
        self.tools = dict
    }

    func register(_ tool: HoloDataTool) {
        tools[tool.descriptor.name] = tool
    }

    func tool(named name: String) -> HoloDataTool? {
        tools[name]
    }

    /// 汇总所有工具描述，供 LLM Prompt 了解可调用工具。按名称排序保证确定性输出。
    func promptDescription() -> String {
        let sorted = tools.values.sorted { $0.descriptor.name < $1.descriptor.name }
        let lines = sorted.map { tool in
            let d = tool.descriptor
            return "【\(d.name)】\(d.description)\n"
                + "  支持查询: \(d.supportedQueries.joined(separator: "、"))\n"
                + "  支持时间范围: \(d.supportedTimeRanges.joined(separator: "、"))\n"
                + "  输出度量: \(d.outputMetrics.joined(separator: "、"))\n"
                + "  敏感度策略: \(d.sensitivityPolicy)"
        }
        return lines.joined(separator: "\n")
    }
}
