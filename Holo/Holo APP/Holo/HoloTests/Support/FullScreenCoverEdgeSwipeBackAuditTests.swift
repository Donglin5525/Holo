//
//  FullScreenCoverEdgeSwipeBackAuditTests.swift
//  HoloTests
//
//  全屏页右滑返回守门测试（东林 2026-09-01 拍板）：
//  「fullScreenCover 没有系统右滑返回，阅读/详情类全屏页必须挂边缘右滑返回」
//  此前只是踩坑速查表里的文字规矩（软约束），FinanceSearchView 漏挂导致
//  深度分析报告→财务数据依据页右滑失灵——本测试把规矩变成机器检查。
//
//  规则：
//  1. 扫描 app 源码里所有 .fullScreenCover 的内容视图；
//  2. 每个内容视图必须在登记表里登记（needsSwipe 或 exempt）；
//  3. needsSwipe 的视图，其定义文件必须含 holoEdgeSwipeBack / swipeBackToDismiss；
//  4. 新增全屏页面未登记 → 测试红灯，按提示登记（挂手势，或写清豁免理由）。
//
//  ──────────────────────────────────────────────────────────────
//  本文件还承载第二个守门（2026-11-01，文件末尾）：PhysicalDeleteAuditTests
//  「用户数据的删除一律软删，物理删除必须在登记表登记」——删记账闪退四次复发的
//  结构性防线。两个守门同放本文件是为避开 HoloTests 手工挂载 pbxproj 的高危手术。
//

import XCTest
@testable import Holo

final class FullScreenCoverEdgeSwipeBackAuditTests: XCTestCase {

    // MARK: - 登记表（新增全屏页面必须来这里登记）

    /// 豁免清单：明确不适合右滑退出、或手势由内容页承担的全屏页，必须写理由。
    private static let exemptPages: [String: String] = [
        "ReportDetailRoute": "路由容器：手势由其内容页承担（AgentDeepAnalysisDetailSheet / ReportReplayReaderView 均已挂；2026-11-01 ChatView 三 cover 收敛单通道后 ReplayReader 改由此间接呈现，手势核验仍在定义文件）",
        "ThoughtEditorView": "编辑器：右滑误触会丢内容（HomeView 注释明确的 fullScreenCover 选型原因）",
        "CameraView": "相机取景页：系统相机交互，不适用滑动退出",
        "CSVQuickImportView": "导入流程页：多步操作流程，走明确的上一步/取消",
        "GoalDraftReviewView": "目标草稿确认页：有明确取消按钮的确认流程",
        "LifePlanReviewView": "周计划确认页：有明确取消按钮的确认流程",
        "TopicConfirmationQueueView": "主题确认队列页：批量确认流程",
        "HoloPlusPaywallView": "付费墙营销页：模态性质，有明确关闭按钮",
        "HoloMembershipCenterView": "会员中心页：营销/管理流程页",
        "ChatLogView": "DEBUG 诊断日志页（#if DEBUG 块内，不随正式包分发）",
        "PhotoLibraryPickerView": "系统照片选择器（UIImagePickerController 包装）：系统自带取消与交互，不适用滑动退出（同 CameraView）",
        "UserAvatarCropView": "头像裁剪操作页：拖动/双指缩放调整裁剪框，右滑会与拖动手势冲突，走明确取消/确认按钮（同 ThoughtEditorView 逻辑）",
        "CloudRepullView": "iCloud 重新拉取确认流程页：有明确的开始/取消按钮与进度状态，多步流程走按钮退出（同 CSVQuickImportView）",
        "HoloLightweightOnboardingView": "轻量新人引导页：选择式流程（尾闭包构造），右滑误退会丢引导进度，走明确选项按钮退出",
    ]

