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
    case analysisSummary(AnalysisSummaryCardData)
    case analysisTrend(AnalysisTrendCardData)
    case analysisBreakdown(AnalysisBreakdownCardData)
    case analysisComparison(AnalysisComparisonCardData)
    case analysisHighlights(AnalysisHighlightsCardData)

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
                priority: data["priority"],
                description: data["description"],
                subtasks: SubtaskParser.parse(data["subtasks"]),
                reminderDate: data["reminderDate"],
                requiresConfirmation: data["confirmationStatus"] == "pending"
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

        case .completeTask, .updateTask, .deleteTask, .createNote, .queryTasks, .queryHabits, .query, .queryAnalysis, .generateMemoryInsight, .unknown:
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
    let description: String?
    let subtasks: [String]
    let reminderDate: String?
    let requiresConfirmation: Bool

    init(
        title: String,
        dueDate: String?,
        priority: String?,
        description: String? = nil,
        subtasks: [String] = [],
        reminderDate: String? = nil,
        requiresConfirmation: Bool = false
    ) {
        self.title = title
        self.dueDate = dueDate
        self.priority = priority
        self.description = description
        self.subtasks = subtasks
        self.reminderDate = reminderDate
        self.requiresConfirmation = requiresConfirmation
    }
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
        FinancePendingCategory.currentName: "questionmark.circle.fill",
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
        "充电": "bolt.car.fill", "洗车": "car.rear.waves.up.fill",
        "车辆保养": "wrench.and.screwdriver.fill", "违章罚款": "exclamationmark.triangle.fill",
        "火车": "train.side.rear.car", "机票": "airplane.departure",
        "旅行": "figure.walk", "过路费": "building.columns.fill",
        // 购物
        "服饰": "hanger", "数码": "desktopcomputer", "日用": "basket.fill",
        "美妆": "sparkles", "家具": "sofa.fill", "书籍": "book.fill",
        "运动": "sportscourt.fill", "礼物": "gift.fill",
        // 娱乐
        "电影": "film.fill", "游戏": "gamecontroller.fill", "视频": "play.tv.fill",
        "音乐": "music.note.list", "KTV": "mic.fill", "旅游": "airplane",
        "住宿": "bed.double.fill", "门票": "ticket.fill", "健身": "figure.run",
        // 居住
        "房租": "key.fill", "房贷": "banknote.fill", "水费": "drop.fill",
        "电费": "bolt.fill", "燃气": "flame.fill", "物业": "building.2.fill",
        "网费": "wifi", "家电": "tv.fill", "装修": "paintbrush.fill",
        "家政保洁": "person.2.badge.gearshape.fill", "搬家": "shippingbox.and.arrow.backward.fill",
        // 医疗
        "就医": "stethoscope", "药品": "pill.fill", "体检": "heart.text.square.fill",
        "健身房": "dumbbell.fill", "保健品": "leaf.fill", "牙齿保健": "heart.circle.fill",
        "医疗用品": "cross.case.fill",
        // 学习
        "课程": "book.closed.fill", "教材": "text.book.closed.fill",
        "考试": "checkmark.rectangle.fill", "文具": "pencil.line",
        "订阅": "arrow.trianglehead.clockwise",
        "AI工具": "sparkles", "软件服务": "laptopcomputer", "云存储": "cloud.fill",
        // 人情（支出）
        "红包礼金": "yensign.circle.fill", "请客": "wineglass.fill",
        "送礼": "gift.fill", "探望": "figure.walk.arrival",
        "育儿": "figure.and.child.holdinghands", "赡养": "person.2.fill",
        "其他": "ellipsis.circle.fill",
        // 其他支出
        "社交": "person.2.fill", "宠物": "pawprint.fill", "理发": "scissors",
        "洗衣": "washer.fill", "话费": "phone.fill", "烟酒": "smoke.fill",
        "维修": "wrench.fill", "保险": "shield.checkered",
        "手续费": "dollarsign.arrow.circlepath", "税费": "building.columns.circle.fill",
        "罚款": "exclamationmark.triangle.fill", "快递": "shippingbox.fill",
        "还款": "arrow.uturn.backward.circle.fill", "转账": "arrow.right.circle.fill",
        "捐赠": "heart.fill",
        // 系统分类
        FinancePendingCategory.currentName: "questionmark.circle.fill",
        FinancePendingCategory.legacyName: "questionmark.circle.fill",
        // 投资理财（收入）
        "利息": "percent", "股票": "chart.line.uptrend.xyaxis",
        "基金": "chart.pie.fill", "房租收入": "building.columns.fill", "其他投资": "chart.pie.fill",
        // 工资收入
        "工资": "banknote.fill", "奖金": "star.fill", "兼职": "briefcase.fill",
        "项目款": "briefcase.fill", "咨询费": "person.crop.circle.badge.checkmark",
        "报销": "arrow.uturn.backward.circle.fill", "退款": "arrow.counterclockwise.circle.fill",
        // 人情来往（收入）
        "红包": "yensign.circle.fill",
        "中奖": "trophy.fill", "转入": "arrow.left.circle.fill",
        // 其他收入
        "借入": "arrow.down.circle.fill", "还款收入": "arrow.uturn.forward.circle.fill",
        "退货": "shippingbox.fill", "公积金": "building.columns.fill",
        "出闲置": "arrow.3.trianglepath", "稿费": "doc.text.fill",
        "补贴": "giftcard.fill", "个税退税": "arrow.uturn.backward.circle.fill",
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

