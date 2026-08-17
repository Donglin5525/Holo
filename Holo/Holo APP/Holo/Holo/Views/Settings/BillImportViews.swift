//
//  BillImportViews.swift
//  Holo
//
//  账单智能导入的 UI 组件：预览页账单区块 / 导出教程 / 隐私说明
//  方案：docs/plans/2026-08-17-finance-bill-import-ai-plan.md §4 §9
//

import SwiftUI

// MARK: - 预览页账单区块

/// 预览确认页的账单区块：来源徽标 + AI 匹配 + 账户映射 + 疑似重复 + 跳过统计
struct BillImportSection: View {
    @ObservedObject var viewModel: ImportPreviewViewModel
    @State private var showPrivacyNotice = false

    var body: some View {
        if let billInfo = viewModel.scanSummary?.billInfo {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                // 标题行：来源徽标 + 隐私 ⓘ
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                    Text("账单导入 · \(billInfo.sourceLabel)")
                        .font(.holoHeading)
                        .foregroundColor(.holoTextPrimary)
                    Spacer()
                    Button {
                        showPrivacyNotice = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 15))
                            .foregroundColor(.holoTextSecondary)
                    }
                }

                aiSection
                accountMappingSection(billInfo)
                duplicateSection
                skipStatsSection(billInfo)
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .sheet(isPresented: $showPrivacyNotice) {
                BillPrivacyNoticeSheet()
            }
        }
    }

    // MARK: AI 匹配状态与动作

    @ViewBuilder
    private var aiSection: some View {
        switch viewModel.aiPhase {
        case .needsColumnMapping:
            aiActionButton(title: "AI 识别列映射") {
                await viewModel.performAIColumnMapping()
            }
        case .columnMapping:
            aiProgress(text: "正在识别账单格式…")
        case .readyForCategorization:
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                aiActionButton(title: "AI 匹配科目") {
                    await viewModel.performAICategorization()
                }
                Text("按您的科目目录匹配交易对方（如「美团」→餐饮），低置信度会标注")
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
            }
        case .columnMatching(let done, let total):
            aiProgress(text: "正在匹配科目 \(done)/\(total)…")
        case .done:
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.holoSuccess)
                        .font(.system(size: 14))
                    Text(aiSummaryText)
                        .font(.system(size: 13))
                        .foregroundColor(.holoTextPrimary)
                    Spacer()
                    Button("重新匹配") {
                        Task { await viewModel.performAICategorization() }
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.holoPrimary)
                }
                if !viewModel.lowConfidenceNames.isEmpty {
                    Text("低置信度（导入后建议检查）：\(viewModel.lowConfidenceNames.prefix(8).joined(separator: "、"))\(viewModel.lowConfidenceNames.count > 8 ? " 等" : "")")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }
            }
        case .degraded(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.orange)
        case .idle:
            EmptyView()
        }
    }

    private var aiSummaryText: String {
        let total = viewModel.categoryMatches.count
        let confident = total - viewModel.lowConfidenceNames.count
        return "已匹配 \(total) 个交易对方（高置信 \(confident)）"
    }

    /// AI 动作按钮：Plus 门槛在首次 AI 调用前把守（A4），购买后自动续跑
    private func aiActionButton(title: String, action: @escaping () async -> Void) -> some View {
        Button {
            gateAndRun(action)
        } label: {
            HStack {
                Image(systemName: "sparkles")
                Text(title)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(Color.holoPrimary)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func gateAndRun(_ action: @escaping () async -> Void) {
        if HoloEntitlementState.shared.isPlusActive {
            Task { await action() }
        } else {
            HoloPlusActionCoordinator.shared.requirePlus(context: .billImportAI) {
                await action()
            }
        }
    }

    private func aiProgress(text: String) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            ProgressView()
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
        }
    }

    // MARK: 账户映射

    @ViewBuilder
    private func accountMappingSection(_ billInfo: BillScanInfo) -> some View {
        if !billInfo.paymentChannels.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text("账户匹配")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                ForEach(billInfo.paymentChannels, id: \.self) { channel in
                    Picker(channel, selection: Binding(
                        get: { viewModel.accountMapping[channel] ?? "不自动匹配" },
                        set: { newValue in
                            if newValue == "不自动匹配" {
                                viewModel.accountMapping[channel] = nil
                            } else {
                                viewModel.accountMapping[channel] = newValue
                            }
                        }
                    )) {
                        Text("不自动匹配").tag("不自动匹配")
                        ForEach(viewModel.allAccounts.filter { !$0.isArchived }, id: \.id) { account in
                            Text(account.name).tag(account.name)
                        }
                    }
                    .font(.system(size: 13))
                }
            }
        } else if viewModel.defaultAccountName != nil || billInfo.source == .bank {
            Picker("整份账单记入账户", selection: Binding(
                get: { viewModel.defaultAccountName ?? "不自动匹配" },
                set: { viewModel.defaultAccountName = $0 == "不自动匹配" ? nil : $0 }
            )) {
                Text("不自动匹配").tag("不自动匹配")
                ForEach(viewModel.allAccounts.filter { !$0.isArchived }, id: \.id) { account in
                    Text(account.name).tag(account.name)
                }
            }
            .font(.system(size: 13))
        }
    }

    // MARK: 疑似重复

    @ViewBuilder
    private var duplicateSection: some View {
        if let dup = viewModel.duplicateResult, !dup.autoSkipRowIndices.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text("疑似重复：默认跳过 \(dup.autoSkipRowIndices.count) 条")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.orange)
                ForEach(Array(dup.autoSkipMatches.values.prefix(5)), id: \.self) { match in
                    Text("· 与 \(match) 金额相同")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                }
                Text("跳过的条目不会导入；如认为误判，可切换下方「重复处理」为全部导入后手动清理")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary.opacity(0.8))
            }
        }
    }

    // MARK: 跳过统计

    @ViewBuilder
    private func skipStatsSection(_ billInfo: BillScanInfo) -> some View {
        if billInfo.skippedNoFlowCount > 0 || billInfo.skippedStatusCount > 0 {
            Text("已跳过：不计收支 \(billInfo.skippedNoFlowCount) 条（零钱通/理财等）· 非成功状态 \(billInfo.skippedStatusCount) 条（退款/关闭等）。退款不会自动冲减此前导入的原交易。")
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
        }
    }
}

