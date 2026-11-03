#if DEBUG && targetEnvironment(simulator)
import CoreData
import Foundation

/// 宣传图财务数据只在隔离上下文中暂存，整批成功后才写入模拟器本地库。
@MainActor
enum HoloASOFinanceSeeder {
    private struct Fixture: Decodable {
        struct Row: Decodable {
            let logicalID: String
            let uuid: UUID
            let category: String
            let amountCents: Int
            let direction: String
            let date: String
            let time: String
            let name: String
            let project: String
            enum CodingKeys: String, CodingKey {
                case uuid, category, direction, date, time, name, project
                case logicalID = "logical_id"
                case amountCents = "amount_cents"
            }
        }
        struct Group: Decodable {
            let blueprintName: String
            let parentName: String
            let childName: String
            let direction: String
            enum CodingKeys: String, CodingKey {
                case direction
                case blueprintName = "blueprint_name"
                case parentName = "parent_name"
                case childName = "child_name"
            }
        }
        let instance: String
        let referenceDate: String
        let transactions: [Row]
        let groups: [Group]
        enum CodingKeys: String, CodingKey {
            case transactions
            case instance = "fixture_instance_id"
            case referenceDate = "reference_date"
            case groups = "category_groups"
        }
    }

    static func seedIfRequested(environment: [String: String]) async throws -> Bool {
        guard environment["HOLO_ASO_V10"] == "1", environment["HOLO_ASO_FINANCE"] == "1" else { return false }
        guard !CloudKitRuntimeAvailability.isAvailable, !HoloProductAnalytics.isCollecting else {
            throw error("演示环境未隔离云同步或埋点")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL.documentsDirectory.appendingPathComponent("aso-fixture.json")))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        guard formatter.string(from: Date()) == fixture.referenceDate,
              fixture.transactions.count == 108,
              Set(fixture.transactions.map(\.uuid)).count == 108,
              Set(fixture.transactions.map(\.logicalID)).count == 108,
              fixture.groups.count == 9,
              Set(fixture.groups.map(\.blueprintName)).count == 9 else { throw error("演示文件日期或数量不匹配") }
        let groups = Dictionary(uniqueKeysWithValues: fixture.groups.map { ($0.blueprintName, $0) })
        guard fixture.transactions.allSatisfy({ $0.amountCents > 0 && groups[$0.category]?.direction == $0.direction }),
              fixture.transactions.filter({ $0.project == "城市漫游" }).reduce(0, { $0 + $1.amountCents }) == 24600 else {
            throw error("演示分类、金额或项目不匹配")
        }
        let expected = [("FIN-A-", 52, 541000, 108000), ("FIN-B-", 56, 588000, 140000)]
        for (prefix, count, expense, dining) in expected {
            let rows = fixture.transactions.filter { $0.logicalID.hasPrefix(prefix) }
            guard rows.count == count,
                  rows.filter({ $0.direction == "income" }).reduce(0, { $0 + $1.amountCents }) == 1200000,
                  rows.filter({ $0.direction == "expense" }).reduce(0, { $0 + $1.amountCents }) == expense,
                  rows.filter({ $0.category == "餐饮" }).reduce(0, { $0 + $1.amountCents }) == dining else { throw error("月度演示金额不匹配") }
        }
        let marker = "holo_aso_v10_finance_" + fixture.instance
        guard !UserDefaults.standard.bool(forKey: marker) else { return true }
        let parent = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        parent.persistentStoreCoordinator = CoreDataStack.shared.persistentContainer.persistentStoreCoordinator
        let child = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        child.parent = parent
        let repo = FinanceRepository(context: child)
        do {
            let accountRequest = Account.fetchRequest()
            accountRequest.predicate = NSPredicate(format: "name == %@ AND deletedAt == nil", "日常账户")
            guard try child.count(for: accountRequest) == 0 else { throw error("演示账户已存在，停止重复写入") }
            let transactionRequest = Transaction.fetchRequest()
            transactionRequest.predicate = NSPredicate(format: "id IN %@", fixture.transactions.map(\.uuid))
            guard try child.count(for: transactionRequest) == 0 else { throw error("演示交易已存在，停止重复写入") }
            let account = try repo.addAccount(name: "日常账户", type: .cash, initialBalance: 2000)
            var childCategories: [String: Category] = [:]
            for group in fixture.groups {
                guard let kind = TransactionType(rawValue: group.direction) else { throw error("未知收支类型") }
                let parents = try await repo.getTopLevelCategories(by: kind).filter { $0.name == group.parentName }
                guard parents.count <= 1 else { throw error("一级分类存在同名冲突") }
                let root: Category
                if let existing = parents.first { root = existing }
                else { root = try await repo.addCategory(name: group.parentName, icon: "circle.fill", color: "#D87548", type: kind) }
                let matches = try await repo.getSubCategories(parentId: root.id).filter { $0.name == group.childName }
                guard matches.count <= 1 else { throw error("二级分类存在同名冲突") }
                if let existing = matches.first { childCategories[group.blueprintName] = existing }
                else { childCategories[group.blueprintName] = try await repo.addCategory(name: group.childName, icon: "circle.fill", color: "#D87548", type: kind, parentId: root.id) }
            }
            let projectRepo = FinanceProjectRepository(finance: repo)
            let projectRequest = FinanceProject.fetchRequest()
            projectRequest.predicate = NSPredicate(format: "name == %@ AND deletedAt == nil", "城市漫游")
            guard try child.count(for: projectRequest) == 0 else { throw error("演示项目已存在") }
            guard let focusDate = fixture.transactions.first(where: { $0.logicalID.hasPrefix("FIN-B-") }).flatMap({ formatter.date(from: $0.date) }) else { throw error("项目日期无效") }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = formatter.timeZone
            guard let interval = calendar.dateInterval(of: .month, for: focusDate),
                  let end = calendar.date(byAdding: .day, value: -1, to: interval.end) else { throw error("项目月份无效") }
            let project = try projectRepo.create(name: "城市漫游", icon: "figure.walk", color: "#D87548", startDate: interval.start, endDate: end, budgetAmount: 800)
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            for row in fixture.transactions {
                guard let kind = TransactionType(rawValue: row.direction), let category = childCategories[row.category],
                      let date = formatter.date(from: row.date + " " + row.time) else { throw error("演示交易字段无效") }
                let transaction = try await repo.addTransaction(amount: Decimal(row.amountCents) / 100, type: kind, category: category, account: account, date: date, note: row.name, financeProject: row.project.isEmpty ? nil : project)
                transaction.id = row.uuid
            }
            try child.save()
            try parent.save()
            UserDefaults.standard.set(true, forKey: marker)
            NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
            print("[HoloASO] 财务演示记录已保存：108条；实例 \(fixture.instance)")
            return true
        } catch {
            child.rollback()
            parent.rollback()
            throw error
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "HoloASOFinance", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
