//
//  HabitTodayView.swift
//  Holo
//
//  今天页（V2 §5）：日期与已记录数量 → 全部/未记录筛选与补录 →
//  全部习惯连续列表（不按频率分组，东林 2026-10-07 拍板：分组切断拖拽排序）→
//  底部轻量暂停入口。名称打开「今天的记录」；缝线只读；无顶部七天统计条。
//

import SwiftUI
import Combine

struct HabitTodayView: View {

    @ObservedObject var model: HabitModuleViewModel
    let onOpenAddHabit: () -> Void
    /// 打开「今天的记录」弹层
    var onOpenTodayRecords: (UUID) -> Void
    /// 打开低频名单（更多 → 已暂停与已归档）
    var onOpenLifecycleList: () -> Void
    /// 「去今天记录」定位目标（消费后回调清零）
    var focusHabitId: UUID? = nil
    var onFocusConsumed: () -> Void = {}

    // MARK: 弹层状态

    /// 测量输入目标（记录/再记录）
    @State private var measureInputTarget: HabitRowSnapshot?
    /// 补录的习惯选择
    @State private var showRetroactiveHabitPicker = false

    // MARK: 拖拽排序（全局顺序数组；渲染分节，跨节不换位——P2 三节分制）

    @StateObject private var reorder = HabitListReorderModel()
    @Environment(\.scenePhase) private var scenePhase

    /// 主角区（每日打卡）显示上限，超出折叠（2026-10-15 东林拍板：放 4 个）
    private static let heroCardLimit = 4
    @State private var heroExpanded = false

    private var orderedRows: [HabitRowSnapshot] {
        let base = model.todayRows
        let byId = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        return reorder.effectiveIds(.today, baseline: base.map(\.id)).compactMap { byId[$0] }
    }

    // MARK: 分节（P2 三节分制 + 坏习惯独立节；同节内拖拽换位，跨节不换）

    private enum TodaySection: Int {
        case checkInHero  // 每日打卡好习惯（主角大卡）
        case numeric      // 计数/测量好习惯
        case weekly       // 每周/每月频率
        case bad          // 坏习惯（想减少的事）
    }

    private func section(of row: HabitRowSnapshot) -> TodaySection {
        if row.isBadHabit { return .bad }
        switch row.frequency {
        case .daily:
            return row.kind == .checkIn ? .checkInHero : .numeric
        case .weekly, .monthly:
            return .weekly
        }
    }

    private var groupedRows: [TodaySection: [HabitRowSnapshot]] {
        Dictionary(grouping: orderedRows, by: section(of:))
    }

    // MARK: Body

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    headerSection

