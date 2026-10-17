//
//  WelcomeNoteSeed.swift
//  Holo
//
//  预置欢迎笔记（新人笔记）：新用户首启种进想法模块的一条真实想法，
//  承担产品理念与功能速览的内容化引导——用户在真实编辑器里读它、编辑它，
//  笔记本身就是「想法长什么样」的示范。四页引导完成后由 HomeView 深链直达。
//
//  种子口径与财务种子同族：
//  - 物理空表才种（含软删/归档行一起数），存量老用户自动跳过；
//  - 重装/跨设备误种由 SeedRevivalRepair 的铁证判定清理（想法 createdAt 早于
//    种子时刻 = 老用户回来了；用户删过笔记的重装也走这条路，预设不复活）；
//  - 文案按 SeedLocalization 固化语言三语落库，种下去那一刻是什么语言就是什么语言。
//
//  必达跳转（与识图复核页同语义）：完成引导时落 pending，编辑器真正打开
//  笔记才清（ack）；中途杀 App 下次启动 onAppear 继续跳，直到送达。
//

import CoreData
import Foundation

enum WelcomeNoteSeed {

    /// 预置笔记身份键：深链直达、激活/统计/AI 管线排除、设置页找回入口共用同一 UUID
    static let noteId = UUID(uuidString: "7A90B5C4-3E21-4F8B-9D06-5E1A2C3B4D5F")!

    /// 欢迎笔记跳转待送达标记（落盘 key 注册在 OnboardingProgressStore）
    private static let pendingKey = OnboardingProgressStore.welcomeNotePendingKey

    // MARK: - 种子

    /// 新用户首启种欢迎笔记。物理空表（任何 Thought 行都不存在，含软删/归档）
    /// 才种：空表即新用户，种过/存量老用户/删光想法的老用户都自动跳过。
    static func seedIfNeeded(context: NSManagedObjectContext) {
        let request = Thought.fetchRequest()
        if ((try? context.count(for: request)) ?? 0) > 0 { return }

        let note = Thought(context: context)
        note.id = noteId
        note.content = localizedNoteContent.currentValue
        note.firstLine = localizedNoteTitle.currentValue
        // 先记种子时刻再取行时间戳：保证 seedMoment ≤ createdAt（fresh 判定用
        // createdAt >= seedMoment，顺序反了微秒差会让重装清理永远不触发）
        SeedRevivalRepair.recordSeedMoment()
        note.createdAt = Date()
        note.updatedAt = note.createdAt
        note.organizedStatus = "disabled"
        try? context.save()
    }

    /// 欢迎笔记是否还在库里（未软删；设置页找回入口的显隐依据）
    static func isNoteAlive(context: NSManagedObjectContext = CoreDataStack.shared.viewContext) -> Bool {
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(
            format: "id == %@ AND deletedAt == nil",
            noteId as CVarArg
        )
        request.fetchLimit = 1
        return ((try? context.count(for: request)) ?? 0) > 0
    }

    /// 预置欢迎笔记的排除谓词：挂到「用户记录信号」的取数源头
    /// （激活判定/统计聚合/AI 整理入队/情境萃取），预置内容不冒充用户生活。
    static var exclusionPredicate: NSPredicate {
        NSPredicate(format: "id != %@", noteId as CVarArg)
    }

    // MARK: - 必达跳转状态

    /// 是否有待送达的欢迎笔记跳转（完成引导时落下，编辑器真正打开才清）
    static var isPendingPresentation: Bool {
        UserDefaults.standard.bool(forKey: pendingKey)
    }

    static func markPendingPresentation(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: pendingKey)
    }

    /// 编辑器真正打开欢迎笔记时清除 pending（送达回执）
    static func acknowledgePresentation(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: pendingKey)
    }

    // MARK: - 三语文案

    /// 笔记标题（落 firstLine；正文首行同文案，列表卡片显示它）
    static let localizedNoteTitle = SeedTerm(
        hans: "欢迎来到 Holo",
        hant: "歡迎來到 Holo",
        english: "Welcome to Holo"
    )

    /// 笔记正文（纯 Markdown 文本；#/@ 以文字示例出现，不做结构化 Token——
    /// Token 绑定实体主键，预置内容跨设备/重装后主键对不上会悬空）
    static let localizedNoteContent = SeedTerm(
        hans: """
        欢迎来到 Holo

        这是一条想法。在 Holo 里，生活的一切都值得被记录——一个念头、一笔账、一件待办、一次打卡，时间久了，它们会汇成你的记忆。

        从首页的功能宫格可以进入各个模块：

        · 想法：随手记下念头，可以加 #标签、用 @引用 串起相关想法
        · 财务：记账与预算，看懂钱去哪儿了
        · 任务：待办清单，也管「正在进行的事」
        · 习惯：每天的小坚持，打卡看得见
        · AI 伙伴：像聊天一样，一句话记录，或直接问自己的数据

        这条笔记本身就是演示：你可以编辑它、归档它，也可以删掉它——它是你的。

        现在，试着记下你的第一个想法吧：点右下角的 ＋。
        """,
        hant: """
        歡迎來到 Holo

        這是一條想法。在 Holo 裡，生活的一切都值得被記錄——一個念頭、一筆帳、一件待辦、一次打卡，時間久了，它們會匯成你的記憶。

        從首頁的功能宮格可以進入各個模組：

        · 想法：隨手記下念頭，可以加 #標籤、用 @引用 串起相關想法
        · 財務：記帳與預算，看懂錢去哪兒了
        · 任務：待辦清單，也管「正在進行的事」
        · 習慣：每天的小堅持，打卡看得見
        · AI 夥伴：像聊天一樣，一句話記錄，或直接問自己的資料

        這條筆記本身就是示範：你可以編輯它、封存它，也可以刪掉它——它是你的。

        現在，試著記下你的第一個想法吧：點右下角的 ＋。
        """,
        english: """
        Welcome to Holo

        This is a thought. In Holo, everything in your life is worth recording—a passing idea, an expense, a to-do, a daily habit. Over time, they become your memory.

        Open each module from the home screen:

        · Thoughts: capture ideas on the fly, with #tags and @references to link related notes
        · Finance: track spending and budgets
        · Tasks: to-dos and things in progress
        · Habits: small daily wins you can see
        · AI companion: chat naturally—record in one sentence, or ask about your own data

        This note is itself a demo: edit it, archive it, or delete it—it's yours.

        Now, try capturing your first thought: tap the ＋ in the corner.
        """
    )
}
