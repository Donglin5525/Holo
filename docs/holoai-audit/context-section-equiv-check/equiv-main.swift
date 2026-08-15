// P0 等价性验证工具：旧手写块渲染（复刻自 HEAD）vs 新注册表渲染，逐字节比对。
// 独立编译运行：stub 掉 UserContext 相关类型，AIContextSection.swift 原样参与编译。
// swiftc -parse-as-library AIContextSection.swift $0 -o /tmp/ctx_equiv && /tmp/ctx_equiv

import Foundation

// MARK: - Stubs（形状与真实类型一致，只含被引用的成员）

enum HoloMemorySource {
    case finance, tasks, habits, thoughts, goals, health, profile, conversation, memoryInsight
}

extension HoloMemorySource {
    var displayName: String {
        switch self {
        case .finance: return "消费记录"
        case .tasks: return "任务"
        case .habits: return "习惯"
        case .thoughts: return "想法"
        case .goals: return "目标"
        case .health: return "健康"
        case .profile: return "档案"
        case .conversation: return "对话"
        case .memoryInsight: return "洞察"
        }
    }
}

enum DataCoverageLevel { case rich, partial, empty }

struct DataCoverage {
    var level: DataCoverageLevel
    var reason: String
    var missingSources: [HoloMemorySource]
}

struct RecentLinkedTaskSummary {
    var title: String
    var itemTitles: [String]
}

struct UserContext {
    var anniversaryLines: [String] = []
    var dataCoverage: DataCoverage? = nil
    var recentLinkedTask: RecentLinkedTaskSummary? = nil
}

// MARK: - 旧渲染（复刻自 git HEAD AIUserContextMessageBuilder.swift，逐行照搬）

enum LegacyRenderer {
    static func chatBlocks(_ context: UserContext) -> String {
        var message = ""
        if !context.anniversaryLines.isEmpty {
            let lines = context.anniversaryLines.map { "- \($0)" }.joined(separator: "\n")
            message += "\n\n## 纪念日\n\n\(lines)"
        }
        if let coverage = context.dataCoverage, coverage.level != .rich {
            message += "\n\n--- 数据覆盖度 ---"
            message += "\n\(coverage.reason)"
            if !coverage.missingSources.isEmpty {
                let missing = coverage.missingSources.map { $0.displayName }.prefix(3)
                message += "\n缺失来源：\(missing.joined(separator: "、"))"
            }
        }
        return message
    }

    static func intentBlocks(_ context: UserContext) -> String {
        var message = ""
        if !context.anniversaryLines.isEmpty {
            let lines = context.anniversaryLines.map { "- \($0)" }.joined(separator: "\n")
            message += "\n\n--- 纪念日 ---"
            message += "\n\(lines)"
            message += "\n规则：用户询问某个纪念日的日期或倒计时（如「妈妈生日是哪天/还有多久」）属于事实问答，输出 mode=query、intent=query，不要 clarification，也不要 flexible_data_query（纪念日不是交易数据）。"
        }
        if let coverage = context.dataCoverage, coverage.level != .rich {
            message += "\n\n--- 数据覆盖度提示 ---"
            message += "\n当前用户数据\(coverage.level == .partial ? "部分可用" : "暂无")：\(coverage.reason)"
            message += "\n处理意图时请注意数据完整性，缺失字段需向用户确认。"
        }
        if let recent = context.recentLinkedTask {
            message += "\n\n--- 最近对话关联的任务 ---"
            message += "\n- 任务：\(recent.title)"
            if !recent.itemTitles.isEmpty {
                let shown = recent.itemTitles.prefix(15).joined(separator: "、")
                let suffix = recent.itemTitles.count > 15 ? "等共 \(recent.itemTitles.count) 项" : ""
                message += "\n- 现有条目：\(shown)\(suffix)"
            } else {
                message += "\n- 现有条目：（暂无）"
            }
            message += "\n规则：仅当用户明确针对上面这个最近的任务补充/删除/替换条目时，用 modify_task_items（填 addItems 新增、removeItems 删除，removeItems 必须引用现有条目的确切名称）；用户不是针对这个任务时不要使用。"
        }
        return message
    }
}

// MARK: - 新渲染（AIContextSection.swift 原样参与编译，此处复刻 builder 的注册表遍历）