    /// 需要右滑返回的全屏页（阅读/详情/检索类）。定义文件必须挂手势。
    /// 注意：只登记「直接出现在 fullScreenCover 内容闭包里」的视图名——
    /// 经由其他视图间接呈现的（如 AgentDeepAnalysisDetailSheet 由 ReportDetailRoute 呈现）
    /// 不在此登记，否则反向核对（登记但无使用）会误报。
    private static let pagesNeedingSwipe: [String] = [
        "ReportFavoritesView",     // 报告收藏夹
        "FinanceSearchView",       // 财务数据依据/交易检索页（2026-09-01 事故页）
        "AnniversaryDetailView",   // 纪念日详情
        "AttachmentGalleryView",   // 任务附件画廊
        "TaskSearchView",          // 任务搜索页
        "DailyKanbanView",         // 日看板
        "ThoughtGalleryView",      // 想法图片画廊
        "TopicDetailView",         // 主题详情
        "ReceiptGalleryView",      // 票根图片画廊（已挂 holoEdgeSwipeBack，与朋友圈式下拉关闭共存）
        "TagThoughtListView",      // 标签想法列表（已挂 holoEdgeSwipeBack）
        "TaskExperienceSearchView",// 任务体验搜索页（2026-10-07 收口补挂）
    ]

    private static let auditFileName = "FullScreenCoverEdgeSwipeBackAuditTests.swift"

    // MARK: - 测试

    func testAllFullScreenCoverPagesProvideEdgeSwipeBack() throws {
        let files = try Self.collectSwiftFiles(under: Self.appSourceRoot())
        let sources: [(url: URL, source: String)] = try files.map {
            (url: $0, source: try String(contentsOf: $0, encoding: .utf8))
        }

        // 内容视图名 → 出现文件数，聚合后统一裁决
        var found: Set<String> = []
        for file in sources {
            found.formUnion(Self.extractFullScreenCoverContentViews(from: file.source))
        }

        var failures: [String] = []

        for name in found.sorted() {
            if Self.exemptPages[name] != nil { continue }
            guard Self.pagesNeedingSwipe.contains(name) else {
                failures.append("「\(name)」未登记：请在 \(Self.auditFileName) 的登记表登记——阅读/详情页加入 pagesNeedingSwipe 并挂 holoEdgeSwipeBack；不适合右滑退出的加入 exemptPages 并写明理由")
                continue
            }
            let definingFiles = sources.filter {
                $0.source.contains("struct \(name):") || $0.source.contains("final class \(name):")
            }
            if definingFiles.isEmpty {
                failures.append("「\(name)」已登记，但源码中找不到定义（struct/class 声明），请核对视图名")
                continue
            }
            let mounted = definingFiles.contains {
                $0.source.contains("holoEdgeSwipeBack") || $0.source.contains("swipeBackToDismiss")
            }
            if !mounted {
                failures.append("「\(name)」已登记为需要右滑返回，但定义文件未挂 holoEdgeSwipeBack / swipeBackToDismiss：\(definingFiles.map { $0.url.lastPathComponent })")
            }
        }

        // 登记表反向核对：登记了但源码里已无 fullScreenCover 使用的条目，提示清理，防登记表腐化
        for name in Self.pagesNeedingSwipe where !found.contains(name) {
            failures.append("「\(name)」已登记需要手势，但源码中没有 fullScreenCover 直接使用它——若已被删除或改为间接呈现，请同步清理登记表")
        }
        for name in Self.exemptPages.keys where !found.contains(name) {
            failures.append("「\(name)」已登记豁免，但源码中没有 fullScreenCover 直接使用它——若已被删除，请同步清理登记表")
        }

        XCTAssertTrue(failures.isEmpty, "全屏页右滑返回守门检查未通过：\n" + failures.joined(separator: "\n"))
    }

    // MARK: - 源码扫描

