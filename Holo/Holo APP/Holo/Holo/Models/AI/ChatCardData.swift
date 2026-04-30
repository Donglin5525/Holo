//
//  ChatCardData.swift
//  Holo
//
//  AI Chat 卡片数据模型
//  从 intent + extractedData 动态构造，零数据迁移
//

import Foundation

// MARK: - 卡片数据枚举

/// AI Chat 卡片数据
/// 渲染时从 ChatMessage 的 intent + extractedDataJSON 动态构造
enum ChatCardData: Equatable {
    case transaction(TransactionCardData)
    case task(TaskCardData)
    case habitCheckIn(HabitCheckInCardData)
    case mood(MoodCardData)
    case weight(WeightCardData)

    /// 从 intent + extractedData 构造卡片数据
    /// - Parameters:
    ///   - intent: AI 识别的意图
    ///   - data: 提取的结构化数据
    /// - Returns: 对应的卡片数据，无法构造时返回 nil
    static func from(intent: AIIntent, data: [String: String]?) -> ChatCardData? {
        guard let data = data else { return nil }

        switch intent {
        case .recordExpense:
            guard let amount = data["amount"] else { return nil }
            return .transaction(TransactionCardData(
                amount: amount,
                note: data["note"],
                primaryCategory: data["primaryCategory"],
                subCategory: data["subCategory"],
                type: "expense",
                date: data["date"]
            ))

        case .recordIncome:
            guard let amount = data["amount"] else { return nil }
            return .transaction(TransactionCardData(
                amount: amount,
                note: data["note"],
                primaryCategory: data["primaryCategory"],
                subCategory: data["subCategory"],
                type: "income",
                date: data["date"]
            ))

        case .createTask:
            guard let title = data["title"], !title.isEmpty else { return nil }
            return .task(TaskCardData(
                title: title,
                dueDate: data["dueDate"],
                priority: data["priority"]
            ))

        case .checkIn:
            guard let habitName = data["habitName"] else { return nil }
            return .habitCheckIn(HabitCheckInCardData(
                habitName: habitName,
                streak: data["streak"].flatMap { Int($0) },
                completed: data["completed"] != "false"
            ))

        case .recordMood:
            let content = data["content"] ?? ""
            guard !content.isEmpty else { return nil }
            return .mood(MoodCardData(
                mood: data["mood"],
                content: content
            ))

        case .recordWeight:
            guard let weight = data["weight"] else { return nil }
            return .weight(WeightCardData(
                weight: weight,
                unit: data["unit"] ?? "kg"
            ))

        case .completeTask, .updateTask, .deleteTask, .createNote, .queryTasks, .queryHabits, .query, .generateMemoryInsight, .unknown:
            return nil
        }
    }

    /// 关联实体 ID（从 extractedData 中获取）
    static func linkedEntityId(from data: [String: String]?) -> String? {
        guard let data = data else { return nil }
        // 优先新格式
        if let entityId = data["entityId"] { return entityId }
        // 兜底旧格式
        return data["transactionId"] ?? data["taskId"] ?? data["habitId"] ?? data["thoughtId"]
    }

    /// 从 AIExecutionItem 构建卡片数据
    static func from(executionItem: AIExecutionItem) -> ChatCardData? {
        return from(intent: executionItem.intent, data: executionItem.renderData)
    }

    /// 从 AIExecutionBatch 构建多个卡片数据
    static func multiple(from batch: AIExecutionBatch?) -> [ChatCardData] {
        guard let batch = batch else { return [] }
        return batch.items.compactMap { from(executionItem: $0) }
    }
}

// MARK: - 交易卡片数据

struct TransactionCardData: Equatable {
    let amount: String
    let note: String?
    let primaryCategory: String?
    let subCategory: String?
    let type: String        // "expense" / "income"
    let date: String?

    /// 是否为支出
    var isExpense: Bool { type == "expense" }

    /// 分类 SF Symbol 图标
    var categoryIcon: String {
        CategorySFSymbolMapper.icon(for: primaryCategory, subCategory: subCategory)
    }

    /// 显示标题（note 存在时用 note，否则用分类名）
    var displayTitle: String {
        if let note = note, !note.isEmpty {
            return note
        }
        return subCategory ?? primaryCategory ?? "未分类"
    }

    /// 分类路径（如 "餐饮 · 午餐"）
    var categoryPath: String? {
        guard let primary = primaryCategory else { return nil }
        if let sub = subCategory, !sub.isEmpty {
            return "\(primary) · \(sub)"
        }
        return primary
    }
}

// MARK: - 任务卡片数据

struct TaskCardData: Equatable {
    let title: String
    let dueDate: String?
    let priority: String?
}

// MARK: - 习惯打卡卡片数据

struct HabitCheckInCardData: Equatable {
    let habitName: String
    let streak: Int?
    let completed: Bool
}

// MARK: - 心情卡片数据

struct MoodCardData: Equatable {
    let mood: String?
    let content: String
}

// MARK: - 体重卡片数据