                    if model.todayRows.isEmpty {
                        emptyState
                    } else {
                        sectionList
                        pausedEntry
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.xs)
                .padding(.bottom, 40)
            }
            .onAppear {
                reorder.scrollProxy = proxy
                reorder.onCommit = { _, order, draggedId in
                    model.persistTodayOrder(order, draggedId: draggedId)
                }
                reorder.canSwapAdjacent = { a, b in
                    let byId = Dictionary(uniqueKeysWithValues: model.todayRows.map { ($0.id, $0) })
                    guard let ra = byId[a], let rb = byId[b] else { return true }
                    return section(of: ra) == section(of: rb)
                }
                consumeFocus(proxy)
            }
            .onChange(of: focusHabitId) { _, _ in consumeFocus(proxy) }
        }
        // 离开前台（来电/控制中心/切换 App）时系统不保证手势 onEnded 回调，
        // 未收尾的拖拽会话就地取消，防全页按钮被 guard 永久静默吞掉
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { reorder.cancelDrag() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 页面内撤销提示（底部导航之上；导航由容器层提供 inset）
            if let hint = model.undoHint {
                HabitRecordFeedbackView(hint: hint) {
                    Task { await model.undoLast() }
                } onExpire: {
                    model.expireUndoHint()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.undoHint)
        .sheet(item: $measureInputTarget) { snapshot in
            HabitMeasureInputSheet(snapshot: snapshot) { value, note in
                Task { await model.record(kind: .addNumeric(value: value), habitId: snapshot.id, note: note) }
            }
        }
        .sheet(isPresented: $showRetroactiveHabitPicker) {
            RetroactiveHabitPicker(model: model)
        }
    }

    /// 定位到目标习惯（「去今天记录」回跳；等行渲染完成后再滚）
    private func consumeFocus(_ proxy: ScrollViewProxy) {
        guard let focusHabitId else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation {
                proxy.scrollTo(focusHabitId, anchor: .center)
            }
            onFocusConsumed()
        }
    }

    private func habitRow(_ row: HabitRowSnapshot) -> some View {
        HabitRowView(
            snapshot: row,
            isSaving: model.coordinator.savingHabitIds.contains(row.id),
            inlineErrorMessage: model.inlineError?.habitId == row.id ? model.inlineError?.message : nil,
            // 拖拽会话中/刚落定的行不放行按钮（长按后直接抬手不该触发打卡/开详情）
            onOpenTodayRecords: {
                guard reorder.admitInteraction() else { return }
                onOpenTodayRecords(row.id)
            },
            onToggleCheckIn: {
                guard reorder.admitInteraction() else { return }
                Task { await model.record(kind: .toggleCheckIn, habitId: row.id) }
            },
            onIncrement: {
                guard reorder.admitInteraction() else { return }
                Task { await model.record(kind: .increment(amount: 1), habitId: row.id) }
            },
            onDecrement: {
                guard reorder.admitInteraction() else { return }
                Task { await model.record(kind: .removeLatestNumeric, habitId: row.id) }
            },
            onMeasureRecord: {
                guard reorder.admitInteraction() else { return }
                measureInputTarget = row
            }
        )
        .habitReorderable(
            id: row.id,
            section: .today,
            spacing: HoloSpacing.sm,
            model: reorder
        )
    }

    // MARK: 头部（日期 + 已记录数量 + 补录入口；P2 撤筛选，2026-10-15 东林拍板）

    private var headerSection: some View {
        HStack(spacing: 6) {
            Text(dateLineText)
                .font(.system(size: 13))
                .foregroundColor(.holoToolTextSecondary)
            Text("·")
                .font(.system(size: 13))
                .foregroundColor(.holoToolTextSecondary.opacity(0.5))
            Text(String(localized: "今天已记录 \(model.recordedTodayCount) 项"))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(model.recordedTodayCount > 0 ? .holoPrimary : .holoToolTextSecondary)

            Spacer(minLength: 0)

            Button {
                showRetroactiveHabitPicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                        .foregroundColor(.holoToolTextSecondary)
                    Text(String(localized: "补录"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoToolText)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(Capsule().fill(Color.holoToolInset))
            }
            .buttonStyle(HoloPressStyle())
            .accessibilityIdentifier("habit.today.retroactive")
        }
        .accessibilityElement(children: .combine)
    }

    private var dateLineText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("MMMMd EEEE")
        return formatter.string(from: model.projectionNow)
    }

    // MARK: 分节列表（今天的打卡主角 → 记数字 → 每周每月 → 想减少的事）

    @ViewBuilder
    private var sectionList: some View {
        let grouped = groupedRows

        if let heroes = grouped[.checkInHero], !heroes.isEmpty {
            sectionLabel(String(localized: "今天的打卡 · \(heroes.count) 个"))
            ForEach(heroExpanded ? heroes : Array(heroes.prefix(Self.heroCardLimit))) { row in
                heroCard(row)
                    .id(row.id)
            }
            if heroes.count > Self.heroCardLimit, !heroExpanded {
                expandHeroButton(count: heroes.count)
            }
        }

        if let rows = grouped[.numeric], !rows.isEmpty {
            sectionLabel(String(localized: "记数字 · \(rows.count) 个"))
            ForEach(rows) { row in
                habitRow(row)
                    .id(row.id)
            }
        }

        if let rows = grouped[.weekly], !rows.isEmpty {
            sectionLabel(String(localized: "每周与每月 · \(rows.count) 个"))
            ForEach(rows) { row in
                habitRow(row)
                    .id(row.id)
            }
        }

        if let rows = grouped[.bad], !rows.isEmpty {
            sectionLabel(String(localized: "想减少的事 · \(rows.count) 个"))
            ForEach(rows) { row in
                habitRow(row)
                    .id(row.id)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .kerning(0.5)
            .foregroundColor(.holoToolTextSecondary)
            .padding(.top, 8)
    }

    private func expandHeroButton(count: Int) -> some View {
        Button {
            withAnimation(HoloAnimation.quick) { heroExpanded = true }
        } label: {
            Text(String(localized: "查看全部 \(count) 个"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.holoPrimary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.holoPrimary.opacity(0.06))
                )
        }
        .buttonStyle(HoloPressStyle())
        .accessibilityIdentifier("habit.today.expandHeroes")
    }

    // MARK: 主角大卡（每日打卡好习惯：连续大数字 + 大打卡钮 + 近一周条）

    private func heroCard(_ row: HabitRowSnapshot) -> some View {
        let done = row.today.isRecorded
        let accent = Color(hex: row.colorHex)
        return HStack(spacing: HoloSpacing.md) {
            // 左侧信息区=行主体（AX 单元素，identifier 与普通行同款；点开概览弹层）
            Button {
                guard reorder.admitInteraction() else { return }
                onOpenTodayRecords(row.id)
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    row.iconImage(size: 20)
                        .foregroundColor(accent)
                        .frame(width: 42, height: 42)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(accent.opacity(0.12)))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        if let streak = row.streak, streak.value > 0 {
                            Text("\(streak.value) \(streak.unitName)")
                                .font(.system(size: 27, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundColor(accent)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        Text(heroSubtitle(row))
                            .font(.system(size: 11.5))
                            .foregroundColor(.holoToolTextSecondary.opacity(0.9))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("habit.rowbody.\(row.id)")
            .accessibilityLabel(Text(String(localized: "查看\(row.name)今天的记录")))
            .accessibilityHint(Text(String(localized: "连续打卡中")))

            Button {
                guard reorder.admitInteraction() else { return }
                Task { await model.record(kind: .toggleCheckIn, habitId: row.id) }
            } label: {
                Group {
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(accent))
                    } else {
                        Text(String(localized: "打卡"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(accent)
                            .frame(width: 66, height: 52)
                            .background(Capsule().fill(accent.opacity(0.14)))
                    }
                }
            }
            .buttonStyle(HoloPressStyle())
            .disabled(model.coordinator.savingHabitIds.contains(row.id))
            .accessibilityIdentifier("habit.row.\(row.id).record")
            .accessibilityLabel(Text(done ? String(localized: "取消打卡") : String(localized: "打卡")))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.1), accent.opacity(0.045)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(accent.opacity(0.25), lineWidth: 1)
        )
        .habitReorderable(id: row.id, section: .today, spacing: HoloSpacing.sm, model: reorder)
    }

    /// 大卡副行：没打卡给习惯名+激励，已打卡给习惯名；周条贴卡底
    private func heroSubtitle(_ row: HabitRowSnapshot) -> String {
        if row.today.isRecorded { return row.name }
        return row.streak?.value ?? 0 > 0
            ? "\(row.name) · \(String(localized: "别断了今天"))"
            : row.name
    }

    // MARK: 底部暂停轻量入口（有活跃列表且有暂停时）

    @ViewBuilder
    private var pausedEntry: some View {
        if model.pausedCount > 0, !model.todayRows.isEmpty {
            Button {
                onOpenLifecycleList()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 13))
                    Text(String(localized: "已暂停 \(model.pausedCount) 项"))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .accessibilityIdentifier("habit.today.paused")
        }
    }

    // MARK: 空状态（分形态，不伪装；全暂停/全归档/首次空；筛选已撤）

    @ViewBuilder
    private var emptyState: some View {
        if !model.pausedRows.isEmpty {
            emptyCard(
                title: String(localized: "给日常留一点空隙"),
                message: String(localized: "暂停中的习惯和以前的记录都还在。"),
                buttonTitle: String(localized: "查看暂停习惯"),
                icon: "pause.circle"
            ) {
                onOpenLifecycleList()
            }
        } else if !model.archivedRows.isEmpty {
            emptyCard(
                title: String(localized: "习惯都已归档"),
                message: String(localized: "想继续的时候，可以再找回来。"),
                buttonTitle: String(localized: "查看归档习惯"),
                icon: "archivebox"
            ) {
                onOpenLifecycleList()
            }
        } else {
            emptyCard(
                title: String(localized: "从一件小事开始"),
                message: String(localized: "先创建一个习惯，今天就能留下第一条记录。"),
                buttonTitle: String(localized: "创建第一个习惯")
            ) {
                onOpenAddHabit()
            }
        }
    }

    private func emptyCard(title: String, message: String,
                           buttonTitle: String? = nil,
                           icon: String = "leaf",
                           action: (() -> Void)? = nil) -> some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundColor(.holoPrimary.opacity(0.7))
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 17).fill(Color.holoToolInset))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.holoToolText)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)
                .multilineTextAlignment(.center)
            if let buttonTitle, let action {
                Button(action: action) {
                    Text(buttonTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoToolOnAction)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(Color.holoToolAction))
                }
                .buttonStyle(HoloPressStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - 测量输入弹层

/// 测量记录输入：有限非负数值（含真实 0），可选备注（方案 §8.2/§11.4）
struct HabitMeasureInputSheet: View {

    let snapshot: HabitRowSnapshot
    var onSave: (Double, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var valueText = ""
    @State private var note = ""
    @State private var errorMessage: String?
    @FocusState private var valueFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.lg) {
            Text(String(localized: "记录\(snapshot.name)"))
                .font(.holoHeading)
                .foregroundColor(.holoToolText)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField(unitPlaceholder, text: $valueText)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 26, weight: .semibold).monospacedDigit())
                        .foregroundColor(.holoToolText)
                        .focused($valueFocused)
                        .accessibilityIdentifier("habit.measure.value")
                    if !unitText.isEmpty {
                        Text(unitText)
                            .font(.system(size: 15))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolError)
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous).fill(Color.holoToolInset))

            TextField(String(localized: "备注（可选）"), text: $note)
                .font(.holoBody)
                .foregroundColor(.holoToolText)
                .padding()
                .background(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous).fill(Color.holoToolInset))

            HStack(spacing: HoloSpacing.md) {
                Button {
                    dismiss()
                } label: {
                    Text(String(localized: "取消"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.holoToolText)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Capsule().fill(Color.holoToolInset))
                }
                .buttonStyle(HoloPressStyle())

                Button {
                    save()
                } label: {
                    Text(String(localized: "保存"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.holoToolOnAction)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Capsule().fill(Color.holoToolAction))
                }
                .buttonStyle(HoloPressStyle())
                .accessibilityIdentifier("habit.record.save")
            }

            Spacer(minLength: 0)
        }
        .padding(HoloSpacing.lg)
        .presentationDetents([.height(320)])
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "完成")) { valueFocused = false }
            }
        }
        .onAppear { valueFocused = true }
    }

    private var unitText: String { snapshot.target?.unit ?? "" }

    private var unitPlaceholder: String {
        snapshot.kind == .measure ? String(localized: "输入今天的数值") : String(localized: "输入数量")
    }

    private func save() {
        // Locale 合法小数 + 有限值（方案 §11.4）；测量允许 0
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        guard let number = formatter.number(from: valueText.trimmingCharacters(in: .whitespaces)),
              let value = number as? Double, value.isFinite, value >= 0 else {
            errorMessage = String(localized: "请输入有效的数值（不能为空或负数）")
            valueFocused = true
            return
        }
        onSave(value, note.isEmpty ? nil : note)
        dismiss()
    }
}

