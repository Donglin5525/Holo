//
//  HabitTileView.swift
//  Holo
//
//  习惯磁贴 —— 打卡页磁贴墙的基本单元
//  点磁贴 = 主记录动作（打卡型勾选 / 计数类 +1 / 测量类弹记录键盘）
//  长按 = 快捷菜单（数值型撤销今日最近一笔 / 查看详情 / 编辑）
//  两态：未完成 = 习惯色淡底；完成 = 实底反白 + 勾徽章，点亮时颜色圆形扩散
//

import SwiftUI
import CoreData
import os.log

// MARK: - 磁贴组件

struct HabitTileView: View {

    private let logger = Logger(subsystem: "com.holo.app", category: "HabitTileView")

    // MARK: - 输入

    let habit: Habit
    /// 磁贴在墙中的序号（入场瀑布与庆祝波浪的动画延迟）
    var index: Int = 0
    /// 本周逐日完成情况（下标 0 = 本周第一天，末位 = 今天），由列表页统一预取
    var weekPattern: [Bool] = []
    /// 庆祝波浪令牌：父视图全部完成时 +1，磁贴依次跳动一次
    var waveToken: Int = 0
    /// 长按菜单「查看详情」（无详情能力的容器如快捷打卡页传 nil 隐藏）
    var onOpenDetail: (() -> Void)? = nil
    /// 长按菜单「编辑」
    var onEdit: (() -> Void)? = nil

    // MARK: - 状态

    @State private var isCompleted: Bool = false
    @State private var todayValue: Double? = nil
    /// 测量类历史最新值（今日无记录时的回退显示）
    @State private var latestHistoricalValue: Double? = nil
    @State private var streakInfo: HabitStreak = .zero()
    @State private var showValueInput: Bool = false
    @State private var inputValue: String = ""
    /// 测量类「撤销」确认弹窗（与原卡片的确认行为一致）
    @State private var showUndoConfirm: Bool = false
    /// 坏习惯超标提示文案是否可见（3 秒自动消失，复刻原卡片）
    @State private var showOverLimitWarning: Bool = false
    /// 点亮扩散动画进行中（结束后背景切实底，移除扩散圆）
    @State private var isRevealing: Bool = false
    @State private var revealScale: CGFloat = 0
    @State private var bounceOffset: CGFloat = 0
    @State private var appeared: Bool = false
    /// 缓存的 habit ID，避免 onReceive 访问已删除对象
    @State private var cachedHabitId: UUID? = nil
    @FocusState private var isValueInputFocused: Bool

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Body

    var body: some View {
        tileContent
            .padding(14)
            .frame(minHeight: 118, alignment: .top)
            .background(backgroundLayer)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                    .stroke(
                        habit.habitColor.opacity(isCompleted ? 0 : Color.habitTileBorderOpacity(colorScheme)),
                        lineWidth: 1
                    )
            )
            .contextMenu { menuItems }
            .onTapGesture { handlePrimaryAction() }
            .sheet(isPresented: $showValueInput) { valueInputSheet }
            .onAppear {
                cachedHabitId = habit.id
                loadStatus()
                withAnimation(.easeOut(duration: 0.45).delay(Double(index) * 0.04)) {
                    appeared = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { notification in
                if let changedHabitId = notification.object as? UUID, changedHabitId != cachedHabitId {
                    return
                }
                loadStatus()
            }
            .onChange(of: waveToken) { _, _ in
                playBounce()
            }
            .offset(y: bounceOffset)
            .opacity(appeared ? 1 : 0)
    }

    // MARK: - 磁贴内容

    private var tileContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                habit.iconImage(size: 26)
                    .foregroundColor(isCompleted ? .white : habit.habitColor)

                Spacer()

                if isCompleted {
                    checkBadge
                }
            }

            nameRow