// MARK: - 分析卡片模型

struct AnalysisSummaryCardData: Equatable {
    let domain: AnalysisDomain
    let periodLabel: String
    let metrics: [AnalysisBreakdownRow]
}

struct AnalysisTrendCardData: Equatable {
    let title: String
    let points: [AnalysisTrendPoint]
}

struct AnalysisBreakdownCardData: Equatable {
    let title: String
    let rows: [AnalysisBreakdownRow]
}

struct AnalysisComparisonCardData: Equatable {
    let title: String
    let currentValue: String
    let previousValue: String?
    let change: String?
}

struct AnalysisHighlightsCardData: Equatable {
    let highlights: [String]
    let warnings: [String]
}

struct AnalysisBreakdownRow: Equatable {
    let label: String
    let value: String
    let percent: Double?
}

struct AnalysisTrendPoint: Equatable {
    let label: String
    let value: Double
    let displayValue: String
}

// MARK: - AnalysisContext → ChatCardData 映射

extension ChatCardData {

    /// 从 AnalysisContext 生成卡片列表
    static func fromAnalysisContext(_ context: AnalysisContext) -> [ChatCardData] {
        var cards: [ChatCardData] = []

        switch context.domain {
        case .finance:
            if let f = context.finance {
                cards.append(contentsOf: financeCards(f, periodLabel: context.periodLabel))
            }
        case .habit:
            if let h = context.habit {
                cards.append(contentsOf: habitCards(h, periodLabel: context.periodLabel))
            }
        case .task:
            if let t = context.task {
                cards.append(contentsOf: taskCards(t, periodLabel: context.periodLabel))
            }
        case .thought:
            if let th = context.thought {
                cards.append(contentsOf: thoughtCards(th, periodLabel: context.periodLabel))
            }
        case .crossModule:
            if let cm = context.crossModule, !cm.isDataFree {
                cards.append(.analysisHighlights(AnalysisHighlightsCardData(
                    highlights: cm.highlights,
                    warnings: cm.warnings
                )))
            }
        case .health:
            if let ht = context.health {
                cards.append(contentsOf: healthCards(ht, periodLabel: context.periodLabel))
            }
        case .goal:
            if let g = context.goal {
                cards.append(contentsOf: goalCards(g, periodLabel: context.periodLabel))
            }
        }

        return cards
    }

    // MARK: - Finance Cards

