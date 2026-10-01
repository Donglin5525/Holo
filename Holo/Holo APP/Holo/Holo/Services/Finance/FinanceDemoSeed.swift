//
//  FinanceDemoSeed.swift
//  Holo
//
//  DEBUG-only 合成数据：财务图表/账本模拟器纵向验收用。
//  启动参数 -FinanceDemoSeed 触发；幂等（窗口内已有交易即跳过）。
//  数据形状复刻 2026-09 实测场景：月末大额尖峰（触发柱截断+断口标注）、
//  跨月周（9/28~10/4 周历）、10 月全空（空态图）。
//  真机/生产不可达（#if DEBUG + 显式启动参数双门禁）。
//

#if DEBUG
import Foundation

@MainActor
enum FinanceDemoSeed {

    static let launchArgument = "-FinanceDemoSeed"

    /// 种子静默失败无证据可查，追加写沙盒 tmp 文件供 Mac 侧读取
    private static func diag(_ line: String) {
        let path = NSTemporaryDirectory() + "finance-seed-diag.log"
        let stamped = "\(Date()) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(stamped.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? stamped.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        }
    }

    static func seedIfNeeded() async {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        let repo = FinanceRepository.shared

        let calendar = Calendar.current
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 1
        guard let sept1 = calendar.date(from: comps),
              let windowEnd = calendar.date(byAdding: .month, value: 2, to: sept1) else { return }

        // 幂等：种子窗口内已有交易即跳过，保证走查可重复启动
        if let existing = try? await repo.getStatisticsTransactions(from: sept1, to: windowEnd), !existing.isEmpty {
            diag("skip: window already has \(existing.count) transactions")
            return
        }

        guard let account = (try? await repo.getDefaultAccount()) ?? repo.getAccounts().first,
              let expenseCategory = (try? await repo.getCategories(by: .expense))?.filter({ $0.isSubCategory }).first,
              let incomeCategory = (try? await repo.getCategories(by: .income))?.filter({ $0.isSubCategory }).first else {
            diag("FAILED: account/category presets not ready")
            return
        }

        func day(_ d: Int) -> Date { calendar.date(byAdding: .day, value: d - 1, to: sept1)! }

        // 9/29 收入 24000 = 唯一尖峰（次高 5500，>2 倍触发截断）；10 月刻意不种（空态图 + 跨月周）
        let plan: [(day: Int, amount: Decimal, type: TransactionType, note: String)] = [
            (1, 5500, .expense, "房租"),
            (3, 128, .expense, "打车"),
            (5, 260, .expense, "超市"),
            (7, 89, .expense, "午饭"),
            (9, 450, .expense, "电费"),
            (11, 76, .expense, "咖啡"),
            (13, 320, .expense, "日料"),
            (15, 1500, .expense, "买鞋"),
            (17, 95, .expense, "水果"),
            (19, 210, .expense, "日用品"),
            (21, 5500, .income, "兼职结算"),
            (22, 66, .expense, "晚饭"),
            (24, 180, .expense, "电影"),
            (26, 120, .expense, "奶茶"),
            (28, 63, .expense, "早饭"),
            (29, 35, .expense, "午饭"),
            (29, 24000, .income, "项目回款"),
            (30, 4000, .expense, "购物"),
        ]

        var created = 0
        for item in plan {
            do {
                _ = try await repo.addTransaction(
                    amount: item.amount,
                    type: item.type,
                    category: item.type == .expense ? expenseCategory : incomeCategory,
                    account: account,
                    date: day(item.day),
                    note: item.note
                )
                created += 1
            } catch {
                diag("addTransaction day=\(item.day) FAILED: \(error)")
            }
        }
        diag("seeded \(created)/\(plan.count) transactions")
    }
}
#endif