    /// 提取一个源文件里全部 .fullScreenCover(...) { ... } 尾闭包里的内容视图名。
    /// 算法：定位 `.fullScreenCover(`，对参数区做括号配对，其后若是尾闭包 `{`，
    /// 取闭包体内第一个非控制词的 `Ident(` 构造作为内容视图（提取结果与全仓写法逐一对齐过）。
    static func extractFullScreenCoverContentViews(from source: String) -> [String] {
        let controlWords: Set<String> = [
            "Binding", "if", "let", "else", "Task", "Group", "VStack", "HStack", "ZStack",
            "Some", "SomeView", "Text", "Image", "Color", "UUID", "Date", "Any", "AnyView",
            "self", "Self", "State", "StateObject", "ObservedObject", "AppStorage",
            "FocusState", "Environment", "Namespace", "UIApplication", "NotificationCenter",
            "ContentColumn", // holoContentColumn() 修饰符，非视图构造
            "LazyView",     // 惰性包装器：内容视图在其尾闭包内，跳过后继续抓深层真视图
        ]
        let marker = ".fullScreenCover("
        let chars = Array(source)
        let markerChars = Array(marker)
        var results: [String] = []
        var i = 0

        while i < chars.count {
            // 找 marker 起点
            guard let start = indexOfMarker(chars, from: i, marker: markerChars) else { break }
            var p = start + markerChars.count // 指向 '(' 的下一字符（深度从 1 起）
            var depth = 1
            while p < chars.count, depth > 0 {
                if chars[p] == "(" { depth += 1 }
                if chars[p] == ")" { depth -= 1 }
                p += 1
            }
            // p 已越过参数闭括号；跳过空白找尾闭包 '{'
            while p < chars.count, chars[p] == " " || chars[p] == "\n" || chars[p] == "\t" || chars[p] == "\r" { p += 1 }
            guard p < chars.count, chars[p] == "{" else {
                i = start + 1 // 无尾闭包（不应出现），跳过继续
                continue
            }
            // 闭包体花括号配对
            var brace = 1
            var k = p + 1
            var body: [Character] = []
            while k < chars.count, brace > 0 {
                if chars[k] == "{" { brace += 1 }
                if chars[k] == "}" { brace -= 1 }
                if brace > 0 { body.append(chars[k]) }
                k += 1
            }
            if let name = firstViewConstructor(in: String(body), excluding: controlWords) {
                results.append(name)
            }
            i = k
        }
        return results
    }

    private static func indexOfMarker(_ chars: [Character], from: Int, marker: [Character]) -> Int? {
        guard !marker.isEmpty else { return nil }
        var i = from
        while i + marker.count <= chars.count {
            if chars[i] == marker[0] {
                var match = true
                for offset in 1..<marker.count where chars[i + offset] != marker[offset] {
                    match = false
                    break
                }
                if match { return i }
            }
            i += 1
        }
        return nil
    }

    /// 闭包体内第一个 `Ident(` 或 `Ident {`（尾闭包构造，如 HoloLightweightOnboardingView { ... }）
    /// 形式的大写开头构造，跳过控制词。
    /// 尾闭包识别缺位时会漏掉真视图、误抓闭包体深处方法名里的大写片段
    /// （曾把 markPendingPresentation() 误提取为「PendingPresentation」，2026-10-18 实锤）。
    private static func firstViewConstructor(in body: String, excluding skip: Set<String>) -> String? {
        let chars = Array(body)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c.isUppercase && c.isLetter {
                // 标识符中间段不算新构造：前一个字符是字母/数字/下划线时，
                // 当前大写字母只是驼峰名的一部分（NSLog→Log、goalDraftForReview→DraftForReview），
                // 曾被误提取为视图名（2026-10-18 尾闭包识别引入，同轮修复）
                if index > 0, chars[index - 1].isLetter || chars[index - 1].isNumber || chars[index - 1] == "_" {
                    // 跳到该标识符末尾继续找
                    var end = index
                    while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" {
                        end += 1
                    }
                    index = end
                    continue
                }
                var name = ""
                var scan = index
                while scan < chars.count, chars[scan].isLetter || chars[scan].isNumber {
                    name.append(chars[scan])
                    scan += 1
                }
                var peek = scan
                while peek < chars.count, chars[peek] == " " || chars[peek] == "\n" || chars[peek] == "\t" {
                    peek += 1
                }
                if peek < chars.count, (chars[peek] == "(" || chars[peek] == "{"), !skip.contains(name) {
                    return name
                }
                index = scan
            } else {
                index += 1
            }
        }
        return nil
    }

    // MARK: - 路径

    /// 测试文件位于 …/Holo/HoloTests/Support/；删 3 级得工程根（含 Holo/ 与 HoloTests/），app 源码在 Holo/ 子目录
    static func appSourceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // HoloTests
            .deletingLastPathComponent() // 工程根（Holo.xcodeproj 所在）
            .appendingPathComponent("Holo")
    }

    static func collectSwiftFiles(under root: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let item = enumerator?.nextObject() as? URL {
            guard item.pathExtension == "swift" else { continue }
            files.append(item)
        }
        return files.sorted { $0.path < $1.path }
    }
}