    private static func financeCards(_ f: FinanceAnalysisContext, periodLabel: String) -> [ChatCardData] {
        var cards: [ChatCardData] = []

        // Summary
        var metrics: [AnalysisBreakdownRow] = [
            AnalysisBreakdownRow(label: "总支出", value: NumberFormatter.compactCurrency(f.totalExpense), percent: nil),
            AnalysisBreakdownRow(label: "总收入", value: NumberFormatter.compactCurrency(f.totalIncome), percent: nil),
            AnalysisBreakdownRow(label: "交易笔数", value: "\(f.transactionCount)", percent: nil),
            AnalysisBreakdownRow(label: "日均支出", value: NumberFormatter.compactCurrency(f.averageDailyExpense), percent: nil)
        ]
        if let budget = f.budgetPerformance {
            metrics.append(AnalysisBreakdownRow(label: "预算使用率", value: String(format: "%.0f%%", budget.utilizationRate), percent: budget.utilizationRate / 100))
        }
        cards.append(.analysisSummary(AnalysisSummaryCardData(
            domain: .finance,
            periodLabel: periodLabel,
            metrics: metrics
        )))

        // Breakdown
        if !f.topExpenseCategories.isEmpty {
            let rows = f.topExpenseCategories.map { cat in
                AnalysisBreakdownRow(label: cat.categoryName, value: NumberFormatter.compactCurrency(cat.amount), percent: cat.percentage / 100)
            }
            cards.append(.analysisBreakdown(AnalysisBreakdownCardData(title: "支出分类", rows: rows)))
        }

        // Trend
        if f.monthlyBreakdown.count > 1 {
            let points = f.monthlyBreakdown.map { item in
                AnalysisTrendPoint(label: item.month, value: NSDecimalNumber(decimal: item.expense).doubleValue, displayValue: NumberFormatter.compactCurrency(item.expense))
            }
            cards.append(.analysisTrend(AnalysisTrendCardData(title: "月度趋势", points: points)))
        }

        // Comparison
        if let prev = f.previousPeriodExpense, prev > 0 {
            let change = f.totalExpense - prev
            let changeStr = change >= 0 ? "+\(NumberFormatter.compactCurrency(change))" : NumberFormatter.compactCurrency(change)
            cards.append(.analysisComparison(AnalysisComparisonCardData(
                title: "环比对比",
                currentValue: NumberFormatter.compactCurrency(f.totalExpense),
                previousValue: NumberFormatter.compactCurrency(prev),
                change: changeStr
            )))
        }

        return cards
    }

    // MARK: - Habit Cards

    private static func habitCards(_ h: HabitAnalysisContext, periodLabel: String) -> [ChatCardData] {
        var cards: [ChatCardData] = []

        var metrics: [AnalysisBreakdownRow] = [
            AnalysisBreakdownRow(label: "活跃习惯", value: "\(h.activeHabitCount)", percent: nil),
            AnalysisBreakdownRow(label: "完成记录", value: "\(h.completedRecordCount)", percent: nil)
        ]
        if let rate = h.averageCompletionRate {
            metrics.append(AnalysisBreakdownRow(label: "平均完成率", value: String(format: "%.0f%%", rate * 100), percent: rate))
        }
        cards.append(.analysisSummary(AnalysisSummaryCardData(
            domain: .habit,
            periodLabel: periodLabel,
            metrics: metrics
        )))

        // Trend
        if h.dailyCompletionTrend.count > 1 {
            let points = h.dailyCompletionTrend.prefix(14).map { pt in
                AnalysisTrendPoint(label: pt.date, value: pt.rate * 100, displayValue: String(format: "%.0f%%", pt.rate * 100))
            }
            cards.append(.analysisTrend(AnalysisTrendCardData(title: "完成率趋势", points: points)))
        }

        // Highlights
        var highlights = h.topPerformingHabits.map { habitPerformanceText($0) }
        highlights += h.strugglingHabits.map { habitPerformanceText($0) }
        if !highlights.isEmpty {
            cards.append(.analysisHighlights(AnalysisHighlightsCardData(
                highlights: highlights,
                warnings: h.strugglingHabits.map { item in
                    item.polarity == .negative ? "\(item.habitName) 需要控制频率" : "\(item.habitName) 需要加油"
                }
            )))
        }

        return cards
    }

    private static func habitPerformanceText(_ item: HabitPerformanceItem) -> String {
        let rate = String(format: "%.0f%%", item.completionRate * 100)
        guard item.polarity == .negative else {
            return "\(item.habitName)：完成率 \(rate)"
        }

        if let overLimitDays = item.overLimitDays, let controlledDays = item.controlledDays {
            return "\(item.habitName)：控制率 \(rate)，超标 \(overLimitDays) 天，控制 \(controlledDays) 天"
        }
        return "\(item.habitName)：控制率 \(rate)"
    }

    // MARK: - Task Cards

