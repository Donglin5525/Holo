//
//  ReceiptBookingResultStore.swift
//  Holo
//
//  图片快捷指令自动记账 · 本地结果/草案/证据存储（2026-09-14 完整方案 §25.1）
//  不新增 CloudKit schema：App Group 容器下的 JSON + JPEG 文件，actor 串行访问。
//
//  隐私铁律（方案 §20.2-9/§25.1）：
//  - booked/rejected/failed 不保存图片与 OCR 全文，只有结果元数据与回执摘要；
//  - 待复核仅在本机暂存受保护压缩图（7 天自动过期），确认/放弃/过期即删 JSON+JPEG；
//  - 银行卡只存账户别名/尾号（账户解析层本来就只产出 name）。
//

import Foundation

actor ReceiptBookingResultStore {

    static let shared = ReceiptBookingResultStore()

    // MARK: - 存储模型

    enum StoredOutcomeKind: String, Codable, Sendable {
        case booked
        case duplicate
        case needsReview
        case rejected
        case failed
        case undone
    }

    struct StoredResult: Codable, Sendable, Identifiable {
        let id: UUID
        let createdAt: Date
        var kind: StoredOutcomeKind
        /// 稳定原因码（review.*/reject.*/failure.*）
        var reasonCode: String?
        /// 展示摘要（已记 ¥xx · 商户 · 分类 · 账户）
        var summaryText: String?
        var transactionID: UUID?
        /// 多笔整批确认时的其余笔（2026-09-19；撤销整批撤）
        var additionalTransactionIDs: [UUID]?
        var draftID: UUID?
        var undoToken: UUID?
        var usedDefaultAccount: Bool
        var undoneAt: Date?
    }

    /// 逐笔草案条目（2026-09-19 一图多笔）：一张图一个 StoredDraft，内含全部待确认笔
    struct StoredDraftItem: Codable, Sendable, Equatable {
        let itemKey: String
        let amountText: String
        let typeIsIncome: Bool
        let dateText: String?
        let note: String?
        let paymentChannel: String?
        let amountOriginalText: String?
        let categoryCandidate: String?
        let normalizedCategoryCandidate: String?
        let semanticCategoryHint: String?
        /// 逐笔警示原因码（金额/方向低置信），确认页该笔卡片提示
        let reviewNotes: [String]?
    }

    /// 待复核草案：只存必要纯值字段（方案 §25.1）
    /// 顶层单笔字段保留：旧格式文件（单笔）兼容读取 + 新文件冗余写第一笔作列表摘要。
    /// 多笔真相在 items；读侧一律走 effectiveItems。
    struct StoredDraft: Codable, Sendable, Identifiable {
        let id: UUID
        let createdAt: Date
        let reasons: [String]
        let amountText: String
        let typeIsIncome: Bool
        let merchant: String?
        let dateText: String?
        let note: String?
        let paymentChannel: String?
        let amountOriginalText: String?
        let paymentStatusOriginalText: String?
        /// 分类语义候选（复核确认时重走完整分类链）
        let categoryCandidate: String?
        let normalizedCategoryCandidate: String?
        let semanticCategoryHint: String?
        let imageType: String
        /// 同图来源键（复核确认时再走一次幂等检查）
        let sourceKey: String
        let itemKey: String
        let accountChoiceRaw: String
        let projectChoiceRaw: String
        let modeRaw: String
        /// 逐笔条目（新格式；旧格式文件无此键 decode 为 nil）
        let items: [StoredDraftItem]?

        /// 全部待确认笔：新格式读 items；旧格式从顶层单笔字段合成一条
        var effectiveItems: [StoredDraftItem] {
            if let items, !items.isEmpty { return items }
        return [StoredDraftItem(
            itemKey: itemKey,
            amountText: amountText,
            typeIsIncome: typeIsIncome,
            dateText: dateText,
            note: note,
            paymentChannel: paymentChannel,
            amountOriginalText: amountOriginalText,
            categoryCandidate: categoryCandidate,
            normalizedCategoryCandidate: normalizedCategoryCandidate,
            semanticCategoryHint: semanticCategoryHint,
            reviewNotes: nil
        )]
        }

        /// 列表行摘要：多笔显示「N 笔 · 合计」（同向时）
        var itemCount: Int { effectiveItems.count }
    }

    // MARK: - 目录

    private let fileManager = FileManager.default
    private lazy var rootDirectory: URL? = {
        // App Group 容器（方案 §25.1）；无签名环境拿不到时回落本机支持目录（测试/模拟器）
        let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.tangyuxuan.holo-app")
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let base else { return nil }
        let root = base.appendingPathComponent("ReceiptBooking", isDirectory: true)
        try? fileManager.createDirectory(at: root.appendingPathComponent("drafts", isDirectory: true), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: root.appendingPathComponent("evidence", isDirectory: true), withIntermediateDirectories: true)
        // 文件保护：首次解锁后可用（锁屏期间快捷指令回执仍可写）
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: root.path
        )
        return root
    }()

    private var resultsURL: URL? { rootDirectory?.appendingPathComponent("results.json") }
    private func draftURL(_ id: UUID) -> URL? { rootDirectory?.appendingPathComponent("drafts/\(id.uuidString).json") }
    private func evidenceURL(_ id: UUID) -> URL? { rootDirectory?.appendingPathComponent("evidence/\(id.uuidString).jpg") }

    private init() {}

    // MARK: - 写入

    func append(result: StoredResult) {
        guard let url = resultsURL else { return }
        var results = loadResultsFromDisk()
        results.insert(result, at: 0)
        // 只保留最近 100 条或 30 天，先到者淘汰（方案 §25.1）
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        results = results.filter { $0.createdAt >= cutoff }
        if results.count > 100 { results = Array(results.prefix(100)) }
        writeAtomically(results, to: url)
    }

    /// 保存待复核草案 + 受保护压缩证据图（7 天过期）。
    /// 多笔（2026-09-19）：snapshot.items 全量落 items；顶层单笔字段冗余写第一笔
    /// （兼容旧读方与列表摘要）。itemKey 参数为旧签名遗留，取首笔键，仅作兜底。
    func saveReviewDraft(
        snapshot: ReceiptReviewSnapshot,
        choices: (accountRaw: String, projectRaw: String, modeRaw: String),
        sourceKey: String,
        itemKey: String,
        evidenceJPEG: Data?
    ) {
        guard let url = draftURL(snapshot.draftID) else { return }
        let items = snapshot.items.map { item in
            StoredDraftItem(
                itemKey: item.itemKey,
                amountText: item.amountText,
                typeIsIncome: item.typeIsIncome,
                dateText: item.dateText,
                note: item.note,
                paymentChannel: item.paymentChannel,
                amountOriginalText: item.amountOriginalText,
                categoryCandidate: item.categoryCandidate,
                normalizedCategoryCandidate: item.normalizedCategoryCandidate,
                semanticCategoryHint: item.semanticCategoryHint,
                reviewNotes: item.reviewNotes.map(\.rawValue)
            )
        }
        let primary = items.first
        let legacySnapshotFields = snapshot.primaryItem
        let draft = StoredDraft(
            id: snapshot.draftID,
            createdAt: snapshot.createdAt,
            reasons: snapshot.reasons.map(\.rawValue),
            amountText: primary?.amountText ?? "",
            typeIsIncome: primary?.typeIsIncome ?? false,
            merchant: snapshot.merchant,
            dateText: primary?.dateText,
            note: primary?.note,
            paymentChannel: primary?.paymentChannel,
            amountOriginalText: primary?.amountOriginalText,
            paymentStatusOriginalText: snapshot.paymentStatusOriginalText,
            categoryCandidate: legacySnapshotFields?.categoryCandidate,
            normalizedCategoryCandidate: legacySnapshotFields?.normalizedCategoryCandidate,
            semanticCategoryHint: legacySnapshotFields?.semanticCategoryHint,
            imageType: "",
            sourceKey: sourceKey,
            itemKey: primary?.itemKey ?? itemKey,
            accountChoiceRaw: choices.accountRaw,
            projectChoiceRaw: choices.projectRaw,
            modeRaw: choices.modeRaw,
            items: items
        )
        writeAtomically(draft, to: url)
        if let evidenceJPEG,
           let evidence = evidenceURL(snapshot.draftID) {
            try? evidenceJPEG.write(to: evidence, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// 撤销完成后把结果置为 undone（重复点击幂等返回，方案 §25.4）
    func markUndone(resultID: UUID) {
        guard let url = resultsURL else { return }
        var results = loadResultsFromDisk()
        guard let index = results.firstIndex(where: { $0.id == resultID && $0.kind == .booked }) else {
            return
        }
        results[index].kind = .undone
        results[index].undoneAt = Date()
        writeAtomically(results, to: url)
    }

    // MARK: - 读取

    nonisolated func loadResults() -> [StoredResult] {
        loadResultsFromDisk()
    }

    nonisolated func loadDrafts() -> [StoredDraft] {
        guard let dir = draftDirectoryURL, let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> StoredDraft? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                // 单项损坏隔离：跳过坏文件，不让整个列表打不开（方案 §25.1）
                return try? JSONDecoder().decode(StoredDraft.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    nonisolated private var draftDirectoryURL: URL? {
        // 与 rootDirectory 相同的解析逻辑（nonisolated 环境下不能碰 lazy 实例属性）
        let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.tangyuxuan.holo-app")
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("ReceiptBooking/drafts", isDirectory: true)
    }

    // MARK: - 过期清理（方案 §27.2：HoloApp 启动时调用一次，不常驻轮询）

    /// 待复核证据 7 天过期；确认/放弃/过期后同时删除 JSON 与 JPEG
    nonisolated func purgeExpired(now: Date = Date()) {
        guard let root = rootDirectoryForCleanup else { return }
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)

        for draft in loadDrafts() where draft.createdAt < cutoff {
            try? fileManager.removeItem(at: root.appendingPathComponent("drafts/\(draft.id.uuidString).json"))
            try? fileManager.removeItem(at: root.appendingPathComponent("evidence/\(draft.id.uuidString).jpg"))
            // 草案已过期删除，通知栏里对应的待复核提醒一并撤下，不让通知指向不存在的草案
            ReceiptBookingNotificationService.cancelReviewReminders(for: draft.id)
        }
        // 无主孤儿证据文件一并清理
        if let evidenceDir = try? fileManager.contentsOfDirectory(
            at: root.appendingPathComponent("evidence", isDirectory: true),
            includingPropertiesForKeys: [.creationDateKey]
        ) {
            for file in evidenceDir {
                let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
                if created < cutoff {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
    }

    /// 复核证据图路径（详情页缩略图用；确认/放弃后由调用方删除文件）
    nonisolated static func evidenceImageURL(for draftID: UUID) -> URL? {
        rootDirForCleanup?.appendingPathComponent("evidence/\(draftID.uuidString).jpg")
    }

    nonisolated private static var rootDirForCleanup: URL? {
        let base = fileManagerShared.containerURL(forSecurityApplicationGroupIdentifier: "group.com.tangyuxuan.holo-app")
            ?? fileManagerShared.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("ReceiptBooking", isDirectory: true)
    }

    private static let fileManagerShared = FileManager.default

    nonisolated private var rootDirectoryForCleanup: URL? {
        let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.tangyuxuan.holo-app")
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("ReceiptBooking", isDirectory: true)
    }

    // MARK: - 磁盘工具

    nonisolated private func loadResultsFromDisk() -> [StoredResult] {
        guard let url = resultsURLNonisolated, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([StoredResult].self, from: data)) ?? []
    }

    nonisolated private var resultsURLNonisolated: URL? {
        rootDirectoryForCleanup?.appendingPathComponent("results.json")
    }

    private func writeAtomically<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        // Data.write(.atomic) 同时覆盖「首次创建」与「后续替换」。旧实现只调用
        // replaceItemAt，目标文件尚不存在时首笔结果/草案会直接写入失败。
        try? data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}
