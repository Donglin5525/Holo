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

import XCTest
@testable import Holo

final class FullScreenCoverEdgeSwipeBackAuditTests: XCTestCase {

    // MARK: - 登记表（新增全屏页面必须来这里登记）

    /// 豁免清单：明确不适合右滑退出、或手势由内容页承担的全屏页，必须写理由。
    private static let exemptPages: [String: String] = [
        "ReportDetailRoute": "路由容器：手势由其内容页承担（AgentDeepAnalysisDetailSheet / ReportReplayReaderView 均已挂）",
        "ThoughtEditorView": "编辑器：右滑误触会丢内容（HomeView 注释明确的 fullScreenCover 选型原因）",
        "CameraView": "相机取景页：系统相机交互，不适用滑动退出",
        "CSVQuickImportView": "导入流程页：多步操作流程，走明确的上一步/取消",
        "GoalDraftReviewView": "目标草稿确认页：有明确取消按钮的确认流程",
        "LifePlanReviewView": "周计划确认页：有明确取消按钮的确认流程",
        "TopicConfirmationQueueView": "主题确认队列页：批量确认流程",
        "HoloPlusPaywallView": "付费墙营销页：模态性质，有明确关闭按钮",
        "HoloMembershipCenterView": "会员中心页：营销/管理流程页",
        "ChatLogView": "DEBUG 诊断日志页（#if DEBUG 块内，不随正式包分发）",
    ]

    /// 需要右滑返回的全屏页（阅读/详情/检索类）。定义文件必须挂手势。
    /// 注意：只登记「直接出现在 fullScreenCover 内容闭包里」的视图名——
    /// 经由其他视图间接呈现的（如 AgentDeepAnalysisDetailSheet 由 ReportDetailRoute 呈现）
    /// 不在此登记，否则反向核对（登记但无使用）会误报。
    private static let pagesNeedingSwipe: [String] = [
        "ReportFavoritesView",     // 报告收藏夹
        "ReportReplayReaderView",  // 周期回放阅读页
        "FinanceSearchView",       // 财务数据依据/交易检索页（2026-09-01 事故页）
        "AnniversaryDetailView",   // 纪念日详情
        "AttachmentGalleryView",   // 任务附件画廊
        "TaskSearchView",          // 任务搜索页
        "DailyKanbanView",         // 日看板
        "ThoughtDetailView",       // 想法详情（全屏形态；push 形态由 showsDismissButton 条件关闭手势）
        "ThoughtGalleryView",      // 想法图片画廊
        "TopicDetailView",         // 主题详情
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

    /// 闭包体内第一个 `Ident(` 形式的大写开头构造，跳过控制词
    private static func firstViewConstructor(in body: String, excluding skip: Set<String>) -> String? {
        let chars = Array(body)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c.isUppercase && c.isLetter {
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
                if peek < chars.count, chars[peek] == "(", !skip.contains(name) {
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