enum RegistryRenderer {
    static func chatBlocks(_ context: UserContext) -> String {
        var message = ""
        for section in AIContextSectionRegistry.sections {
            if let block = section.chatBlock(context), !block.isEmpty {
                message += "\n\n" + block
            }
        }
        return message
    }

    static func intentBlocks(_ context: UserContext) -> String {
        var message = ""
        for section in AIContextSectionRegistry.sections {
            if let block = section.intentBlock(context), !block.isEmpty {
                message += "\n\n" + block
            }
        }
        return message
    }
}

// MARK: - 样例与比对

var failures = 0
var total = 0

func check(_ name: String, _ context: UserContext) {
    total += 1
    let legacyChat = LegacyRenderer.chatBlocks(context)
    let newChat = RegistryRenderer.chatBlocks(context)
    let legacyIntent = LegacyRenderer.intentBlocks(context)
    let newIntent = RegistryRenderer.intentBlocks(context)
    if legacyChat == newChat && legacyIntent == newIntent {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
        if legacyChat != newChat {
            print("  chat 旧: \(legacyChat.debugDescription)")
            print("  chat 新: \(newChat.debugDescription)")
        }
        if legacyIntent != newIntent {
            print("  intent 旧: \(legacyIntent.debugDescription)")
            print("  intent 新: \(newIntent.debugDescription)")
        }
    }
}

// 1. 全空
check("全空", UserContext())

// 2. 只有纪念日
check("纪念日1条", UserContext(anniversaryLines: ["妈妈生日：2026-09-01（还有17天）"]))
check("纪念日多条", UserContext(anniversaryLines: ["妈妈生日：2026-09-01（还有17天）", "结婚纪念日：2026-10-11（还有57天）", "父亲生日：2026-12-03（还有110天）"]))

// 3. 覆盖度各档
check("覆盖度partial无缺失", UserContext(dataCoverage: DataCoverage(level: .partial, reason: "健康数据未授权", missingSources: [])))
check("覆盖度partial两条缺失", UserContext(dataCoverage: DataCoverage(level: .partial, reason: "部分数据缺失", missingSources: [.health, .habits])))
check("覆盖度partial五条缺失(截断prefix3)", UserContext(dataCoverage: DataCoverage(level: .partial, reason: "部分数据缺失", missingSources: [.health, .habits, .finance, .tasks, .goals])))
check("覆盖度empty", UserContext(dataCoverage: DataCoverage(level: .empty, reason: "新用户暂无数据", missingSources: [.finance])))
check("覆盖度rich(不注入)", UserContext(dataCoverage: DataCoverage(level: .rich, reason: "数据充足", missingSources: [])))

// 4. 备忘单边界
check("备忘单无条目", UserContext(recentLinkedTask: RecentLinkedTaskSummary(title: "去山姆购物", itemTitles: [])))
check("备忘单3条", UserContext(recentLinkedTask: RecentLinkedTaskSummary(title: "去山姆购物", itemTitles: ["买牛奶", "买可乐", "买酸奶"])))
check("备忘单恰好15条", UserContext(recentLinkedTask: RecentLinkedTaskSummary(title: "去山姆购物", itemTitles: (1...15).map { "条目\($0)" })))
check("备忘单16条(触发等共后缀)", UserContext(recentLinkedTask: RecentLinkedTaskSummary(title: "去山姆购物", itemTitles: (1...16).map { "条目\($0)" })))

// 5. 组合
check("全满组合", UserContext(
    anniversaryLines: ["妈妈生日：2026-09-01（还有17天）"],
    dataCoverage: DataCoverage(level: .partial, reason: "健康数据未授权", missingSources: [.health]),
    recentLinkedTask: RecentLinkedTaskSummary(title: "去山姆购物", itemTitles: ["买牛奶"])
))
check("纪念日+覆盖度", UserContext(
    anniversaryLines: ["妈妈生日：2026-09-01（还有17天）"],
    dataCoverage: DataCoverage(level: .empty, reason: "新用户", missingSources: [.finance, .tasks, .habits, .health])
))

print("")
if failures == 0 {
    print("✅ 全部 \(total) 组样例逐字节等价")
    exit(0)
} else {
    print("❌ \(failures)/\(total) 组不等价")
    exit(1)
}