    private static func taskCards(_ t: TaskAnalysisContext, periodLabel: String) -> [ChatCardData] {
        var cards: [ChatCardData] = []

        var metrics: [AnalysisBreakdownRow] = [
            AnalysisBreakdownRow(label: "总任务", value: "\(t.totalCount)", percent: nil),
            AnalysisBreakdownRow(label: "已完成", value: "\(t.completedCount)", percent: nil),
            AnalysisBreakdownRow(label: "逾期", value: "\(t.overdueCount)", percent: nil),
            AnalysisBreakdownRow(label: "完成率", value: String(format: "%.0f%%", t.completionRate * 100), percent: t.completionRate)
        ]
        if let rate = t.highPriorityCompletionRate {
            metrics.append(AnalysisBreakdownRow(label: "高优完成率", value: String(format: "%.0f%%", rate * 100), percent: rate))
        }
        cards.append(.analysisSummary(AnalysisSummaryCardData(
            domain: .task,
            periodLabel: periodLabel,
            metrics: metrics
        )))

        // Trend
        if t.dailyCompletionTrend.count > 1 {
            let points = t.dailyCompletionTrend.prefix(14).map { pt in
                AnalysisTrendPoint(label: pt.date, value: Double(pt.count), displayValue: "\(pt.count)")
            }
            cards.append(.analysisTrend(AnalysisTrendCardData(title: "每日完成趋势", points: points)))
        }

        // Comparison
        if let prev = t.previousPeriodCompletedCount, prev > 0 {
            let diff = t.completedCount - prev
            let changeStr = diff >= 0 ? "+\(diff)" : "\(diff)"
            cards.append(.analysisComparison(AnalysisComparisonCardData(
                title: "环比对比",
                currentValue: "\(t.completedCount) 个",
                previousValue: "\(prev) 个",
                change: changeStr
            )))
        }

        return cards
    }

    // MARK: - Thought Cards

    private static func thoughtCards(_ th: ThoughtAnalysisContext, periodLabel: String) -> [ChatCardData] {
        var cards: [ChatCardData] = []

        let metrics: [AnalysisBreakdownRow] = [
            AnalysisBreakdownRow(label: "想法总数", value: "\(th.totalCount)", percent: nil),
            AnalysisBreakdownRow(label: "标签数", value: "\(th.topTags.count)", percent: nil)
        ]
        cards.append(.analysisSummary(AnalysisSummaryCardData(
            domain: .thought,
            periodLabel: periodLabel,
            metrics: metrics
        )))

        // Breakdown
        if !th.moodDistribution.isEmpty {
            let rows = th.moodDistribution.map { m in
                AnalysisBreakdownRow(label: m.mood, value: "\(m.count)", percent: m.percentage / 100)
            }
            cards.append(.analysisBreakdown(AnalysisBreakdownCardData(title: "心情分布", rows: rows)))
        }

        return cards
    }

    // MARK: - Health Cards

