//
//  FinanceEvidenceReviewView.swift
//  Holo
//
//  Agent 财务分析证据核对页：用原始账单明细承接 AI evidence 下钻。
//

import SwiftUI

struct FinanceEvidenceReviewView: View {
    let link: FinanceEvidenceReviewDeepLink
    let onBack: () -> Void
    let onBackToAI: () -> Void
    let onOpenAnalysis: (FinanceAnalysisDeepLink) -> Void

    /// 期次选择：本期 / 对比期
    private enum EvidencePeriod {
        case current, baseline
    }

    /// 内容模式：交易明细 / 科目对比
    private enum EvidenceViewMode {
        case transactions, comparison
    }

    @State private var currentTransactions: [Transaction] = []
    @State private var baselineTransactions: [Transaction] = []
    @State private var categoryInfos: [UUID: CategoryComparisonInfo] = [:]
    @State private var selectedPeriod: EvidencePeriod = .current
    @State private var viewMode: EvidenceViewMode = .transactions
    @State private var editingTransaction: Transaction?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            headerView

            if isLoading {
                loadingView
            } else if let errorMessage {
                errorView(errorMessage)
            } else {
                ScrollView {
                    VStack(spacing: HoloSpacing.lg) {
                        summaryBand

                        if hasBaseline {
                            modeSwitcher
                        }

                        if viewMode == .comparison, hasBaseline {
                            CategoryComparisonListView(
                                items: comparisonItems,
                                currentTotal: totalAmount(currentTransactions),
                                baselineTotal: totalAmount(baselineTransactions)
                            )
                        } else {
                            transactionSection(title: detailTitle, transactions: selectedTransactions)
                        }
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.bottom, 32)
                }
            }
        }
        .background(Color.holoBackground.ignoresSafeArea())
        .task {
            await loadTransactions()
        }
        .sheet(item: $editingTransaction) { transaction in
            AddTransactionSheet(editingTransaction: transaction) { _ in
                NotificationCenter.default.post(name: .financeDataDidChange, object: nil)
                Task { await loadTransactions() }
            }
        }
    }

    private var headerView: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 36, height: 36)
                    .background(Color.holoCardBackground)
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
            }

            Spacer()

            VStack(spacing: 2) {
                Text(link.title)
                    .font(.holoTitle)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(rangeText(start: link.start, end: link.end))
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            Button(action: onBackToAI) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                    Text("回到AI")
                        .font(.holoTinyLabel)
                        .fontWeight(.semibold)
                }
                .foregroundColor(.holoPrimary)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Color.holoPrimary.opacity(0.12))
                .clipShape(Capsule())
            }
            .accessibilityLabel("回到这次分析")
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, 0)
        .padding(.bottom, HoloSpacing.md)
    }

    private var loadingView: some View {
        VStack(spacing: HoloSpacing.md) {
            ProgressView()
            Text("正在核对账单明细…")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .medium))
                .foregroundColor(.holoError)
            Text(message)
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await loadTransactions() }
            }
            .font(.holoBody)
            .foregroundColor(.white)
            .padding(.horizontal, HoloSpacing.xl)
            .padding(.vertical, HoloSpacing.sm)
            .background(Color.holoPrimary)
            .clipShape(Capsule())
        }
        .padding(HoloSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summaryBand: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(keywordTitle)
                        .font(.holoBody)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoTextPrimary)
                    Text(hasBaseline ? "点合计切换期次，点明细看原账单" : "点明细看原账单")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                }
                Spacer()

                Button {
                    openAnalysisForSelectedPeriod()
                } label: {
                    HStack(spacing: 2) {
                        Text("统计分析")
                            .font(.holoTinyLabel)
                            .fontWeight(.semibold)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.holoPrimary.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("进入统计分析页")
            }

            HStack(spacing: HoloSpacing.md) {
                totalCard(
                    title: "本期合计",
                    total: totalAmount(currentTransactions),
                    count: currentTransactions.count,
                    isSelected: selectedPeriod == .current
                ) {
                    selectedPeriod = .current
                }

                if hasBaseline {
                    totalCard(
                        title: "对比期合计",
                        total: totalAmount(baselineTransactions),
                        count: baselineTransactions.count,
                        isSelected: selectedPeriod == .baseline
                    ) {
                        selectedPeriod = .baseline
                    }
                }
            }
        }
        .padding(HoloSpacing.lg)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
        .shadow(color: HoloShadow.card, radius: 8, x: 0, y: 2)
    }

    private func totalCard(
        title: String,
        total: Decimal,
        count: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.holoTinyLabel)
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)
                Text(currency(total))
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("\(count) 笔")
                    .font(.holoTinyLabel)
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HoloSpacing.md)
            .background(isSelected ? Color.holoPrimary.opacity(0.08) : Color.holoBackground)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.holoPrimary : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// 明细 / 科目对比 分段切换（样式复用 CategoryTabView.typeSwitcher）
    private var modeSwitcher: some View {
        HStack(spacing: 0) {
            modeButton(title: "明细", isSelected: viewMode == .transactions) {
                viewMode = .transactions
            }
            modeButton(title: "科目对比", isSelected: viewMode == .comparison) {
                viewMode = .comparison
            }
        }
        .padding(4)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoDivider, lineWidth: 1)
        )
    }

    private func modeButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.holoCaption)
                .foregroundColor(isSelected ? .white : .holoTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HoloSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .fill(isSelected ? Color.holoPrimary : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func transactionSection(title: String, transactions: [Transaction]) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text(title)
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)

            if transactions.isEmpty {
                emptySection
            } else {
                VStack(spacing: 0) {
                    ForEach(transactions) { transaction in
                        VStack(spacing: 0) {
                            TransactionRowView(transaction: transaction) {
                                editingTransaction = transaction
                            }
                            if transaction.id != transactions.last?.id {
                                Divider().background(Color.holoDivider)
                            }
                        }
                    }
                }
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.lg)
                .shadow(color: HoloShadow.card, radius: 8, x: 0, y: 2)
            }
        }
    }

    private var emptySection: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.holoTextSecondary)
            Text("这个时间段没有匹配明细")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.xl)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
    }

    private var keywordTitle: String {
        guard let keyword = normalizedKeyword else { return "全部支出依据" }
        return "\(keyword)相关依据"
    }

    private var normalizedKeyword: String? {
        let keyword = link.keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return keyword.isEmpty ? nil : keyword
    }

    /// 是否带对比期
    private var hasBaseline: Bool {
        link.baselineStart != nil && link.baselineEnd != nil
    }

    /// 当前选中期次的交易列表
    private var selectedTransactions: [Transaction] {
        selectedPeriod == .current ? currentTransactions : baselineTransactions
    }

    /// 明细列表标题（带日期区间，区分两期）
    private var detailTitle: String {
        if selectedPeriod == .current {
            return "本期明细（\(rangeText(start: link.start, end: link.end))）"
        }
        if let baselineStart = link.baselineStart, let baselineEnd = link.baselineEnd {
            return "对比期明细（\(rangeText(start: baselineStart, end: baselineEnd))）"
        }
        return "本期明细（\(rangeText(start: link.start, end: link.end))）"
    }

    /// 科目对比聚合结果（本地聚合，尊重关键词过滤，零新增查询）
    private var comparisonItems: [CategoryComparisonItem] {
        CategoryComparisonBuilder.build(
            current: currentTransactions.map(comparisonInput),
            baseline: baselineTransactions.map(comparisonInput),
            categories: categoryInfos
        )
    }

    private func comparisonInput(_ transaction: Transaction) -> CategoryComparisonInput {
        CategoryComparisonInput(
            categoryID: transaction.category?.id,
            amount: transaction.amount.decimalValue
        )
    }

    /// 以当前选中期次的时间段进入统计分析页
    private func openAnalysisForSelectedPeriod() {
        let range: (label: String, start: Date, end: Date)
        if selectedPeriod == .baseline, let baselineStart = link.baselineStart, let baselineEnd = link.baselineEnd {
            range = ("对比期合计", baselineStart, baselineEnd)
        } else {
            range = ("本期合计", link.start, link.end)
        }
        onOpenAnalysis(FinanceAnalysisDeepLink(
            label: range.label,
            start: range.start,
            end: range.end,
            sourceEvidenceID: link.sourceEvidenceID
        ))
    }

    @MainActor
    private func loadTransactions() async {
        isLoading = true
        errorMessage = nil
        do {
            FinanceRepository.shared.setup()
            let current = try await FinanceRepository.shared.getTransactions(from: link.start, to: link.end)
            currentTransactions = filteredTransactions(current)

            if let baselineStart = link.baselineStart, let baselineEnd = link.baselineEnd {
                let baseline = try await FinanceRepository.shared.getTransactions(from: baselineStart, to: baselineEnd)
                baselineTransactions = filteredTransactions(baseline)
            } else {
                baselineTransactions = []
            }

            // 科目对比所需的分类信息（id → 名称/层级/样式）
            let categories = try await FinanceRepository.shared.getCategories(by: .expense)
            categoryInfos = Dictionary(categories.map { category in
                (category.id, CategoryComparisonInfo(
                    id: category.id,
                    name: category.name,
                    icon: category.icon,
                    color: category.color,
                    parentID: category.parentId
                ))
            }, uniquingKeysWith: { first, _ in first })
        } catch {
            errorMessage = "账单明细加载失败，请稍后再试"
        }
        isLoading = false
    }

    private func filteredTransactions(_ transactions: [Transaction]) -> [Transaction] {
        transactions
            .filter { transaction in
                guard transaction.transactionType == .expense else { return false }
                guard let keyword = normalizedKeyword else { return true }
                return searchableText(for: transaction).localizedCaseInsensitiveContains(keyword)
            }
            .sorted { $0.date > $1.date }
    }

    private func searchableText(for transaction: Transaction) -> String {
        [
            transaction.note,
            transaction.remark,
            transaction.category?.name,
            transaction.tags?.joined(separator: " ")
        ]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private func totalAmount(_ transactions: [Transaction]) -> Decimal {
        transactions.reduce(Decimal(0)) { $0 + $1.amount.decimalValue }
    }

    private func currency(_ amount: Decimal) -> String {
        NumberFormatter.currency.string(from: NSDecimalNumber(decimal: amount)) ?? "¥0"
    }

    private func rangeText(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy.MM.dd"
        return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
    }
}
