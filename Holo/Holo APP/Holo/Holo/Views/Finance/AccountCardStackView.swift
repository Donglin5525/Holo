//
//  AccountCardStackView.swift
//  Holo
//
//  账户卡堆：当前卡完整展开，其余卡露出卡头（图标+名称+余额）；
//  点卡头置顶 / 上下滑动翻卡 / 点当前卡进详情 / 长按弹管理菜单。
//  交互与视觉规范见 docs/design-mockups/finance-account-cards-brand.html
//

import SwiftUI

// MARK: - 数据模型

/// 卡堆里一张卡需要的全部数据（余额与月度收支在父视图统一取数，避免 body 内反复 fetch）
struct AccountStackItem: Identifiable {
    let account: Account
    let balance: Decimal
    let monthlyIncome: Decimal
    let monthlyExpense: Decimal

    var id: UUID { account.id }

    /// 信用卡余额为负（欠款）；卡面语义「已用额度」取其绝对值
    var outstanding: Decimal? {
        guard account.accountType.isCreditCard, balance < 0 else { return nil }
        return -balance
    }
}

// MARK: - 金额格式化

enum AccountCardFormat {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "zh_CN")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    /// 千分位数字（不含货币符号）："8,420.50"
    static func amount(_ value: Decimal) -> String {
        formatter.string(from: NSDecimalNumber(decimal: value)) ?? "0.00"
    }
}

// MARK: - 卡堆

struct AccountCardStackView: View {
    let items: [AccountStackItem]

    /// 当前置顶的账户（父视图持久化，下次进入自动置顶）
    @Binding var topAccountId: UUID?

    var onOpenDetail: (Account) -> Void
    var onAddAccount: () -> Void
    var onEdit: (Account) -> Void
    var onAdjustBalance: (Account) -> Void
    var onSetDefault: (Account) -> Void
    var onArchive: (Account) -> Void

    /// 卡头高度；BODY = 当前卡展开的卡身高度
    static let headHeight: CGFloat = 64
    static let bodyHeight: CGFloat = 148
    static let cardHeight: CGFloat = 212
    /// 收起卡露出的卡身边高度（被下一张卡叠压，形成实体卡堆层次）
    static let collapsedTailHeight: CGFloat = 16
    /// 相邻收起卡的步进 = 卡头 64；收起卡总高 80 → 与下一张重叠 16pt
    static let collapsedCardHeight: CGFloat = 80
    /// 当前展开卡与卡堆的分离间距（「抽出来的卡」语义）
    static let stackGap: CGFloat = 10

    @State private var order: [UUID] = []
    @State private var appeared = false

    private let flipAnimation = Animation.spring(response: 0.5, dampingFraction: 0.86)

