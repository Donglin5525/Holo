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

    // MARK: 拖拽排序（单一连续列表，跨频率自由拖动，落库全局生效）

    @StateObject private var reorder = HabitListReorderModel()

    private var orderedRows: [HabitRowSnapshot] {
        let base = model.filteredTodayRows
        let byId = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        return reorder.effectiveIds(.today, baseline: base.map(\.id)).compactMap { byId[$0] }
    }

    // MARK: Body

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    headerSection
                    filterBar

                    if model.filteredTodayRows.isEmpty {
                        emptyState
                    } else {
                        ForEach(orderedRows) { row in
                            habitRow(row)
                            .id(row.id)
                        }

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
                consumeFocus(proxy)
            }
            .onChange(of: focusHabitId) { _, _ in consumeFocus(proxy) }
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
                guard !reorder.isInteracting else { return }
                onOpenTodayRecords(row.id)
            },
            onToggleCheckIn: {
                guard !reorder.isInteracting else { return }
                Task { await model.record(kind: .toggleCheckIn, habitId: row.id) }
            },
            onIncrement: {
                guard !reorder.isInteracting else { return }
                Task { await model.record(kind: .increment(amount: 1), habitId: row.id) }
            },
            onDecrement: {
                guard !reorder.isInteracting else { return }
                Task { await model.record(kind: .removeLatestNumeric, habitId: row.id) }
            },
            onMeasureRecord: {
                guard !reorder.isInteracting else { return }
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

    // MARK: 头部（日期 + 已记录数量）

    private var headerSection: some View {
        // 固定「今天已记录 X 项」：周/月习惯与减少的习惯不能被当成每日必做清单（V2 §5.1）
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
        }
        .accessibilityElement(children: .combine)
    }

    private var dateLineText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("MMMMd EEEE")
        return formatter.string(from: model.projectionNow)
    }

    // MARK: 筛选与补录

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                filterChip(String(localized: "全部"), selected: model.todayFilter == .all) {
                    model.todayFilter = .all
                }
                filterChip(String(localized: "未记录"), selected: model.todayFilter == .unrecorded) {
                    model.todayFilter = .unrecorded
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.holoToolInset))

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
            }
            .buttonStyle(HoloPressStyle())
            .accessibilityIdentifier("habit.today.retroactive")
        }
    }

    private func filterChip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .holoPrimary : .holoToolTextSecondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
        }
        .buttonStyle(HoloPressStyle())
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

    // MARK: 空状态（分形态，不伪装；筛选空/全暂停/全归档/首次空）

    @ViewBuilder
    private var emptyState: some View {
        if model.todayFilter == .unrecorded {
            emptyCard(
                title: String(localized: "当前筛选下没有习惯"),
                message: String(localized: "未记录是记录筛选，不代表任务未完成。"),
                buttonTitle: String(localized: "查看全部")
            ) {
                model.todayFilter = .all
            }
        } else if !model.pausedRows.isEmpty {
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
                        .foregroundColor(.white)
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
                        .foregroundColor(.holoError)
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
        if row.kind == .checkIn {
            return row.frequency == .daily
                ? String(localized: "补签")
                : String(localized: "周/月习惯按周期记录，不补每日漏签")
        }
        return String(localized: "补记")
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
