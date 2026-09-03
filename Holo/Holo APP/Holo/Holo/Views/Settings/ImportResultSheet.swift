//
//  ImportResultSheet.swift
//  Holo
//
//  导入结果弹窗 — 展示导入统计 + 24 小时撤回入口
//

import SwiftUI
import CoreData

struct ImportResultSheet: View {
    @Environment(\.dismiss) var dismiss

    let result: BatchImportResult

    /// 撤回回调
    let onUndo: (() -> Void)?

    @State private var showUndoConfirm = false
    @State private var undoError: String?
    @State private var showUndoError = false
    /// 按账户分组的余额核对数据（onAppear 取一次；body 内查库是既有铁律禁区）
    @State private var balanceChecks: [BalanceCheck] = []
    /// 「以账单为准」失败提示
    @State private var errorMessage: String?
    @State private var showError = false

    /// 单账户的导入后余额核对
    struct BalanceCheck: Identifiable {
        let account: Account
        /// 账单末行余额（组内最晚一笔的余额列；无余额列的账单为 nil）
        let billBalance: Decimal?
        /// 导入后当前账本余额
        let bookBalance: Decimal
        /// 本批净流水（收入−支出），新建账户设期初用
        let batchNet: Decimal
        /// 该账户是否由本批导入新建
        let isNewAccount: Bool
        /// 连续性校验：余额列不连续的笔数（>0 提示账单可能缺行）
        let discontinuityCount: Int
        /// 首个不连续点的行号（展示用）
        let firstDiscontinuityRow: Int?

        var id: UUID { account.id }
    }

    init(result: BatchImportResult, onUndo: (() -> Void)? = nil) {
        self.result = result
        self.onUndo = onUndo
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 拖动指示条
                Capsule()
                    .fill(Color.holoTextSecondary.opacity(0.3))
                    .frame(width: 36, height: 5)
                    .padding(.top, 12)
                    .padding(.bottom, 16)

                VStack(spacing: HoloSpacing.lg) {
                    // 成功图标
                    VStack(spacing: 8) {
                        Image(systemName: result.isAllSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(result.isAllSuccess ? .holoSuccess : .orange)

                        Text(result.isAllSuccess ? "导入完成" : "导入完成（有提示）")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.holoTextPrimary)
                    }

                    // 统计列表
                    VStack(spacing: 12) {
                        resultRow(
                            icon: "checkmark",
                            color: .holoSuccess,
                            label: "成功导入",
                            value: "\(result.successCount) 条"
                        )

                        if result.skippedDuplicateCount > 0 {
                            resultRow(
                                icon: "arrow.triangle.2.circlepath",
                                color: .holoPrimary,
                                label: "跳过重复",
                                value: "\(result.skippedDuplicateCount) 条"
                            )
                        }

                        if !result.failedItems.isEmpty {
                            resultRow(
                                icon: "xmark",
                                color: .red,
                                label: "导入失败",
                                value: "\(result.failedItems.count) 条"
                            )
                        }

                        if result.newCategoriesCount > 0 {
                            resultRow(
                                icon: "folder.badge.plus",
                                color: .blue,
                                label: "新建分类",
                                value: "\(result.newCategoriesCount) 个"
                            )
                        }

                        if result.newAccountsCount > 0 {
                            resultRow(
                                icon: "creditcard.badge.plus",
                                color: .orange,
                                label: "新建账户",
                                value: "\(result.newAccountsCount) 个"
                            )
                        }

                        // 存盘失败提示
                        if !result.saveSucceeded {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text("部分数据可能未保存成功，建议重新导入")
                                    .font(.system(size: 13))
                                    .foregroundColor(.red)
                            }
                            .padding(12)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                        }
                    }
                    .padding(HoloSpacing.md)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

                    // 余额核对（导入后账本余额 vs 账单末行余额）
                    if !balanceChecks.isEmpty {
                        balanceCheckSection
                    }

                    // 失败明细（最多 5 条）
                    if !result.failedItems.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("失败明细")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.holoTextSecondary)
                            ForEach(Array(result.failedItems.prefix(5).enumerated()), id: \.offset) { _, failure in
                                Text("第 \(failure.index) 行：\(failure.error)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.holoTextSecondary)
                            }
                            if result.failedItems.count > 5 {
                                Text("...还有 \(result.failedItems.count - 5) 条")
                                    .font(.system(size: 11))
                                    .foregroundColor(.holoTextSecondary)
                            }
                        }
                        .padding(HoloSpacing.md)
                        .background(Color.orange.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                    }

                    Spacer()

                    // 撤回入口（仅成功导入且在 24h 内）
                    if onUndo != nil, result.batchId != nil, result.successCount > 0 {
                        Button {
                            showUndoConfirm = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.backward")
                                Text("撤回此次导入")
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
                        }
                    }