    var body: some View {
        ZStack(alignment: .top) {
            // 视觉层：当前卡完整展开，收起卡只渲染卡头（图标+名称+余额）。
            // 不靠「完整卡互相遮挡」实现堆叠——遮挡计算要求下层卡 zIndex 更高、
            // 身体延伸裁剪等，极易错位；只渲染头部则天然互不重叠。
            ForEach(Array(order.enumerated()), id: \.element) { index, id in
                if let item = item(for: id) {
                    AccountMaterialCard(item: item, isCurrent: index == 0, showsBody: index == 0)
                        .allowsHitTesting(false)
                        .offset(y: stackOffset(index) + (appeared ? 0 : -26))
                        .opacity(appeared ? 1 - Double(index) * 0.06 : 0)
                        .animation(flipAnimation.delay(Double(index) * 0.07), value: appeared)
                        .animation(flipAnimation, value: order)
                        // zIndex 放在 animation 之外：层级不参与弹簧插值，翻卡瞬间
                        // 就按目标层级绘制。否则过渡期间层级与位置错配，飞卡会盖住
                        // 途经的卡/添加卡（「最后一张卡遮挡添加账户」的根源）
                        .zIndex(Double(index))
                }
            }

            // 「＋ 添加账户」虚线卡头（常驻堆底）
            addButton
                .offset(y: addButtonOffset)
                .opacity(appeared ? 1 : 0)
                .animation(flipAnimation.delay(Double(order.count) * 0.07), value: appeared)
                // 增删账户挪位时与卡片同一条弹簧移动，避免按钮瞬移、卡片慢移的两层错位
                .animation(flipAnimation, value: order)
                .zIndex(100)

            // 命中层：当前卡整卡可点，收起卡仅头部可点（与视觉严格对齐）。
            // 用 contentShape + onTapGesture（Button+contextMenu 在手势竞争中长按易失效）
            ForEach(Array(order.enumerated()), id: \.element) { index, id in
                if let item = item(for: id) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if index == 0 {
                                onOpenDetail(item.account)
                            } else {
                                bringToTop(id)
                            }
                        }
                        .contextMenu { cardMenu(for: item.account) }
                        .frame(height: index == 0 ? Self.cardHeight : Self.headHeight)
                        .offset(y: stackOffset(index))
                        .zIndex(Double(50 + index))
                }
            }
        }
        .frame(height: totalHeight, alignment: .top)
        .gesture(
            // 普通优先级：点击交给命中层，只有滑动超过阈值才翻卡
            DragGesture(minimumDistance: 28)
                .onEnded { value in
                    if value.translation.height < -56 {
                        cycle(forward: true)
                    } else if value.translation.height > 56 {
                        cycle(forward: false)
                    }
                }
        )
        .onAppear {
            rebuildOrder()
            appeared = true
        }
        .onChange(of: items.map(\.id)) { _, _ in
            rebuildOrder()
        }
    }

    // MARK: 堆叠几何

    /// 第 0 张完整展开，与卡堆留分离间距；其后每张步进一条卡头位，
    /// 收起卡总高 80 > 步进 64 → 相邻卡天然叠压 16pt（后卡压前卡底边）
    private func stackOffset(_ index: Int) -> CGFloat {
        index == 0
            ? 0
            : Self.cardHeight + Self.stackGap + CGFloat(index - 1) * Self.headHeight
    }

    /// 添加卡排在最后，同样压住最后一张收起卡的底边
    private var addButtonOffset: CGFloat {
        Self.cardHeight + Self.stackGap + CGFloat(max(order.count - 1, 0)) * Self.headHeight
    }

    private var totalHeight: CGFloat {
        addButtonOffset + Self.headHeight
    }

    // MARK: 子视图

    private var addButton: some View {
        Button {
            onAddAccount()
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.holoPrimary.opacity(0.12))
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.holoPrimaryDark)
                }
                .frame(width: 26, height: 26)
                Text("添加账户")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoPrimaryDark)
            }
        }
        .frame(height: Self.headHeight)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AccountCardMaterial.cornerRadius, style: .continuous)
                .fill(Color.holoPrimary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AccountCardMaterial.cornerRadius, style: .continuous)
                .strokeBorder(Color.holoPrimaryDark.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .buttonStyle(.plain)
    }

    private func cardMenu(for account: Account) -> some View {
        Group {
            Button { onEdit(account) } label: {
                Label("编辑账户", systemImage: "pencil")
            }
            Button { onAdjustBalance(account) } label: {
                Label("调整余额", systemImage: "arrow.triangle.2.circlepath")
            }
            if account.isDefault {
                Label("设为默认（当前默认）", systemImage: "star.fill")
            } else {
                Button { onSetDefault(account) } label: {
                    Label("设为默认", systemImage: "star")
                }
            }
            Divider()
            Button(role: .destructive) { onArchive(account) } label: {
                Label("归档账户", systemImage: "archivebox")
            }
        }
    }

    // MARK: 翻卡

    private func item(for id: UUID) -> AccountStackItem? {
        items.first { $0.id == id }
    }

    private func bringToTop(_ id: UUID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
        syncTop()
    }

    /// 上滑=当前卡收到底部（首移尾），下滑=最后一张拉回顶部
    private func cycle(forward: Bool) {
        guard !order.isEmpty else { return }
        if forward {
            order.append(order.removeFirst())
        } else {
            order.insert(order.removeLast(), at: 0)
        }
        syncTop()
    }

    private func syncTop() {
        topAccountId = order.first
    }

    /// 账户增删后重建顺序：记住的置顶账户保持在顶，其余按传入顺序
    private func rebuildOrder() {
        let valid = items.map(\.id)
        var newOrder: [UUID] = []
        if let top = topAccountId, valid.contains(top) {
            newOrder.append(top)
        }
        newOrder.append(contentsOf: valid.filter { $0 != topAccountId })
        order = newOrder
    }
}

// MARK: - 单张卡（视觉层）

