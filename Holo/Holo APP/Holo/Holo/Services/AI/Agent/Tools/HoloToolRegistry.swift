//
//  HoloToolRegistry.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 2.2 工具注册中心
//  登记所有可用 HoloDataTool，供 Executor 查找，并汇总为 LLM 可读的 Prompt 描述。
//

import Foundation

actor HoloToolRegistry {

    private var tools: [String: HoloDataTool] = [:]

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
