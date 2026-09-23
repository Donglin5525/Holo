//
//  RecognizeAndBookReceiptIntent.swift
//  Holo
//
//  图片快捷指令自动记账 · 系统动作（2026-09-14 完整方案 §10/§22.1）
//  放在主 App target：后台运行不拉起 Holo，不新建独立 App Intents extension
//  （§22.3：避免第二个进程直接写共享库）。
//
//  perform() 只做六件事（方案 §22.1）：
//  1. 校验功能开关/授权/基础账本初始化
//  2. 从 IntentFile 读取图片（安全范围，不请求照片全库权限）
//  3. AppEntity ID 解析成纯值选择
//  4. 调 ReceiptBookingCoordinator.book(_:)
//  5. 结果写入本地结果存储（复核项可恢复）
//  6. 返回一句可读结果（业务规则全部在协调器与门禁里）
//

import AppIntents
import Foundation
import UIKit
import UniformTypeIdentifiers

/// 处理方式参数（AppEnum 一致性挂在这里；领域定义在 ReceiptBookingModels）
extension ReceiptBookingMode: AppEnum {
    nonisolated static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "处理方式")
    }
    nonisolated static var caseDisplayRepresentations: [ReceiptBookingMode: DisplayRepresentation] {
        [
            .autoWhenSafe: DisplayRepresentation(title: "安全时自动记账", subtitle: "金额状态可靠时直接入账"),
            .alwaysReview: DisplayRepresentation(title: "始终先确认", subtitle: "全部生成待复核项"),
        ]
    }
}

struct RecognizeAndBookReceiptIntent: AppIntent {

    static let title: LocalizedStringResource = "识别图片并记账"
    static let description = IntentDescription(
        "把支付截图或小票照片交给 Holo 识别：金额、商户、日期、支付方式，安全时自动记账。"
    )
    // §22.3：后台执行，不拉起 Holo（真机实际存活时长由 M0 探针验证）
    static let openAppWhenRun = false

