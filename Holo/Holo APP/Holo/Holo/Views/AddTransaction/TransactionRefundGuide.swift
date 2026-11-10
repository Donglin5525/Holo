//
//  TransactionRefundGuide.swift
//  Holo
//
//  「记一笔」退款引导：手动记收入带退款语义时引导关联原支出，落成退款笔冲减其分类支出。
//  原型 docs/design/2026-11-10-记一笔退款引导-原型.html（东林 11-10 拍板，文案零描述行）。
//  结构约定：引导区与选择器是独立 View struct 自带弹层，不往 AddTransactionSheet
//  主视图树与修饰链上叠体量（View Weight Guard / 真机栈溢出红线）。
//

import SwiftUI
import CoreData

// MARK: - 关联快照

/// 已关联原支出的值快照。渲染与状态比较只用这份值，保存时再按 id 取回托管对象——
/// 弹层开着期间原支出可能被其他设备同步删除，直接持有托管对象渲染会读到失效对象
struct RefundLink: Equatable {
    let originalId: UUID
    /// 展示名：原支出备注，无备注用分类名
    let title: String
    /// 原支出金额文案（如 "363.30"）
    let amountText: String
    /// 原支出分类路径（如 "服饰美妆/服装"；无分类为 "未分类"）
    let categoryPath: String
    /// 原支出日期文案（今年 "11月7日"，跨年带年份）
    let dateText: String
    /// 退回账户 id（nil=原支出无账户或账户已归档，保持用户当前选择）
    let accountId: UUID?
    /// 关联时的可退余额（原额 − 名下已退累计）
    let refundable: Decimal
}

// MARK: - 引导区

/// 名称输入框下方的退款引导区：未关联时显示提示条，已关联显示确认卡
struct RefundGuideSection: View {
    let link: RefundLink?
    let showsHint: Bool
    /// 当前输入金额（0=未填；>可退余额时确认卡上红字提示）
    let amount: Decimal
    let nameHint: String
    let onPick: (RefundLink) -> Void
    let onUnlink: () -> Void

    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 0) {
            if let link {
                linkedCard(link)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if showsHint {
                hintBar
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .animation(HoloAnimation.standard, value: link)
        .animation(HoloAnimation.standard, value: showsHint)
        .sheet(isPresented: $showPicker) {
            RefundOriginalPickerSheet(
                amount: amount,
                nameHint: nameHint,
                onSelect: onPick,
                onDecline: onUnlink
            )
        }
    }

    /// 提示条：一句话 + 一个动作，忽略它照常保存普通收入
    private var hintBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.holoSuccessDark)

            Text(String(localized: "看起来是退款，关联原支出可自动冲减"))
                .font(.holoCaption)
                .foregroundColor(.holoToolText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                showPicker = true
            } label: {
                Text(String(localized: "选择原支出"))
                    .font(.holoCaption.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Color.holoSuccessDark)
                    .clipShape(Capsule())
                    // 视觉胶囊 30pt，热区扩到 44（视觉不变）
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .padding(.vertical, -7)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("refundGuide.pickButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.holoSuccessDark.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoSuccessDark.opacity(0.30), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    /// 关联确认卡：告知将关联哪笔（分类沿用原支出写进信息行），更换 / 取消关联
    private func linkedCard(_ link: RefundLink) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoSuccessDark)

                Text(String(localized: "将关联原支出"))
                    .font(.holoCaption.weight(.semibold))
                    .foregroundColor(.holoSuccessDark)

                Spacer(minLength: 8)

                cardActionButton(String(localized: "更换")) { showPicker = true }
                cardActionButton(String(localized: "取消关联")) { onUnlink() }
            }

            Text(verbatim: "\(link.title) · \(link.categoryPath) · ¥\(link.amountText) · \(link.dateText)")
                .font(.holoCaption)
                .foregroundColor(.holoToolText)
                .lineLimit(1)
                .truncationMode(.middle)

            if amount > link.refundable {
                Text(String(localized: "超过可退余额 ¥\(link.refundable.formattedAsCurrency())"))
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoToolError)
            } else if link.refundable < decimal(of: link.amountText) {
                // 部分退过才提示余额；全额未动过不占行
                Text(String(localized: "可退 ¥\(link.refundable.formattedAsCurrency())"))
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoToolTextSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.holoSuccessDark.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoSuccessDark.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    /// 文字操作钮：布局高度跟随文字，热区上下外扩（外扩命中区范式同键盘托盘 chip）
    private func cardActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.holoTinyLabel)
                .foregroundColor(.holoToolTextSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .padding(.vertical, -8)
        }
        .buttonStyle(.plain)
    }

    private func decimal(of amountText: String) -> Decimal {
        Decimal(string: amountText) ?? 0
    }
}

// MARK: - 原支出选择弹层