// MARK: - 账单导出教程

/// 「如何导出账单」图文教程（入口：导入导出页）
struct BillExportTutorialSheet: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    tutorialBlock(
                        icon: "message.fill",
                        color: .green,
                        title: "微信账单",
                        steps: [
                            "微信 → 我 → 服务 → 钱包 → 账单",
                            "右上角「常见问题」→ 下载账单",
                            "选「用于个人对账」，时间范围最多一年",
                            "输入邮箱，微信会发送加密压缩包（解压密码在微信里显示）",
                            "在电脑上解压出 CSV 文件后，导入 Holo",
                        ]
                    )
                    tutorialBlock(
                        icon: "creditcard.fill",
                        color: .blue,
                        title: "支付宝账单",
                        steps: [
                            "支付宝 → 我的 → 账单",
                            "右上角「…」→ 开具交易流水证明",
                            "选「用于个人对账」，接收邮箱",
                            "邮箱收到加密压缩包（密码见支付宝提示），电脑解压出 CSV 后导入",
                        ]
                    )
                    tutorialBlock(
                        icon: "building.columns.fill",
                        color: .orange,
                        title: "银行账单",
                        steps: [
                            "各银行 App 或网银导出交易明细（CSV 或 Excel）",
                            "推荐导出 xlsx 或 CSV 格式",
                            "暂不支持 xls 老格式（请另存为 xlsx）与 PDF 账单",
                        ]
                    )
                    BillPrivacyNoticeContent()
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground)
            .navigationTitle("如何导出账单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func tutorialBlock(icon: String, color: Color, title: String, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: HoloSpacing.sm) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 18, height: 18)
                        .background(color.opacity(0.8))
                        .clipShape(Circle())
                    Text(step)
                        .font(.system(size: 13))
                        .foregroundColor(.holoTextPrimary)
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }
}

// MARK: - 隐私说明（预览页 ⓘ / 教程页共用内容）

struct BillPrivacyNoticeSheet: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                BillPrivacyNoticeContent()
                    .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground)
            .navigationTitle("数据与隐私说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("我知道了") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// 隐私口径（方案 §9）：发了什么、不发什么、数据去向
struct BillPrivacyNoticeContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Label("账单智能导入的数据与隐私", systemImage: "lock.shield")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            privacyPoint(
                icon: "paperplane",
                color: .holoPrimary,
                text: "使用 AI 识别（银行账单认列、科目匹配）时，只发送：账单表头、脱敏后的几行样本（金额已替换为假数字、卡号打码）、去重后的交易对方名称、您的账户与科目名称清单。"
            )
            privacyPoint(
                icon: "lock",
                color: .holoSuccess,
                text: "不会发送：完整交易流水、每笔的真实金额与时间组合、交易单号、备注全文。"
            )
            privacyPoint(
                icon: "server.rack",
                color: .holoTextSecondary,
                text: "数据经 Holo 自有服务器转发至 AI 服务处理，与聊天等现有 AI 功能同一数据口径，不新增存储，不用于训练。"
            )
            privacyPoint(
                icon: "wifi.slash",
                color: .orange,
                text: "不使用 AI 也能导入：微信/支付宝账单自动识别、手动字段映射均不联网。"
            )
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private func privacyPoint(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.holoTextPrimary)
        }
    }
}