    // inputConnectionBehavior（2026-09-15 东林真机反馈）：声明自动连接上一个动作的输出，
    // 否则快捷指令编辑器不会把「截屏/拍照」结果接进图片参数，运行时会弹文件选择器要图
    @Parameter(
        title: "图片",
        description: "支付成功截图或小票照片（只取第一张）",
        requestValueDialog: "选择要记账的图片",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var image: IntentFile

    // 实体参数用可选：未设置 = 语义默认（自动识别 / 不挂项目），默认展示由 defaultQuery.defaultResult() 提供
    @Parameter(title: "账户", description: "自动识别，或固定某个账户")
    var account: HoloAccountChoiceEntity?

    @Parameter(title: "项目", description: "不挂项目，按图匹配，或固定某个项目")
    var project: HoloProjectChoiceEntity?

    @Parameter(title: "处理方式", description: "安全时自动记账，或始终先确认", default: ReceiptBookingMode.autoWhenSafe)
    var mode: ReceiptBookingMode

    @Parameter(title: "附言", description: "可选：补充说明，如「这是昨天的，挂东京旅行」", default: nil)
    var caption: String?

    static var parameterSummary: some ParameterSummary {
        Summary("识别 \(\.$image)，记到账户 \(\.$account)，项目 \(\.$project)，方式 \(\.$mode)")
    }

    @MainActor
    // 默认模式在后台完成；用户明确选“始终先确认”时，才打开 Holo 的复核页。
    func perform() async throws -> IntentResultContainer<String, OpenReviewIntent, Never, Never> {
        // 1. 运行资格
        if let notReady = ReceiptBookingFeaturePolicy.readinessReason() {
            // 修复（模拟器崩溃二分 2026-09-15）：IntentDialog(stringLiteral:) 传运行时字符串
            // 会在系统 snippet 渲染时触发断言崩溃——dialog 一律用编译期字面量
            return Self.backgroundResult(Self.text(for: .failed(ReceiptBookingFailure(
                reason: notReady, retryable: false, userMessage: ""
            ))))
        }

        // 2. 图片（IntentFile 系统显式传入；不读取照片库）
        let imageData = image.data

        // 3. AppEntity → 纯值选择（§22.1 第 3 步）
        let accountChoice: ReceiptAccountChoice
        if account == nil || account?.id == "account:auto" {
            accountChoice = .automatic
        } else if let uuid = UUID(uuidString: String((account?.id ?? "").dropFirst("account:".count))) {
            accountChoice = .fixed(uuid)
        } else {
            accountChoice = .automatic
        }
        let projectChoice: ReceiptProjectChoice
        switch project?.id {
        case "project:none":
            projectChoice = .noProject
        case "project:explicit":
            projectChoice = .explicitTextMatch
        default:
            if let uuid = UUID(uuidString: String((project?.id ?? "").dropFirst("project:".count))) {
                projectChoice = .fixed(uuid)
            } else {
                projectChoice = .noProject
            }
        }

        let trimmedCaption = (caption ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let request = ReceiptBookingRequest(
            rawImageData: imageData,
            source: .shortcutScreenshot,
            mode: mode,
            caption: trimmedCaption.isEmpty ? nil : String(trimmedCaption.prefix(200)),
            capturedAt: Date(),
            invocationID: UUID(),
            accountChoice: accountChoice,
            projectChoice: projectChoice
        )

        // 4-5. 协调器编排（含结果与复核草案落盘）+ 非阻塞通知（授权时）
        let outcome = await ReceiptBookingCoordinator.shared.book(request)

        if case .needsReview(let snapshot) = outcome {
            // 前台直弹（2026-09-22 确认页必达）：本 Intent 跑在主 App 进程，App 恰在
            // 前台（截完图直接回到 Holo 等）时当场弹出复核页。后台拉起通道
            // （opensIntent）受系统自动化运行策略限制不可依赖，确认页到达需多通道兜底。
            let appInForeground = UIApplication.shared.applicationState == .active
            if appInForeground {
                ReceiptBookingForegroundPresenter.present(draftID: snapshot.draftID)
            }
            // 「始终先确认」会打开 Holo 复核页：提醒押后 5 分钟，当场确认即撤回（2026-09-16）；
            // 前台直弹同理押后。其余模式不打开 App，通知是唯一反馈渠道，仍立即投递。
            await ReceiptBookingNotificationService.shared.notifyIfNeeded(
                for: outcome,
                deferredReviewReminder: mode == .alwaysReview || appInForeground
            )
            if mode == .alwaysReview {
                return .result(
                    value: Self.text(for: .needsReview(snapshot)),
                    opensIntent: OpenReviewIntent(draftIDRaw: snapshot.draftID.uuidString)
                )
            }
            return Self.backgroundResult(Self.text(for: .needsReview(snapshot)))
        }
        await ReceiptBookingNotificationService.shared.notifyIfNeeded(for: outcome)

        // 6. 结果文字（结构化状态在本地存储，快捷指令不解析文字）
        return Self.backgroundResult(Self.text(for: outcome))
    }

    /// iOS 17 的结果容器以可选 opensIntent 表达条件打开 App。先构造同一返回类型，
    /// 再清空打开动作，避免自动入账成功时也把 Holo 拉到前台。
    private static func backgroundResult(
        _ value: String
    ) -> IntentResultContainer<String, OpenReviewIntent, Never, Never> {
        var result: IntentResultContainer<String, OpenReviewIntent, Never, Never> = .result(
            value: value,
            opensIntent: OpenReviewIntent(draftIDRaw: nil)
        )
        result.opensIntent = nil
        return result
    }

    // MARK: - 首版结果文字规范（§22.1；只服务人类反馈，不做机器判读依据）

    static func text(for outcome: ReceiptBookingOutcome) -> String {
        switch outcome {
        case .booked(let receipt):
            return receipt.summaryText
        case .duplicate(let receipt):
            return String(localized: "这张图已经记过：\(receipt.summaryText)")
        case .needsReview(let snapshot):
            // 2026-09-19 一图多笔：多笔给逐单清点文案；Intent dialog 对长度敏感，
            // 只说笔数+合计，不逐笔展开
            if snapshot.items.count > 1 {
                if let total = snapshot.uniformTotalAmountText {
                    return String(localized: "识别到 \(snapshot.items.count) 笔支出，共 ¥\(total)，未自动入账。打开 Holo 逐笔确认。")
                }
                return String(localized: "识别到 \(snapshot.items.count) 笔收支，未自动入账。打开 Holo 逐笔确认。")
            }
            if let reason = snapshot.reasons.first {
                return reviewText(for: reason)
            }
            return String(localized: "这笔需要确认，未自动入账。打开 Holo 复核。")
        case .rejected(let reason):
            return rejectText(for: reason)
        case .failed(let failure):
            return failureText(for: failure)
        }
    }

    private static func reviewText(for reason: ReceiptBookingReason) -> String {
        switch reason {
        case .reviewMultipleTransactions:
            return String(localized: "图里有多笔交易，未入账。打开 Holo 逐笔确认。")
        case .reviewAmountLowConfidence, .reviewAmountConflict:
            return String(localized: "金额不确定，未入账。打开 Holo 确认。")
        case .reviewDirectionLowConfidence:
            return String(localized: "收支方向不确定，未入账。打开 Holo 确认。")
        case .reviewPaymentStatusLowConfidence:
            return String(localized: "支付状态不确定，未入账。打开 Holo 确认。")
        case .reviewDateMissingForHistoricalImage:
            return String(localized: "图片里没有日期，未入账。打开 Holo 确认。")
        case .reviewDateOutsideProjectRange:
            return String(localized: "日期不在项目周期内，未入账。打开 Holo 确认。")
        case .reviewPossibleDuplicate:
            return String(localized: "这笔可能已经记过，未自动入账。打开 Holo 确认。")
        case .reviewAccountChoiceUnavailable:
            return String(localized: "快捷指令里的账户已失效，未入账。请修改这条快捷指令。")
        case .reviewProjectChoiceUnavailable:
            return String(localized: "快捷指令里的项目已结束，未入账。请修改这条快捷指令。")
        case .reviewProjectAmbiguous:
            return String(localized: "匹配到多个项目，未入账。打开 Holo 确认。")
        case .reviewProjectNotSupportedForIncome:
            return String(localized: "收入不能挂项目，未入账。打开 Holo 确认。")
        case .reviewContractGuarded:
            return String(localized: "识别结果有异常，未入账。打开 Holo 确认。")
        case .reviewLegacyContract:
            return String(localized: "识别服务需要更新，未自动入账。打开 Holo 手动确认这笔。")
        default:
            return String(localized: "这笔需要确认，未自动入账。打开 Holo 复核。")
        }
    }

    private static func rejectText(for reason: ReceiptBookingReason) -> String {
        // 文案本体在 ReceiptBookingReason.rejectionUserText（2026-09-23 与结果通知共用）
        reason.rejectionUserText
    }

    private static func failureText(for failure: ReceiptBookingFailure) -> String {
        switch failure.reason {
        case .failureNetwork:
            return String(localized: "网络不可用，未入账。截图仍在照片里，可稍后重试。")
        case .failureRateLimited:
            return String(localized: "今天的识别次数用完了，明天再试。")
        case .failureServer:
            return String(localized: "服务暂时不可用，未入账。截图仍在照片里，可稍后重试。")
        case .failureCancelled:
            return String(localized: "已取消，未入账。")
        case .failureNotConfigured:
            return String(localized: "请先打开 Holo 完成设置。")
        default:
            return String(localized: "没有入账，请稍后重试。")
        }
    }
}