// MARK: - 物理删除守门（2026-11-01 删记账闪退第四次复发后设立）

/// 「物理删除守门」：用户数据（交易/习惯/任务/想法/目标/消息等）的删除一律软删
/// （`markDeleted`，回收站批次或单条软删，30 天物理清理），持有对象的视图才能永不踩死对象。
/// 本测试扫描全库 `context.delete(` 调用：
/// 1. 文件在 fileExempts（系统数据/维护/生成代码）→ 放行；
/// 2. 其余每处调用必须落在 registeredDeletes 的 (文件, 函数) 登记里；
/// 3. 新增物理删除未登记 → 红灯。用户数据删除请改软删；
///    确属系统内部数据的，来登记表写清理由；
/// 4. 反向核对：登记的函数/文件已不存在 → 提示清理登记表（存量债迁移完成后删条目）。
///
/// 登记表冻结于 2026-11-01 全库审计快照（42 文件 108 处）。理由标「存量债」的，
/// 是还在用物理删除的用户数据路径，按交易软删路线（aef486b03）排期迁移。
final class PhysicalDeleteAuditTests: XCTestCase {

    private static let auditFileName = "FullScreenCoverEdgeSwipeBackAuditTests.swift"

    /// 文件级豁免：系统数据/维护/生成代码，整文件物理删除正当（新增需写理由）
    private static let fileExempts: [String: String] = [
        "Account+CoreDataProperties.swift": "模板生成代码",
        "AccountDataDeletionService.swift": "账户注销全清通道（用户主动触发的整库清理）",
        "CategoryLearningStore.swift": "名称制学习规则（系统数据，非用户数据）",
        "ConvergenceRejectionRepository.swift": "过期拒绝记录清理（系统维护）",
        "CoreDataHoloMemoryRepository.swift": "记忆系统内部生命周期（upsert/墓碑，有自己的治理）",
        "DiscoveryStore.swift": "发现模块内部数据生命周期（系统数据）",
        "FinanceDuplicateRepair.swift": "iCloud 重复行修复",
        "GlobalDuplicateRepair.swift": "iCloud 重复行修复",
        "HabitDuplicateRepair.swift": "iCloud 重复行修复",
        "HoloAppStoreScreenshotSeeder.swift": "诊断播种器（不随正式包跑）",
        "HoloGrowthStore.swift": "成长提醒配置（系统数据）",
        "HoloGrowthValidation.swift": "成长数据校验（系统数据）",
        "HoloMemoryControlEventStore.swift": "记忆控制事件（系统数据）",
        "HomeIconConfig+CoreDataProperties.swift": "重复配置修复（系统维护）",
        "MemoryInsight+CoreDataProperties.swift": "失败洞察清理（系统维护）",
        "MemoryInsightRepository.swift": "过期/失败洞察清理（系统维护）",
        "RecycleBinService.swift": "回收站物理清理终点（设计内唯一正当的批量物理删除）",
        "ScheduleSyncEngine.swift": "日程同步引擎维护（系统数据）",
        "SeedRevivalRepair.swift": "重装种子复活修复（对账，有意看全量）",
        "ThoughtDuplicateRepair.swift": "iCloud 重复行修复",
        "UserAvatarRepository.swift": "头像持久化替换/修复（系统数据）",
        "UserPreferenceRepository.swift": "键值偏好替换/修复（系统数据）",
    ]