            if let subtitle = subtitleText {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(isCompleted ? .white.opacity(0.78) : .holoTextSecondary.opacity(0.9))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            bottomArea

            // 坏习惯超标提示（自动消失，复刻原卡片）
            if showOverLimitWarning {
                Text("已经超过当日限额，请注意控制")
                    .font(.system(size: 9))
                    .foregroundColor(isCompleted ? .white : .holoError)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
    }

    /// 完成勾徽章（右上角）
    private var checkBadge: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 22, height: 22)

            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
        }
        .transition(.scale(scale: 0.3).combined(with: .opacity))
        // 点亮瞬间跟在扩散动画后弹出（取消时立即消失）
        .animation(
            isCompleted
                ? .spring(response: 0.45, dampingFraction: 0.6).delay(0.12)
                : .easeOut(duration: 0.15),
            value: isCompleted
        )
    }

    private var nameRow: some View {
        HStack(spacing: 5) {
            Text(habit.name)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)

            if streakInfo.value > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 8))
                    Text("\(streakInfo.value)")
                        .font(.system(size: 9, weight: .semibold))
                }
                .opacity(0.85)
                .fixedSize()
            }
        }
        .foregroundColor(isCompleted ? .white : .holoTextPrimary)
    }

    /// 副标题：信息只在偏离默认时出现（每日习惯不显示频率）
    private var subtitleText: String? {
        var parts: [String] = []
        if habit.habitFrequency != .daily {
            parts.append(habit.habitFrequency.displayName)
        }
        if habit.isBadHabit, let target = habit.targetValueDouble {
            parts.append("上限 \(habit.formatValue(target))\(habit.unitText)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 底部区（按类型分化）

    @ViewBuilder
    private var bottomArea: some View {
        if habit.isCheckInType {
            weekDots
        } else if habit.isCountType {
            countRow
        } else {
            measureRow
        }
    }

    /// 打卡型：本周点阵（过去完成实色 / 未完成淡色 / 今天描边 / 未来最淡）
    private var weekDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<7, id: \.self) { day in
                let isToday = day == weekPattern.count - 1
                let hit = day < weekPattern.count && weekPattern[day]
                let future = day >= weekPattern.count
                Circle()
                    .fill(dotFill(hit: hit, future: future))
                    .frame(width: 6, height: 6)
                    .overlay(
                        Circle()
                            .stroke(isCompleted ? Color.white.opacity(0.6) : habit.habitColor.opacity(0.45), lineWidth: 1)
                            .frame(width: 8.5, height: 8.5)
                            .opacity(isToday ? 1 : 0)
                    )
            }
        }
    }

    private func dotFill(hit: Bool, future: Bool) -> Color {
        if hit {
            return isCompleted ? .white : habit.habitColor
        }
        let base: Double = future ? 0.06 : 0.18
        return isCompleted ? Color.white.opacity(base + 0.08) : habit.habitColor.opacity(base)
    }

    /// 计数类：第一行迷你进度条 + 当前值；第二行「−」「＋」
    /// 「−」仅在今日有记录时出现（手滑多记可直接回退，与原卡片的 -1 对齐）
    private var countRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let target = habit.targetValueDouble, target > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(isCompleted ? Color.white.opacity(0.25) : habit.habitColor.opacity(0.14))
                            Capsule()
                                .fill(countAccentColor)
                                .frame(width: geo.size.width * min((todayValue ?? 0) / target, 1))
                        }
                    }
                    .frame(height: 4)
                    .animation(.easeOut(duration: 0.3), value: todayValue)
                }

                Text(countText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(countTextColor)
                    .fixedSize()
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                if (todayValue ?? 0) > 0 {
                    Button {
                        undoLatestRecord()
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(isCompleted ? .white : habit.habitColor)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .stroke(isCompleted ? Color.white.opacity(0.5) : habit.habitColor, lineWidth: 1.2)
                            )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle().inset(by: -5))
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }

                Button {
                    increment()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(
                            // 超标时按钮变红（复刻原卡片）
                            Circle().fill(isCompleted ? Color.white.opacity(0.28) : (isOverLimit ? .holoError : habit.habitColor))
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Circle().inset(by: -5))
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: todayValue)
        }
    }

    private var countText: String {
        let value = habit.formatValue(todayValue ?? 0)
        if let target = habit.targetValueDouble, target > 0 {
            return "\(value)/\(habit.formatValue(target))"
        }
        return "\(value)\(habit.unitText)"
    }

    /// 坏习惯是否超过目标值（三分支判定，复刻原卡片口径）
    private var isOverLimit: Bool {
        guard habit.isBadHabit else { return false }

        if habit.isCheckInType {
            guard let target = habit.targetCountValue else { return false }
            // 打卡型一天只能打一次，检查 isCompleted 即可
            return isCompleted && target <= 1
        } else if habit.isCountType {
            guard let target = habit.targetValueDouble, let value = todayValue else { return false }
            return value > target
        } else {
            // 测量类坏习惯
            guard let target = habit.targetValueDouble,
                  let value = todayValue ?? latestHistoricalValue else { return false }
            return value > target
        }
    }

    private var countAccentColor: Color {
        if isOverLimit {
            return isCompleted ? .white : .holoError
        }
        return isCompleted ? .white : habit.habitColor
    }

    private var countTextColor: Color {
        if isOverLimit {
            return isCompleted ? .white : .holoError
        }
        return isCompleted ? .white : habit.habitColor
    }

    /// 测量类：当前值（今日值优先，回退历史最新值）+ 撤销（有今日记录时）+「记录」
    private var measureRow: some View {
        HStack(spacing: 6) {
            if let value = todayValue ?? latestHistoricalValue {
                Text(habit.formatValue(value))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(measureValueColor)
                    + Text(" \(habit.unitText)")
                        .font(.system(size: 9))
                        .foregroundColor(isOverLimit && !isCompleted ? .holoError : (isCompleted ? .white.opacity(0.75) : .holoTextSecondary))
            }

            Spacer(minLength: 0)

            if todayValue != nil {
                Button {
                    showUndoConfirm = true
                } label: {
                    Text("撤销")
                        .font(.system(size: 10))
                        .foregroundColor(isCompleted ? .white.opacity(0.75) : .holoTextSecondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }

            Button {
                inputValue = ""
                showValueInput = true
            } label: {
                Text("记录")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(isCompleted ? Color.white.opacity(0.28) : habit.habitColor)
                    )
            }
            .buttonStyle(.plain)
        }
        .animation(.easeOut(duration: 0.2), value: todayValue)
        .confirmationDialog(
            "撤销今日最近一笔记录？",
            isPresented: $showUndoConfirm,
            titleVisibility: .visible
        ) {
            Button("撤销", role: .destructive) {
                undoLatestRecord()
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 测量类当前值颜色：超标红（复刻原卡片），点亮后白
    private var measureValueColor: Color {
        if isOverLimit && !isCompleted { return .holoError }
        return isCompleted ? .white : habit.habitColor
    }

    // MARK: - 背景（两态 + 点亮扩散）

    @ViewBuilder
    private var backgroundLayer: some View {
        ZStack {
            Color.holoCardBackground
            // reveal 期间保持淡底，扩散圆负责点亮视觉；结束后跳到实底（此刻被圆覆盖，跳变不可见）
            habit.habitColor.opacity(isCompleted && !isRevealing ? 1 : Color.habitTileTintOpacity(colorScheme))

            if isRevealing {
                Circle()
                    .fill(habit.habitColor)
                    .frame(width: 300, height: 300)
                    .scaleEffect(revealScale)
            }
        }
    }

    // MARK: - 长按菜单

    @ViewBuilder
    private var menuItems: some View {
        Group {
            if habit.isNumericType {
                Button {
                    undoLatestRecord()
                } label: {
                    Label("撤销今日最近一笔", systemImage: "arrow.uturn.backward")
                }

                Divider()
            }

            if let onOpenDetail {
                Button {
                    onOpenDetail()
                } label: {
                    Label("查看详情", systemImage: "info.circle")
                }
            }

            if let onEdit {
                Button {
                    onEdit()
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
            }
        }
    }

    // MARK: - 主操作（点磁贴）

    /// 仅打卡型响应主体点击（勾选/取消对称，误触代价为零）。
    /// 数值类加减/记录只走明确按钮——主体点击若映射 +1，手滑按「−」时会误加。
    private func handlePrimaryAction() {
        guard habit.isCheckInType else { return }
        do {
            let newStatus = try HabitRepository.shared.toggleCheckIn(for: habit)
            if newStatus {
                isCompleted = true
                startReveal()
                HapticManager.success()
            } else {
                withAnimation(.easeInOut(duration: 0.4)) {
                    isCompleted = false
                }
                HapticManager.light()
            }
        } catch {
            logger.error("打卡失败: \(error)")
        }
    }

    private func increment() {
        do {
            _ = try HabitRepository.shared.incrementCount(for: habit)
            let newValue = HabitRepository.shared.getTodayValue(for: habit)
            // 「有记录即完成」语义：今日第一笔触发点亮
            let firstOfToday = (todayValue == nil || todayValue == 0) && (newValue ?? 0) > 0
            todayValue = newValue
            if firstOfToday {
                isCompleted = true
                startReveal()
                HapticManager.success()
            } else {
                HapticManager.light()
            }
            // 坏习惯超标时显示提示
            if habit.isBadHabit {
                checkAndShowOverLimitWarning()
            }
        } catch {
            logger.error("+1 失败: \(error)")
        }
    }

    /// 检查坏习惯是否超标，超标则显示 3 秒自动消失的提示（复刻原卡片）
    private func checkAndShowOverLimitWarning() {
        // 短暂延迟以确保 todayValue 已更新
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard self.isOverLimit else { return }

            withAnimation(.easeIn(duration: 0.3)) {
                self.showOverLimitWarning = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(.easeOut(duration: 0.3)) {
                    self.showOverLimitWarning = false
                }
            }
        }
    }

    /// 点亮扩散：从磁贴中心圆形晕开铺满（iOS 17 无点击坐标 API，中心扩散视觉等效）
    private func startReveal() {
        isRevealing = true
        withAnimation(.easeOut(duration: 0.45)) {
            revealScale = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) {
            isRevealing = false
            revealScale = 0
        }
    }

    /// 庆祝波浪：磁贴按位置依次跳一下
    private func playBounce() {
        let delay = Double(index) * 0.045
        withAnimation(.spring(response: 0.45, dampingFraction: 0.5).delay(delay)) {
            bounceOffset = -8
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + delay) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                bounceOffset = 0
            }
        }
    }

    // MARK: - 数值输入弹窗（测量类）

    private var valueInputSheet: some View {
        NavigationStack {
            VStack(spacing: HoloSpacing.lg) {
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(habit.habitColor.opacity(0.1))
                            .frame(width: 40, height: 40)

                        habit.iconImage(size: 18)
                            .foregroundColor(habit.habitColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(habit.name)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Text(habit.unitText.isEmpty ? "输入数值" : "单位：\(habit.unitText)")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer()
                }

                TextField("输入数值", text: $inputValue)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .keyboardType(.decimalPad)
                    .focused($isValueInputFocused)
                    .padding()
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

                Spacer()
            }
            .padding(HoloSpacing.lg)
            .background(Color.holoBackground)
            .navigationTitle("记录数值")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        showValueInput = false
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveValue()
                    }
                    .font(.holoBody)
                    .foregroundColor(.holoPrimary)
                    .disabled(inputValue.isEmpty)
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { isValueInputFocused = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func saveValue() {
        guard let value = Double(inputValue), value > 0 else {
            showValueInput = false
            return
        }

        do {
            _ = try HabitRepository.shared.addNumericRecord(for: habit, value: value)
            let firstOfToday = todayValue == nil
            todayValue = HabitRepository.shared.getTodayValue(for: habit)
            showValueInput = false
            if firstOfToday {
                isCompleted = true
                startReveal()
                HapticManager.success()
            } else {
                HapticManager.light()
            }
            // 坏习惯超标时显示提示
            if habit.isBadHabit {
                checkAndShowOverLimitWarning()
            }
        } catch {
            logger.error("保存数值失败: \(error)")
        }
    }

    // MARK: - 撤销（长按菜单，数值型）

    private func undoLatestRecord() {
        do {
            let removed = try HabitRepository.shared.removeLatestTodayRecord(for: habit)
            guard removed else { return }
            todayValue = HabitRepository.shared.getTodayValue(for: habit)
            if !habit.isCountType {
                latestHistoricalValue = HabitRepository.shared.getLatestValue(for: habit)
            }
            if (todayValue ?? 0) == 0 {
                withAnimation(.easeInOut(duration: 0.4)) {
                    isCompleted = false
                }
            }
            HapticManager.light()
        } catch {
            logger.error("撤销记录失败: \(error)")
        }
    }

    // MARK: - 状态加载

    private func loadStatus() {
        guard habit.managedObjectContext != nil else { return }

        Task { @MainActor in
            guard habit.managedObjectContext != nil else { return }

            let repo = HabitRepository.shared
            if habit.isCheckInType {
                isCompleted = repo.isTodayCompleted(for: habit)
                streakInfo = repo.calculateStreakInfo(for: habit)
            } else {
                todayValue = repo.getTodayValue(for: habit)
                // 「有记录即完成」——外部打卡/重进页面时与进度条口径保持一致
                isCompleted = todayValue != nil
                if !habit.isCountType {
                    latestHistoricalValue = repo.getLatestValue(for: habit)
                }
            }
        }
    }
}

// MARK: - 今日进度头（磁贴墙公共组件）

/// 橙色单色进度条版式：标题行 + 渐变细条，全部完成时标题切换为点亮文案
struct HabitProgressHeader: View {

    let completed: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isAllDone {
                    Text("今天全部点亮 ")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.holoPrimary)
                    + Text("✨")
                        .font(.system(size: 15))
                } else {
                    Text("今日进度 ")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                    + Text("\(completed)")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.holoPrimary)
                    + Text(" / \(total)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.holoBorder)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.holoPrimary, .holoPrimaryDark],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * ratio)
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.5), value: completed)
        }
    }

    private var isAllDone: Bool {
        total > 0 && completed == total
    }

    private var ratio: CGFloat {
        total > 0 ? CGFloat(completed) / CGFloat(total) : 0
    }

    private var subtitle: String {
        if total == 0 { return "" }
        return isAllDone ? "完美的一天" : "还有 \(total - completed) 项待点亮"
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Text("磁贴组件预览（需 Habit 数据）")
            .font(.holoHeading)
    }
    .padding()
    .background(Color.holoBackground)
}
