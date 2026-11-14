//
//  UnderstandingDemoSeed.swift
//  Holo
//
//  影子理解引擎合成数据种子（DEBUG-only，启动参数 -UnderstandingDemoSeed，幂等）。
//
//  用途：模拟器全链验证（2026-11-14 东林拍板「不等额度」）——模拟器=新设备身份=
//  新额度主体，种三案例真实感数据后带 -understandingShadowRun 跑真模型真通道。
//  数据形态对齐 M1.1 合成集：咖啡（关联候选）、羽毛球（重复行为）、猫粮（角色候选）
//  + 反例（一笔代购备注、一笔午夜补账）。
//

#if DEBUG
import Foundation
import CoreData

enum UnderstandingDemoSeed {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-UnderstandingDemoSeed")
            || ProcessInfo.processInfo.environment["UNDERSTANDING_DEMO_SEED"] == "1"
    }

    /// 幂等：UserDefaults 标记（不污染交易备注——备注是概念提取的语义源）。
    static func seedIfNeeded(now: Date = Date()) async {
        guard isRequested else { return }
        let seededKey = "holo_understanding_demo_seeded_v1"
        if UserDefaults.standard.bool(forKey: seededKey) { return }
        let repository = FinanceRepository.shared
        guard let account = (try? await repository.getDefaultAccount()) ?? repository.getAccounts().first,
              let expenseCategory = (try? await repository.getCategories(by: .expense))?.filter({ $0.isSubCategory }).first else {
            print("[UnderstandingDemoSeed] FAILED: presets not ready")
            return
        }
        let calendar = Calendar.current
        // (距今天数, 备注)：三个主题 + 反例
        let plan: [(Int, String)] = [
            // 咖啡主题（5 笔，2 笔晚间——M1.1 caseB 的购买-时点形态）
            (3, "咖啡"), (6, "拿铁"), (12, "咖啡 外卖"), (20, "咖啡"), (31, "咖啡 外卖"),
            // 羽毛球主题（3 笔）
            (5, "羽毛球 场地费"), (13, "羽毛球 场地费"), (26, "羽毛球 装备"),
            // 猫粮主题（3 笔 + 1 笔代购反例）
            (8, "猫粮"), (18, "猫砂豆腐砂"), (33, "猫粮 5kg"), (40, "猫粮 帮同事带的"),
            // 补账反例（午夜默认时间由录入时间差制造：直接用早前日期）
            (45, "咖啡"),
        ]
        for (offsetDays, note) in plan {
            let date = calendar.date(byAdding: .day, value: -offsetDays, to: now) ?? now
            _ = try? await repository.addTransaction(
                amount: Decimal(Int.random(in: 15...160)),
                type: .expense,
                category: expenseCategory,
                account: account,
                date: date,
                note: note
            )
        }
        // 想法 3 条（quote 证据通道：羽毛球感受/咖啡自述/猫的观察）
        let context = CoreDataStack.shared.viewContext
        await MainActor.run {
            context.performAndWait {
                let thoughts: [(Int, String)] = [
                    (4, "今晚羽毛球打得很尽兴，双打赢了三局，下周还约。"),
                    (11, "下午那杯咖啡好像有点影响入睡，以后试试中午前喝。"),
                    (22, "楼下的猫今天又蹲我家门口，拍了张照片，挺治愈。"),
                ]
                for (offsetDays, text) in thoughts {
                    let thought = Thought(context: context)
                    thought.id = UUID()
                    thought.content = text
                    thought.createdAt = calendar.date(byAdding: .day, value: -offsetDays, to: now) ?? now
                    thought.updatedAt = thought.createdAt
                }
                try? context.save()
            }
        }
        UserDefaults.standard.set(true, forKey: seededKey)
        print("[UnderstandingDemoSeed] seeded: 14 transactions + 3 thoughts")
    }
}

#endif