    /// 函数级登记：用户数据模块的存量物理删除（冻结存量；新增函数不登记即红灯）
    /// 理由带「存量债」的 = 待按 2026-11-01 交易软删路线迁移，迁移完成后从表里删除
    private static let registeredDeletes: [String: [String: String]] = [
        "Budget+CoreDataProperties.swift": [
            "deleteAllForAccount": "账户删除级联预算（有「无交易」守卫前置）",
            "deleteForCategory": "分类删除级联预算（治理流程内）",
        ],
        "ChatMessageRepository.swift": [
            "clearAllMessages": "清空会话（设计内全清）",
            "deleteMessage": "存量债·中风险：聊天行删除（消息行被 ChatView 持有，删除后数组同步移除是时序修补）；待按软删路线迁移",
            "deleteReportMessages": "报告消息清理（随报告删除）",
        ],
        "FinanceProjectRepository.swift": [
            "deleteProject": "存量债·中风险：FinanceProject 详情/统计页持有；待按软删路线迁移",
        ],
        "FinanceRepository+Accounts.swift": [
            "deleteAccount": "存量债·低风险：有「无交易」守卫且账户持有面窄；迁移随账户模块改版",
        ],
        "FinanceRepository+CategoryDeletion.swift": [
            "<none>": "分类删除治理内部（规则/引用行级清理，2026-09 设计）",
            "applySecondary": "分类删除治理",
            "rewriteLearnedRules": "分类删除治理（同上，文档过的设计决策）",
            "softDeleteCategoryRows": "分类删除治理（2026-09 设计：规则物理删防 CloudKit 回流悬空）",
        ],
        "FinanceRepository+Import.swift": [
            "<none>": "undoImportBatch 内部分类/账户清理（2026-11-01 有意保留：交易已软删，引用计数只数有效行）",
        ],
        "FinanceRepository.swift": [
            "detachReceipt": "票据解除挂靠（行级附件数据）",
            "purgeReceiptBookingReceipts": "票据缓存清理（系统维护）",
            "syncRecurringProjects": "周期补账对账（系统维护）",
        ],
        "GoalRepository.swift": [
            "<none>": "目标保存失败回滚（save 前回滚，对象从未上屏）",
            "deleteGoal": "存量债·中风险：硬删级联 MetricLog；待按软删路线迁移",
            "deleteMetricLog": "手动记录行级删除",
        ],
        "GoalWorkshopStore.swift": [
            "discard": "目标工作台草稿丢弃（草稿，非正式数据）",
        ],
        "HabitRepository+InteractionRebuild.swift": [
            "<none>": "交互记录重建（系统维护）",
            "performAddNumericReceipt": "数值回执重建（系统维护）",
        ],
        "HabitRepository.swift": [
            "addNumericRecord": "数值记录替换旧值（行级）",
            "bridgeRecordsForTypeChange": "习惯类型切换重建（系统维护，行级记录）",
            "deleteHabit": "存量债·高风险：硬删级联全部记录，习惯视图持有面广（列表/今日/详情/统计）；最优先迁移",
            "deleteHabitById": "存量债·高风险：同上（dismiss 后延迟删除是历史时序绕行补丁）",
            "<none>": "存量债·高风险：与 deleteHabit 同族的内部物理删除",
            "simulateStreakAfterRetroactiveCheckIn": "补打卡模拟重建（系统维护）",
        ],
        "LifePlanRepository.swift": [
            "deleteGoal": "LifePlan 版本切换维护（计划草稿层）",
            "deleteHabit": "LifePlan 版本切换维护",
            "deleteTask": "LifePlan 版本切换维护",
        ],
        "ThoughtRepository+Attachments.swift": [
            "deleteAttachment": "想法附件行级删除（文件同步删）",
        ],
        "ThoughtRepository+EditorCommit.swift": [
            "<none>": "编辑提交内部（行级）",
            "syncReferencesDiff": "引用同步（行级）",
        ],
        "ThoughtRepository+RichContent.swift": [
            "replaceReferences": "富文本引用替换（行级）",
        ],
        "ThoughtRepository+TagManagement.swift": [
            "<none>": "标签管理内部（行级）",
            "deleteTagGlobally": "标签全局删除（行级关联）",
        ],
        "ThoughtRepository.swift": [
            "<none>": "存量债·中风险：想法内部行级（引用/标签关联）；主路径已软删",
            "deleteAllThoughtData": "全清通道（设计内）",
            "deleteTag": "标签删除（行级关联数据）",
            "hardDelete": "回收站终清/全清通道（设计内）",
            "removeReference": "引用行级",
            "replaceUnconfirmedAITagAssignments": "AI 标签替换（系统维护）",
            "normalizeExistingTags": "标签归一化（系统维护）",
        ],
        "TodoRepository+Attachments.swift": [
            "deleteAttachment": "任务附件行级删除（文件同步删）",
        ],
        "TodoRepository.swift": [
            "addCheckItem": "勾选项重建（行级）",
            "clearTrash": "回收站终清（设计内）",
            "deleteCheckItem": "行级勾选项（2026-08 已修调用方时序；CheckItem 无独立详情页，持有面窄）",
            "deleteFolder": "存量债·中高风险：级联删清单全部任务；待按软删路线迁移",
            "deleteList": "存量债·中高风险：同上",
            "deleteRepeatRule": "重复规则（行级配置）",
            "permanentlyDeleteTask": "回收站「彻底删除」入口（用户明示永久删，语义正当；视图持有风险随迁移评估）",
        ],
        "TopicRepository.swift": [
            "delete": "存量债·低风险：话题删除（合并/清理场景，想法本体不受影响）；待评估回收站",
            "pruneEmptyPresetTopics": "空预设话题清理（系统维护）",
        ],
    ]