    private static func healthCards(_ h: HealthAnalysisContext, periodLabel: String) -> [ChatCardData] {
        var cards: [ChatCardData] = []

        // Summary
        var metrics: [AnalysisBreakdownRow] = []
        if let steps = h.steps, !steps.isDataFree {
            metrics.append(AnalysisBreakdownRow(
                label: "步数",
                value: "日均 \(Int(steps.dailyAverage).formatted()) 步 · 达标 \(steps.goalMetDays)/\(steps.totalDays) 天",
                percent: steps.totalDays > 0 ? Double(steps.goalMetDays) / Double(steps.totalDays) : nil
            ))
        }
        if let sleep = h.sleep, !sleep.isDataFree {
            metrics.append(AnalysisBreakdownRow(
                label: "睡眠",
                value: "日均 \(String(format: "%.1f", sleep.dailyAverage))h · 达标 \(sleep.goalMetDays)/\(sleep.totalDays) 天",
                percent: sleep.totalDays > 0 ? Double(sleep.goalMetDays) / Double(sleep.totalDays) : nil
            ))
        }
        if let stand = h.stand, !stand.isDataFree {
            metrics.append(AnalysisBreakdownRow(
                label: "站立",
                value: "日均 \(String(format: "%.1f", stand.dailyAverage))h · 达标 \(stand.goalMetDays)/\(stand.totalDays) 天",
                percent: stand.totalDays > 0 ? Double(stand.goalMetDays) / Double(stand.totalDays) : nil
            ))
        }
        if let active = h.activeMinutes, !active.isDataFree {
            metrics.append(AnalysisBreakdownRow(
                label: "活动",
                value: "日均 \(Int(active.dailyAverage).formatted()) 分钟 · 达标 \(active.goalMetDays)/\(active.totalDays) 天",
                percent: active.totalDays > 0 ? Double(active.goalMetDays) / Double(active.totalDays) : nil
            ))
        }
        if let score = h.overallBodyScore {
            metrics.append(AnalysisBreakdownRow(
                label: "体表分",
                value: String(format: "%.0f", score),
                percent: score / 100
            ))
        }
        if !metrics.isEmpty {
            cards.append(.analysisSummary(AnalysisSummaryCardData(
                domain: .health,
                periodLabel: periodLabel,
                metrics: metrics
            )))
        }

        // Trend — 步数趋势
        if let steps = h.steps, steps.dailyTrend.count > 1 {
            let points = steps.dailyTrend.suffix(14).map { pt in
                AnalysisTrendPoint(label: pt.date, value: pt.rate, displayValue: "\(Int(pt.rate).formatted()) 步")
            }
            cards.append(.analysisTrend(AnalysisTrendCardData(title: "步数趋势", points: points)))
        }

        // Trend — 睡眠趋势
        if let sleep = h.sleep, sleep.dailyTrend.count > 1 {
            let points = sleep.dailyTrend.suffix(14).map { pt in
                AnalysisTrendPoint(label: pt.date, value: pt.rate, displayValue: String(format: "%.1fh", pt.rate))
            }
            cards.append(.analysisTrend(AnalysisTrendCardData(title: "睡眠趋势", points: points)))
        }

        // Comparison — 体表分环比
        if let curr = h.overallBodyScore, let prev = h.previousPeriodScore {
            let diff = curr - prev
            let changeStr = diff >= 0 ? "+\(String(format: "%.0f", diff))" : String(format: "%.0f", diff)
            cards.append(.analysisComparison(AnalysisComparisonCardData(
                title: "体表分环比",
                currentValue: String(format: "%.0f", curr),
                previousValue: String(format: "%.0f", prev),
                change: changeStr
            )))
        }

        // Highlights
        if !h.anomalyNotes.isEmpty {
            cards.append(.analysisHighlights(AnalysisHighlightsCardData(
                highlights: [],
                warnings: h.anomalyNotes
            )))
        }

        return cards
    }

    // MARK: - Goal Cards

    private static func goalCards(_ g: GoalAnalysisContext, periodLabel: String) -> [ChatCardData] {
        var cards: [ChatCardData] = []

        // Summary
        var metrics: [AnalysisBreakdownRow] = [
            AnalysisBreakdownRow(label: "活跃目标", value: "\(g.totalActiveGoals)", percent: nil)
        ]
        if g.completedGoalsInPeriod > 0 {
            metrics.append(AnalysisBreakdownRow(label: "本周期完成", value: "\(g.completedGoalsInPeriod)", percent: nil))
        }
        if !g.atRiskGoals.isEmpty {
            metrics.append(AnalysisBreakdownRow(label: "风险目标", value: "\(g.atRiskGoals.count)", percent: nil))
        }
        cards.append(.analysisSummary(AnalysisSummaryCardData(
            domain: .goal,
            periodLabel: periodLabel,
            metrics: metrics
        )))

        // Breakdown — 各目标进度
        let progressItems = g.goals.filter { $0.overallProgress != nil || $0.linkedTaskTotal > 0 }
        if !progressItems.isEmpty {
            let rows = progressItems.map { item in
                let progressStr = item.overallProgress.map { String(format: "%.0f%%", $0 * 100) } ?? "无数据"
                let taskInfo = "\(item.linkedTaskCompleted)/\(item.linkedTaskTotal) 任务"
                return AnalysisBreakdownRow(
                    label: item.title,
                    value: "\(progressStr) · \(taskInfo)",
                    percent: item.overallProgress
                )
            }
            cards.append(.analysisBreakdown(AnalysisBreakdownCardData(title: "目标进度", rows: rows)))
        }

        // Highlights
        var highlights: [String] = []
        var warnings: [String] = g.atRiskGoals.map { "\($0) 需要关注" }
        if let prev = g.previousPeriodCompleted, prev > 0 {
            let diff = g.completedGoalsInPeriod - prev
            if diff > 0 {
                highlights.append("比上期多完成 \(diff) 个目标")
            }
        }
        if !highlights.isEmpty || !warnings.isEmpty {
            cards.append(.analysisHighlights(AnalysisHighlightsCardData(
                highlights: highlights,
                warnings: warnings
            )))
        }

        return cards
    }
}