// MARK: - 补录习惯选择

/// 今天页补录入口：先选习惯，再进既有补签/补记弹层（V2 §5.2 统一入口文案「补录」）
private struct RetroactiveHabitPicker: View {

    @ObservedObject var model: HabitModuleViewModel
    @Environment(\.dismiss) private var dismiss

    /// 只提供支持的模式：好习惯（打卡每日/数值）且进行中（既有资格规则）
    private var eligibleRows: [HabitRowSnapshot] {
        model.todayRows.filter { !$0.isBadHabit }
    }

    var body: some View {
        NavigationStack {
            List(eligibleRows) { row in
                Button {
                    dismiss()
                    // 打开既有补签/补记弹层（模式/日期由既有弹层承载）
                    PendingRetroactiveOpener.shared.open(habitId: row.id)
                } label: {
                    HStack(spacing: HoloSpacing.md) {
                        row.iconImage(size: 15)
                            .foregroundColor(Color(hex: row.colorHex))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .foregroundColor(.holoToolText)
                            Text(actionText(row))
                                .font(.system(size: 12))
                                .foregroundColor(.holoToolTextSecondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(String(localized: "选择要补录的习惯"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// 实际动作按既有资格区分（V2 §5.2：入口统一叫补录，动作再分补签/补记）
    private func actionText(_ row: HabitRowSnapshot) -> String {
        row.kind == .checkIn ? String(localized: "补签") : String(localized: "补记")
    }
}

/// 补签弹层的打开中转：习惯选择弹层 dismiss 后由宿主视图消费
/// （sheet 之上再开 sheet 需在非 sheet 层级触发）
@MainActor
final class PendingRetroactiveOpener: ObservableObject {
    static let shared = PendingRetroactiveOpener()
    @Published var habitId: UUID?
    func open(habitId: UUID) { self.habitId = habitId }
}