    // MARK: - 测试

    func testAllPhysicalDeletesAreRegisteredOrSoftDeleted() throws {
        let sources = try Self.collectSources()
        var failures: [String] = []
        var filesWithDeletes: Set<String> = []

        for (fileName, source) in sources {
            let sites = Self.physicalDeleteSites(source)
            guard !sites.isEmpty else { continue }
            filesWithDeletes.insert(fileName)
            // 文件级豁免：系统数据/维护，整文件正当
            if Self.fileExempts[fileName] != nil { continue }

            let registered = Self.registeredDeletes[fileName] ?? [:]
            for site in sites {
                let key = site.functionName ?? "<none>"
                if registered[key] == nil {
                    failures.append("\(fileName) L\(site.line)（\(key)）：物理删除未登记。用户数据删除一律改软删 markDeleted（先例 aef486b03 交易软删化）；确属系统内部数据，在 \(Self.auditFileName) 的 registeredDeletes 登记并写清理由")
                }
            }
        }

        // 反向核对①：登记的文件已无任何物理删除 → 清理
        for fileName in Self.registeredDeletes.keys where !filesWithDeletes.contains(fileName) {
            failures.append("\(fileName) 已登记存量物理删除，但源码中已无 context.delete——若已完成软删迁移，请从登记表删除该条目")
        }
        // 反向核对②：登记的函数已不存在 → 清理
        for (fileName, functions) in Self.registeredDeletes {
            guard let source = sources.first(where: { $0.0 == fileName })?.1 else { continue }
            for functionName in functions.keys where functionName != "<none>" {
                if !source.contains("func \(functionName)(") {
                    failures.append("\(fileName) 的 \(functionName)() 已登记，但源码中已无此函数——请同步清理登记表")
                }
            }
        }

        XCTAssertTrue(failures.isEmpty, "物理删除守门检查未通过：\n" + failures.joined(separator: "\n"))
    }

    // MARK: - 源码扫描

    /// 物理删除调用点：(函数名, 行号)。函数名取调用行向上最近的 func 声明（与登记口径一致），
    /// 解析不到（属性初始化器/闭包等）记 nil，登记口径为 "<none>"。
    static func physicalDeleteSites(_ source: String) -> [(functionName: String?, line: Int)] {
        let lines = source.components(separatedBy: .newlines)
        let regex = try! NSRegularExpression(pattern: #"\w*[Cc]ontext\.delete\("#)
        let declRegex = try! NSRegularExpression(pattern: #"func\s+(\w+)"#)
        var sites: [(String?, Int)] = []
        for (index, line) in lines.enumerated() {
            guard regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
            var functionName: String?
            for back in stride(from: index, through: max(0, index - 25), by: -1) {
                let ns = lines[back] as NSString
                if let m = declRegex.firstMatch(in: lines[back], range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 {
                    functionName = ns.substring(with: m.range(at: 1))
                    break
                }
            }
            sites.append((functionName, index + 1))
        }
        return sites
    }

    /// (文件名, 源码) 全量。复用同文件 EdgeSwipe 守门的 appSourceRoot/collectSwiftFiles。
    static func collectSources() throws -> [(String, String)] {
        try FullScreenCoverEdgeSwipeBackAuditTests.collectSwiftFiles(under: FullScreenCoverEdgeSwipeBackAuditTests.appSourceRoot())
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }
}