                    // 完成按钮
                    Button {
                        dismiss()
                    } label: {
                        Text("完成")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.holoPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.bottom, HoloSpacing.lg)
            }
            .background(Color.holoBackground)
            .navigationBarHidden(true)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .onAppear { loadBalanceChecks() }
        .alert("对账失败", isPresented: $showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .alert("撤回此次导入？", isPresented: $showUndoConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认撤回", role: .destructive) {
                onUndo?()
                dismiss()
            }
        } message: {
            Text("将删除本次导入的 \(result.successCount) 条交易，以及自动创建且未被引用的分类和账户。导入后被你编辑过的交易不会被删除。")
        }
    }

    private func resultRow(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(color)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(.holoTextSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.holoTextPrimary)
        }
    }

    // MARK: - 余额核对

    private var balanceCheckSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("余额核对")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.holoTextSecondary)

            ForEach(balanceChecks) { check in
                balanceCheckRow(check)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    @ViewBuilder
    private func balanceCheckRow(_ check: BalanceCheck) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let billBalance = check.billBalance {
                let difference = check.bookBalance - billBalance
                HStack {
                    Image(systemName: difference == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(difference == 0 ? .holoSuccess : .orange)
                    Text(check.account.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoTextPrimary)
                    Spacer()
                    Text(difference == 0
                         ? "与账单一致"
                         : "差 \(AccountCardFormat.prefixed(abs(difference)))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(difference == 0 ? .holoSuccess : .orange)
                }
                Text("账单余额 \(AccountCardFormat.prefixed(billBalance)) · 账本余额 \(AccountCardFormat.prefixed(check.bookBalance))")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)

                if difference != 0 {
                    Button {
                        alignToBill(check)
                    } label: {
                        Label(check.isNewAccount ? "以账单为准（补设期初余额）" : "以账单为准（生成对账调整）", systemImage: "checkmark.seal")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.holoPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.holoPrimary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                    }
                    .buttonStyle(.plain)
                }

                if let row = check.firstDiscontinuityRow {
                    Text("第 \(row) 行起余额列不连续，账单可能缺行（如同秒交易只导出一笔）")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            } else if check.isNewAccount {
                // 无余额列的账单：只对新建账户提示从 0 起算的问题
                HStack {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundColor(.orange)
                    Text("\(check.account.name) 为本次新建，从 ¥0 起算（账单不含余额列，无法自动核对）")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 「以账单为准」：已有账户生成对账调整流水；本批新建账户直接补设期初（等价于把期初补到账单开始前）。
    /// 调整失败（如系统分类缺失）必须中止——余额未拉平时写锚点是错误锚点。
    private func alignToBill(_ check: BalanceCheck) {
        guard let billBalance = check.billBalance else { return }
        let repo = FinanceRepository.shared
        do {
            if check.isNewAccount {
                // 期初 = 账单末行余额 − 本批净流水 → 当前余额恰好等于账单末行余额，无需生成流水
                repo.updateAccount(check.account, initialBalance: .some(.some(billBalance - check.batchNet)))
            } else {
                _ = try repo.adjustBalance(
                    account: check.account,
                    newBalance: billBalance,
                    note: "导入对账：以账单末行余额为准"
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            return
        }
        // 此刻余额 == 账单末行余额，锚点成立
        repo.markReconciled(check.account, balance: repo.getAccountBalance(check.account))
        HapticManager.success()
        loadBalanceChecks()
    }

    private func loadBalanceChecks() {
        guard let batchId = result.batchId, result.successCount > 0 else {
            balanceChecks = []
            return
        }
        let repo = FinanceRepository.shared
        let request = Transaction.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "importBatchId == %@", batchId as CVarArg),
            NSPredicate(format: "deletedAt == nil")
        ])
        guard let transactions = try? repo.context.fetch(request) else {
            balanceChecks = []
            return
        }

        let grouped = Dictionary(grouping: transactions) { $0.account?.objectID }
        balanceChecks = grouped.compactMap { objectID, txs in
            guard let objectID, let account = try? repo.context.existingObject(with: objectID) as? Account else {
                return nil
            }
            // 同秒多笔按 createdAt 决胜：流式导入按账单行序创建，createdAt 单调，
            // 保证「末行余额」真的是账单最后一行（仅按 date 排序时同秒行序不稳定）
            let sorted = txs.sorted {
                $0.date < $1.date || ($0.date == $1.date && $0.createdAt < $1.createdAt)
            }

            // 账单末行余额：最晚一笔的余额列
            let billBalance = sorted.last?.importBalance?.decimalValue

            var batchNet: Decimal = 0
            for tx in sorted {
                batchNet += tx.transactionType == .income
                    ? tx.amount.decimalValue
                    : -tx.amount.decimalValue
            }

            // 连续性校验：balance[i] − balance[i-1] 应等于该笔净额（收+/支−）
            var discontinuity = 0
            var firstRow: Int?
            var previousBalance: Decimal?
            for (offset, tx) in sorted.enumerated() {
                guard let balance = tx.importBalance?.decimalValue else { continue }
                if let prev = previousBalance {
                    let expected = tx.transactionType == .income
                        ? prev + tx.amount.decimalValue
                        : prev - tx.amount.decimalValue
                    if balance != expected {
                        discontinuity += 1
                        if firstRow == nil { firstRow = offset + 1 }
                    }
                }
                previousBalance = balance
            }

            return BalanceCheck(
                account: account,
                billBalance: billBalance,
                bookBalance: repo.getAccountBalance(account),
                batchNet: batchNet,
                isNewAccount: account.importBatchId == batchId,
                discontinuityCount: discontinuity,
                firstDiscontinuityRow: firstRow
            )
        }
    }
}