/// 选择这笔退款对应的原支出：推荐候选（近 90 天，金额吻合优先）+ 全量搜索 +
/// 「没找到，直接按普通收入记录」降级。候选一律输出值快照，托管对象不流出本弹层
struct RefundOriginalPickerSheet: View {
    /// 当前输入金额（0=未填：候选不按金额筛，行上不标金额吻合）
    let amount: Decimal
    /// 名称输入（剔除退款词后作候选匹配关键词）
    let nameHint: String
    let onSelect: (RefundLink) -> Void
    let onDecline: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFocused: Bool
    @State private var searchText = ""
    @State private var detent: PresentationDetent = .medium
    @State private var recommended: [RefundCandidate] = []
    @State private var searchResults: [RefundCandidate] = []
    /// 各原交易的累计已退金额（推荐/搜索共用，避免两次聚合查询）
    @State private var refundedTotals: [UUID: Decimal] = [:]
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(visibleCandidates) { candidate in
                            candidateRow(candidate)
                        }

                        if !hasLoaded {
                            ProgressView()
                                .padding(.top, 32)
                        } else if visibleCandidates.isEmpty {
                            emptyHint
                                .padding(.top, 32)
                        }

                        declineButton
                            .padding(.top, 12)
                            .padding(.bottom, 24)
                    }
                    .padding(.horizontal, 16)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .background(Color.holoToolBackground)
            .navigationTitle(String(localized: "这笔退的是哪笔消费？"))
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                    .accessibilityLabel(Text("关闭"))
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .task { await loadRecommended() }
        .task(id: searchText) { await runSearch() }
        .onChange(of: isSearchFocused) { _, focused in
            // 搜索需要键盘+更多行数：聚焦升到大档
            if focused { detent = .large }
        }
    }

    // MARK: 数据

    /// 搜索词为空显示推荐，非空显示搜索结果（可选的在前，不可退的沉底置灰）
    private var visibleCandidates: [RefundCandidate] {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty ? recommended : searchResults
    }

    private func loadRecommended() async {
        refundedTotals = (try? await FinanceRepository.shared.refundedTotalsByOriginal()) ?? [:]
        let keyword = RefundSemantics.strippingKeywords(from: nameHint)
        let found = (try? await FinanceRepository.shared.findRefundCandidates(
            amount: amount,
            keyword: keyword.isEmpty ? nil : keyword,
            limit: 12
        )) ?? []
        recommended = found
            .map { RefundCandidate(transaction: $0, refunded: refundedTotals[$0.id] ?? 0) }
            .filter { $0.link.refundable >= max(amount, 1) }
        hasLoaded = true
    }

    private func runSearch() async {
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else {
            searchResults = []
            return
        }
        // 输入防抖：停顿后再查，逐字不清库
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        if refundedTotals.isEmpty {
            refundedTotals = (try? await FinanceRepository.shared.refundedTotalsByOriginal()) ?? [:]
        }
        let found = (try? await FinanceRepository.shared.searchRefundableExpenses(keyword: keyword)) ?? []
        searchResults = found
            .map { RefundCandidate(transaction: $0, refunded: refundedTotals[$0.id] ?? 0) }
            // 可选的在前，已退完/余额不足的沉底；同档保持仓库层的时间倒序
            .sorted { $0.isSelectable(for: amount) && !$1.isSelectable(for: amount) }
    }

    // MARK: 子视图

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(.holoToolTextSecondary)

            TextField(String(localized: "搜商家 / 备注"), text: $searchText)
                .font(.holoBody)
                .foregroundColor(.holoToolText)
                .focused($isSearchFocused)
                .submitLabel(.search)
                .accessibilityIdentifier("refundPicker.searchField")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.holoToolTextSecondary.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color.holoToolSurface)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private func candidateRow(_ candidate: RefundCandidate) -> some View {
        let selectable = candidate.isSelectable(for: amount)
        let amountMatches = amount > 0 && candidate.link.amountText == amount.formattedAsCurrency()

        return Button {
            onSelect(candidate.link)
            dismiss()
        } label: {
            HStack(spacing: 11) {
                categoryIcon(candidate)
                    .frame(width: 36, height: 36)
                    .background(Color.holoToolSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(candidate.link.title)
                            .font(.holoBody.weight(.semibold))
                            .foregroundColor(selectable ? .holoToolText : .holoToolTextSecondary)
                            .lineLimit(1)

                        if amountMatches {
                            Text(String(localized: "金额吻合"))
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoSuccessDark)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.holoSuccessDark.opacity(0.12))
                                .clipShape(Capsule())
                                .fixedSize()
                        }
                    }

                    Text(verbatim: "\(candidate.link.dateText) · \(candidate.link.categoryPath)\(candidate.accountSuffix)")
                        .font(.holoCaption)
                        .foregroundColor(.holoToolTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("¥\(candidate.link.amountText)")
                        .font(.holoBody.weight(.semibold))
                        .foregroundColor(selectable ? .holoToolText : .holoToolTextSecondary)
                        .lineLimit(1)
                        .fixedSize()

                    if candidate.partiallyRefunded {
                        Text(String(localized: "可退 ¥\(candidate.link.refundable.formattedAsCurrency())"))
                            .font(.holoTinyLabel)
                            .foregroundColor(selectable ? .holoToolTextSecondary : .holoToolError)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color.holoCardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(amountMatches ? Color.holoSuccessDark.opacity(0.45) : Color.clear, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .opacity(selectable ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .accessibilityIdentifier("refundPicker.row")
    }

    /// 分类图标（值快照渲染；icon_ 旧命名回退同 transactionCategoryIcon）
    private func categoryIcon(_ candidate: RefundCandidate) -> some View {
        Group {
            if candidate.iconName.hasPrefix("icon_") {
                Image(systemName: "tag.fill")
                    .font(.system(size: 36 * 0.6, weight: .medium))
                    .foregroundColor(candidate.iconColor)
            } else {
                categoryIconGlyph(candidate.iconName, size: 36 * 0.6, color: candidate.iconColor)
            }
        }
    }

    private var emptyHint: some View {
        Text(searchText.trimmingCharacters(in: .whitespaces).isEmpty
             ? String(localized: "近 90 天没有可关联的支出")
             : String(localized: "没有找到相关支出"))
            .font(.holoCaption)
            .foregroundColor(.holoToolTextSecondary)
    }

    /// 降级出口：一键按普通收入记录（= 现状行为），任何找不到的场景都一步走完
    private var declineButton: some View {
        Button {
            onDecline()
            dismiss()
        } label: {
            Text(String(localized: "没找到，直接按普通收入记录"))
                .font(.holoCaption)
                .foregroundColor(.holoToolTextSecondary)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("refundPicker.declineButton")
    }
}

// MARK: - 候选值快照

/// 弹层内的候选行值快照：构造时一次性从托管对象拷出全部展示值与关联快照，
/// 之后渲染/点击都不再触碰托管对象（防弹层打开期间对象被同步删除后失效）
struct RefundCandidate: Identifiable, Equatable {
    let link: RefundLink
    let iconName: String
    let iconColor: Color
    /// 部分退过（可退余额 < 原额）
    let partiallyRefunded: Bool
    /// 账户后缀文案（有账户且非默认才显示，与交易列表行同规则）
    let accountSuffix: String

    var id: UUID { link.originalId }

    /// 本次金额（>0）是否能退：有余额且本次金额不超过可退余额
    func isSelectable(for amount: Decimal) -> Bool {
        guard amount > 0 else { return link.refundable > 0 }
        return link.refundable >= amount
    }

    init(transaction: Transaction, refunded: Decimal) {
        let category = transaction.category
        let names = category.map { FinanceRepository.shared.resolveCategoryNames(from: $0) } ?? (primary: "", sub: nil)
        let primary = names.primary.isEmpty ? String(localized: "未分类") : names.primary
        let title = transaction.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameYear = Calendar.current.isDate(transaction.date, equalTo: Date(), toGranularity: .year)
        let dateText = transaction.date.formatted(
            sameYear ? .dateTime.month().day() : .dateTime.year().month().day()
        )
        let accountName = transaction.account?.name
        let isDefaultAccount = transaction.account?.isDefault ?? false
        let refundable = max(transaction.amountAsDecimal - refunded, 0)

        self.link = RefundLink(
            originalId: transaction.id,
            title: (title?.isEmpty == false ? title : (names.sub ?? primary)) ?? primary,
            amountText: transaction.amountAsDecimal.formattedAsCurrency(),
            categoryPath: names.sub.map { "\(primary)/\($0)" } ?? primary,
            dateText: dateText,
            accountId: transaction.account?.id,
            refundable: refundable
        )
        self.iconName = category?.icon ?? "tag.fill"
        self.iconColor = category?.swiftUIColor ?? .holoToolTextSecondary
        self.partiallyRefunded = refunded > 0
        self.accountSuffix = (accountName != nil && !isDefaultAccount) ? " · \(accountName!)" : ""
    }
}

// MARK: - AddTransactionSheet 接入

extension AddTransactionSheet {

    /// 退款引导提示条：新增流程 + 收入 + 名称或分类带退款语义 + 未关联 + 未拒绝
    var showsRefundHint: Bool {
        editingTransaction == nil
            && transactionType == .income
            && refundLink == nil
            && !refundHintDeclined
            && (RefundSemantics.matches(note) || RefundSemantics.matches(selectedCategory?.name ?? ""))
    }

    /// 传给引导区的当前金额（名称框可能是未求值的表达式，先过一次求值）
    var refundGuideAmount: Decimal {
        Decimal(string: AmountMath.resolve(displayAmountString)) ?? 0
    }

    /// 关联原支出：账户默认退回原支付账户；金额未填时带出可退余额；退款不分期
    func linkRefund(_ link: RefundLink) {
        refundLink = link
        isInstallment = false
        if link.accountId != nil, let account = accounts.first(where: { $0.id == link.accountId }) {
            selectedAccount = account
        }
        if amountString == "0" {
            amountString = AmountMath.format(link.refundable)
        }
    }

    /// 解除关联并停止本次提示（改选分类 / 取消关联 / 降级普通收入同走这里；
    /// 未关联时降级调用也要落 declined，提示条才会收起）
    func unlinkRefund() {
        refundLink = nil
        refundHintDeclined = true
    }
}