struct WeightCardData: Equatable {
    let weight: String
    let unit: String
}

// MARK: - 分类 SF Symbol 映射

/// 将分类名称映射到 SF Symbol 图标
/// 用于记账卡片的头部图标
enum CategorySFSymbolMapper {

    /// 一级分类 → SF Symbol
    private static let primaryMapping: [String: String] = [
        "餐饮": "fork.knife",
        "交通": "car.fill",
        "购物": "bag.fill",
        "娱乐": "music.note.list",
        "居住": "house.fill",
        "医疗": "heart.text.square.fill",
        "学习": "book.closed.fill",
        "人情": "yensign.circle.fill",
        "其他": "questionmark.folder.fill",
        "投资理财": "chart.line.uptrend.xyaxis",
        "工资收入": "banknote.fill",
        "人情来往": "gift.fill",
        "其他收入": "plus.circle.fill",
    ]

    /// 二级分类 → SF Symbol（从 Category+CoreDataProperties 的层级定义中提取）
    private static let subMapping: [String: String] = [
        // 餐饮
        "早餐": "sunrise.fill", "午餐": "sun.max.fill", "晚餐": "moon.stars.fill",
        "夜宵": "moonphase.waning.crescent", "零食": "popcorn.fill",
        "咖啡": "cup.and.saucer.fill", "外卖": "bag.fill", "饮品": "wineglass.fill",
        "水果": "carrot.fill", "酒水": "wineglass", "超市": "cart.fill",
        // 交通
        "地铁": "train.side.front.car", "打车": "car.side.fill", "公交": "bus.fill",
        "单车": "bicycle", "加油": "fuelpump.fill", "停车": "parkingsign.circle.fill",
        "火车": "train.side.rear.car", "机票": "airplane.departure",
        "旅行": "figure.walk", "过路费": "building.columns.fill",
        // 购物
        "服饰": "hanger", "数码": "desktopcomputer", "日用": "basket.fill",
        "美妆": "sparkles", "家具": "sofa.fill", "书籍": "book.fill",
        "运动": "sportscourt.fill", "礼物": "gift.fill",
        // 娱乐
        "电影": "film.fill", "游戏": "gamecontroller.fill", "视频": "play.tv.fill",
        "音乐": "music.note.list", "KTV": "mic.fill", "旅游": "airplane",
        "健身": "figure.run",
        // 居住
        "房租": "key.fill", "房贷": "banknote.fill", "水费": "drop.fill",
        "电费": "bolt.fill", "燃气": "flame.fill", "物业": "building.2.fill",
        "网费": "wifi", "家电": "tv.fill", "装修": "paintbrush.fill",
        // 医疗
        "就医": "stethoscope", "药品": "pill.fill", "体检": "heart.text.square.fill",
        "健身房": "dumbbell.fill", "保健品": "leaf.fill", "牙齿保健": "heart.circle.fill",
        "医疗用品": "cross.case.fill",
        // 学习
        "课程": "book.closed.fill", "教材": "text.book.closed.fill",
        "考试": "checkmark.rectangle.fill", "文具": "pencil.line",
        "订阅": "arrow.trianglehead.clockwise",
        // 人情（支出）
        "红包礼金": "yensign.circle.fill", "请客": "wineglass.fill",
        "送礼": "gift.fill", "探望": "figure.walk.arrival",
        "其他": "ellipsis.circle.fill",
        // 其他支出
        "社交": "person.2.fill", "宠物": "pawprint.fill", "理发": "scissors",
        "洗衣": "washer.fill", "话费": "phone.fill", "烟酒": "smoke.fill",
        "维修": "wrench.fill", "保险": "shield.checkered",
        "还款": "arrow.uturn.backward.circle.fill", "转账": "arrow.right.circle.fill",
        "捐赠": "heart.fill",
        // 投资理财（收入）
        "利息": "percent", "股票": "chart.line.uptrend.xyaxis",
        "房租收入": "building.columns.fill", "其他投资": "chart.pie.fill",
        // 工资收入
        "工资": "banknote.fill", "奖金": "star.fill", "兼职": "briefcase.fill",
        "报销": "arrow.uturn.backward.circle.fill", "退款": "arrow.counterclockwise.circle.fill",
        // 人情来往（收入）
        "红包": "yensign.circle.fill",
        "中奖": "trophy.fill", "转入": "arrow.left.circle.fill",
        // 其他收入
        "借入": "arrow.down.circle.fill", "还款收入": "arrow.uturn.forward.circle.fill",
        "退货": "shippingbox.fill", "公积金": "building.columns.fill",
        "出闲置": "arrow.3.trianglepath",
    ]

    /// 获取分类对应的 SF Symbol
    /// 优先使用二级分类图标，回退到一级分类图标
    static func icon(for primaryCategory: String?, subCategory: String?) -> String {
        if let sub = subCategory, let icon = subMapping[sub] {
            return icon
        }
        if let primary = primaryCategory, let icon = primaryMapping[primary] {
            return icon
        }
        return "yensign.circle"
    }
}