struct AccountMaterialCard: View {
    let item: AccountStackItem
    let isCurrent: Bool
    /// 收起态只渲染卡头（高度 64），当前卡完整展开（高度 212）
    var showsBody: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            head
            if showsBody {
                cardBody
                    // 展开时从卡头下方滑出、收起时滑回（clipped 裁掉滑入途中
                    // 越出卡身区域的部分，形成「从卡头底下抽出来」的展开感）；
                    // 转场与卡壳 offset 共用外层同一条 spring，避免「壳在滑、
                    // 内容原地淡入等贴」的两层动画割裂
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .clipped()
            } else {
                // 折叠尾条：材质自然延伸出 16pt 卡身边，被下一张卡叠压
                Color.clear.frame(height: AccountCardStackView.collapsedTailHeight)
            }
        }
        .modifier(AccountCardMaterial(palette: .palette(for: item.account), isCurrent: isCurrent, compact: !showsBody))
        .overlay(alignment: .bottomTrailing) {
            // 卡面水印：右下角大图标，7% 透明度强化识别又不出戏（仅展开卡）
            if showsBody {
                Image(systemName: item.account.icon)
                    .font(.system(size: 110, weight: .light))
                    .foregroundColor(.white.opacity(0.07))
                    .padding(.trailing, 8)
                    .padding(.bottom, -18)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: 卡头（收起时露出的识别区，64pt）

    private var head: some View {
        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.white.opacity(0.16))
                Image(systemName: item.account.icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white)
            }
            .frame(width: 38, height: 38)
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.account.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if item.account.isDefault {
                        Text("★ 默认")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color(hex: "#FFAA6E").opacity(0.28)))
                            .overlay(Capsule().strokeBorder(Color(hex: "#FFBE8C").opacity(0.35), lineWidth: 0.5))
                    }
                }
                Text("\(item.account.accountType.displayName) · \(item.account.accountType.englishLabel)")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.4)
                    .foregroundColor(.white.opacity(0.78))
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("¥\(AccountCardFormat.amount(item.outstanding ?? item.balance))")
                    .font(.system(size: 14.5, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(item.outstanding != nil ? "已用额度" : "当前余额")
                    .font(.system(size: 9))
                    .tracking(0.8)
                    .foregroundColor(.white.opacity(0.68))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: AccountCardStackView.headHeight)
        .background(
            LinearGradient(colors: [.white.opacity(0.05), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: 卡身（当前卡展开区）

    private var cardBody: some View {
        VStack(spacing: 0) {
            // 把手条：当前卡由品牌橙点亮
            Capsule()
                .fill(isCurrent ? Color.holoPrimary : Color.white.opacity(0.35))
                .frame(width: 30, height: 4)
                .shadow(color: isCurrent ? Color.holoPrimary.opacity(0.65) : .clear, radius: 6)
                .padding(.top, 5)
                .padding(.bottom, 3)

            if let outstanding = item.outstanding {
                creditBody(outstanding: outstanding)
            } else {
                balanceBody
            }
        }
    }

    private var balanceBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前余额 · BALANCE")
                        .font(.system(size: 9.5, weight: .medium))
                        .tracking(1.6)
                        .foregroundColor(.white.opacity(0.75))
                    HStack(alignment: .top, spacing: 2) {
                        Text("¥")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                        Text(AccountCardFormat.amount(item.balance))
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
                Spacer()
                if showsChip {
                    AccountChipIcon().padding(.bottom, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            HStack(spacing: 6) {
                AccountCardPill(label: "本月支出", value: "¥\(AccountCardFormat.amount(item.monthlyExpense))")
                AccountCardPill(label: "本月收入", value: "¥\(AccountCardFormat.amount(item.monthlyIncome))")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 15)
        }
    }

    private func creditBody(outstanding: Decimal) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已用额度 · OUTSTANDING")
                        .font(.system(size: 9.5, weight: .medium))
                        .tracking(1.6)
                        .foregroundColor(.white.opacity(0.75))
                    HStack(alignment: .top, spacing: 2) {
                        Text("¥")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                        Text(AccountCardFormat.amount(outstanding))
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
                Spacer()
                AccountChipIcon().padding(.bottom, 2)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 11)

            // 额度水位：欠款越多，暖光越长
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.20))
                    Capsule()
                        .fill(LinearGradient(colors: [Color(hex: "#FFEBCD").opacity(0.65), Color(hex: "#FFEBCD")], startPoint: .leading, endPoint: .trailing))
                        .shadow(color: Color(hex: "#FFE1B4").opacity(0.45), radius: 4)
                        .frame(width: proxy.size.width * creditUsageRatio)
                }
            }
            .frame(height: 4.5)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            HStack(spacing: 6) {
                if let limit = item.account.creditLimitDecimal {
                    AccountCardPill(label: "可用", value: "¥\(AccountCardFormat.amount(max(limit - outstanding, 0)))")
                    AccountCardPill(label: "总额度", value: "¥\(AccountCardFormat.amount(limit))")
                }
                if let billDay = item.account.billingDayInt, let dueDay = item.account.dueDayInt {
                    AccountCardPill(label: "账单 \(billDay) 日 · 还款 \(dueDay) 日", value: "")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 15)
        }
    }

    private var creditUsageRatio: CGFloat {
        guard let limit = item.account.creditLimitDecimal, limit > 0 else { return 0 }
        let used = item.outstanding ?? 0
        let ratio = NSDecimalNumber(decimal: used / limit).doubleValue
        return min(max(CGFloat(ratio), 0), 1)
    }

    /// 芯片只给实体卡类账户（信用卡 / 储蓄卡），现金与钱包不带
    private var showsChip: Bool {
        item.account.accountType.isCreditCard || item.account.accountType == .bank || item.account.accountType == .card
    }
}
