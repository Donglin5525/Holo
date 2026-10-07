//
//  HabitTileView.swift
//  Holo
//
//  习惯磁贴 —— 打卡页磁贴墙的基本单元（温润纸感 · 2026-10-06 方案）
//  点磁贴 = 主记录动作（打卡型勾选 / 计数类 +1 / 测量类弹记录键盘）
//  长按 = 快捷菜单（数值型撤销今日最近一笔 / 查看详情 / 编辑 / 删除习惯）
//  两态：未完成 = 纸白卡 + 暖灰细描边（安静纸墙）；完成 = 习惯色钳制实底 + 白字 + 盖章
//

import SwiftUI
import CoreData
import os.log

// MARK: - 磁贴组件

struct HabitTileView: View {

    private let logger = Logger(subsystem: "com.holo.app", category: "HabitTileView")

    // MARK: - 输入

    let habit: Habit
    /// 磁贴在墙中的序号（保留调用方接口）
    var index: Int = 0
    /// 本周逐日完成情况（下标 0 = 本周第一天，末位 = 今天），由列表页统一预取
    var weekPattern: [Bool] = []
    /// 兼容原有调用方参数；V2 不再播放全墙庆祝波浪
    var waveToken: Int = 0
    /// 长按菜单「查看详情」（无详情能力的容器如快捷打卡页传 nil 隐藏）
    var onOpenDetail: (() -> Void)? = nil
    /// 长按菜单「编辑」
    var onEdit: (() -> Void)? = nil
    /// 长按菜单「暂停习惯」（Plus 功能；无此能力的容器传 nil 隐藏）
    var onPause: (() -> Void)? = nil

    // MARK: - 状态

    @State private var isCompleted: Bool = false
    @State private var todayValue: Double? = nil
    /// 测量类历史最新值（今日无记录时的回退显示）
    @State private var latestHistoricalValue: Double? = nil
    @State private var streakInfo: HabitStreak = .zero()
    /// 全历史累计（打卡型好习惯=完成次数；计数类=数值总和；坏习惯/测量类=nil）
    @State private var lifetimeTotal: Double? = nil
    @State private var showValueInput: Bool = false
    @State private var inputValue: String = ""
    @State private var inputNote: String = ""
    /// 打卡型「当日备注」编辑弹层
    @State private var showCheckInNote: Bool = false
    @State private var checkInNoteText: String = ""
    /// 测量类「撤销」确认弹窗（与原卡片的确认行为一致）
    @State private var showUndoConfirm: Bool = false
    /// 长按菜单「删除习惯」确认弹窗（名字在点菜单时快照，弹窗展示期间不触碰 habit 对象）
    @State private var showDeleteConfirm: Bool = false
    @State private var deleteTargetName: String = ""
    /// 坏习惯超标提示文案是否可见（3 秒自动消失，复刻原卡片）
    @State private var showOverLimitWarning: Bool = false
    /// 首次呈现时的轻淡入
    @State private var appeared: Bool = false
    /// 缓存的 habit ID，避免 onReceive 访问已删除对象
    @State private var cachedHabitId: UUID? = nil
    /// 补签弹层目标（非 nil 时弹出）
    @State private var retroContext: HabitRetroactiveSheetContext? = nil
    /// 最近 7 天可补签天数（长按菜单入口的显隐依据）
    @State private var retroEligibleCount: Int = 0
    @FocusState private var isValueInputFocused: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 完成反馈动效灰度开关（与系统 Reduce Motion 相与；关闭只影响展示不影响打卡）
    @AppStorage(HoloMotionRollout.completionKey) private var motionEnabled = true
    private var allowsMotion: Bool { motionEnabled && !reduceMotion }

    // MARK: - Body

    var body: some View {
        tileContent
            .padding(14)
            // 撑满磁贴列宽：宽屏下列宽≥240pt，不撑满会缩在列左缘显得稀疏
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .top)
            .background(backgroundLayer)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.tile, style: .continuous)
                    .stroke(borderStroke, lineWidth: 1)
            )
            .shadow(
                color: isCompleted ? doneSurface.opacity(0.30) : .clear,
                radius: 10, x: 0, y: 4
            )
            .contextMenu { menuItems }
            .holoHover()
            .holoRecordArrival(habit.id, domain: .habit, isActive: !showValueInput && !showCheckInNote && !showUndoConfirm)
            .onTapGesture { handlePrimaryAction() }
            .sheet(isPresented: $showValueInput) { valueInputSheet }
            .sheet(isPresented: $showCheckInNote) { checkInNoteSheet }
            .sheet(item: $retroContext) { context in
                HabitRetroactiveSheet(context: context)
            }
            // 挂在磁贴根部（不能挂 measureRow）：长按菜单的「撤销今日最近一笔」
            // 对全部数值类开放，计数类卡片不渲染 measureRow，dialog 必须全场在场
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
            // 与详情页删除确认同用 alert：取消按钮显式渲染（confirmationDialog 在
            // iOS 26 会把 cancel 省略成点外部关闭，两个入口样式需一致）
            .alert("删除“\(deleteTargetName)”？", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    deleteHabit()
                }
            } message: {
                Text("删除后将无法恢复，包括所有记录数据。")
            }
            .onAppear {
                cachedHabitId = habit.id
                loadStatus()
                withAnimation(reduceMotion ? nil : HoloAnimation.enter) {
                    appeared = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { notification in
                if let changedHabitId = notification.object as? UUID, changedHabitId != cachedHabitId {
                    return
                }
                loadStatus()
            }
            .animation(allowsMotion ? HoloAnimation.standard : nil, value: isCompleted)
            .opacity(appeared ? 1 : 0)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: Text("记录\(habit.name)")) { handlePrimaryAction() }
    }

    // MARK: - 磁贴内容（三层：行1 → 副行 → 底部）

    private var tileContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            sublineRow

            Spacer(minLength: 10)

            bottomArea

            // 坏习惯超标提示（3 秒自动消失）：副行已红字，此行作强调
            if showOverLimitWarning {
                Text("已超当日限额，请注意控制")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isCompleted ? .white : .holoError)
                    .padding(.top, 6)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
    }

    /// 行1：图标 chip + 名字（名字独占行，徽章已移副行）+ 右上状态位
    /// 名字给状态位预留尾部安全距离，避免长名贴环/被环叠字
    private var headerRow: some View {
        HStack(spacing: 8) {
            iconChip

            Text(habit.name)
                .holoText(.body)
                .fontWeight(.semibold)
                .foregroundColor(isCompleted ? .white : .holoToolText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 26)
        }
        .frame(minHeight: 32, alignment: .center)
        .overlay(alignment: .topTrailing) { statusSlot }
    }

    /// 图标 chip：32×32 圆角 10。未完成 = 习惯色淡底 + 习惯色图标；
    /// 完成 = 白 26% 底 + 内白描边（emoji 自带颜色直接显示）
    private var iconChip: some View {
        Group {
            if EmojiCatalog.isEmojiIcon(habit.icon) {
                Text(habit.icon).font(.system(size: 17))
            } else {
                habit.iconImage(size: 17)
                    .foregroundColor(isCompleted ? .white : habit.habitColor)
            }
        }
        .frame(width: 32, height: 32)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isCompleted
                      ? Color.white.opacity(0.26)
                      : habit.habitColor.opacity(colorScheme == .dark ? 0.20 : 0.13))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isCompleted ? Color.white.opacity(0.22) : .clear, lineWidth: 1)
        )
    }

    /// 右上状态位：未完成 = 空心灰环（「待办」暗示）；完成 = 盖章（白圆 + 光晕环 + 习惯色勾，微旋转）。
    /// 两态条件渲染而非叠放：未完成时盖章不占位，光晕环不会撑出卡缘被裁
    @ViewBuilder
    private var statusSlot: some View {
        if isCompleted {
            stamp
        } else {
            Circle()
                .strokeBorder(Color.holoToolTextSecondary.opacity(0.45), lineWidth: 1.6)
                .frame(width: 21, height: 21)
        }
    }

    /// 盖章：未完成时放大 1.5 倍且透明，完成瞬间弹入（spring），带 -7° 手盖歪度
    private var stamp: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: 25, height: 25)
                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
            Circle()
                .strokeBorder(Color.white.opacity(0.4), lineWidth: 2)
                .frame(width: 29, height: 29)
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(habit.habitColor)
        }
        .rotationEffect(.degrees(-7))
        .scaleEffect(isCompleted ? 1 : 1.5)
        .opacity(isCompleted ? 1 : 0)
        .animation(allowsMotion ? HoloAnimation.snappy : nil, value: isCompleted)
        .accessibilityLabel(String(localized: "今天已记录"))
    }

    /// 副行：徽章（连续/累计）+ 数据文本（周计/上限）+ 完成后的备注入口
    private var sublineRow: some View {
        // 有徽章（连续/累计）时周计压缩为纯数字，防止三件同排把文本截成残字
        let hasBadge = streakInfo.value > 0 || (lifetimeTotal ?? 0) > 0
        return HStack(spacing: 6) {
            if streakInfo.value > 0 {
                streakBadge
            }
            if let lifetimeTotal, lifetimeTotal > 0, !habit.isBadHabit, habit.isCheckInType {
                lifetimeBadge
            }

            if let subline = sublineText(compactWeekLabel: hasBadge) {
                (subline.0 + subline.1)
                    .font(.system(size: 12))
                    .foregroundColor(isCompleted ? .white.opacity(0.82) : .holoToolTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if isCompleted, habit.isCheckInType {
                noteEntry
            }
        }
        .padding(.top, 8)
    }

    /// 连续天数徽章：橙 tint 胶囊（完成态白 22% 反白）
    private var streakBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "flame.fill").font(.system(size: 9))
            Text("\(streakInfo.value)").font(.system(size: 11, weight: .bold))
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(
            Capsule().fill(isCompleted ? Color.white.opacity(0.22) : Color.holoPrimary.opacity(0.11))
        )
        .foregroundColor(isCompleted ? .white : .holoPrimary)
        .fixedSize()
    }

    /// 累计徽章：习惯色 tint 胶囊（打卡型好习惯专用）
    private var lifetimeBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "infinity").font(.system(size: 9, weight: .bold))
            Text(String(localized: "\(habit.formatValue(lifetimeTotal ?? 0))次"))
                .font(.system(size: 11, weight: .bold))
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(
            Capsule().fill(isCompleted ? Color.white.opacity(0.22) : habit.habitColor.opacity(0.12))
        )
        .foregroundColor(isCompleted ? .white : habit.habitColor)
        .fixedSize()
    }

    /// 打卡型完成后的备注入口：视觉 26×24 笔记图标，热区隐形扩到 44
    private var noteEntry: some View {
        Color.clear
            .frame(width: 44, height: 44)
            .overlay(alignment: .trailing) {
                Image(systemName: "note.text")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 26, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.white.opacity(0.8), lineWidth: 1)
                    )
            }
            .contentShape(Rectangle())
            .onTapGesture {
                checkInNoteText = HabitRepository.shared.findTodayCheckInRecord(for: habit)?.note ?? ""
                showCheckInNote = true
            }
            .accessibilityLabel(String(localized: "编辑今日备注"))
    }

    /// 副行数据文本：打卡型=本周节奏（compact 时省「本周」前缀）；坏习惯=上限与超标
    private var sublineText: ((Text, Text))? { sublineText(compactWeekLabel: false) }

    private func sublineText(compactWeekLabel: Bool) -> (Text, Text)? {
        if habit.isCheckInType {
            let pastDays = weekPattern.dropLast()
            if !pastDays.isEmpty {
                let hits = pastDays.filter { $0 }.count
                return (
                    Text(compactWeekLabel ? "" : String(localized: "本周 ")),
                    Text("\(hits)/\(pastDays.count)")
                        .fontWeight(.bold)
                        .foregroundColor(isCompleted ? .white : .holoPrimary)
                )
            }
            return nil
        }
        if habit.isBadHabit {
            let target = habit.targetValueDouble ?? Double(habit.targetCountValue ?? 0)
            if target > 0 {
                let unit = habit.unitText
                let head = Text(String(localized: "上限 \(habit.formatValue(target))\(unit)/日"))
                guard isOverLimit else { return (head, Text("")) }
                let exceed = (todayValue ?? 0) - target
                let over = Text(String(localized: " · 已超 \(habit.formatValue(exceed))"))
                    .fontWeight(.bold)
                    .foregroundColor(isCompleted ? .white : .holoError)
                return (head, over)
            }
            return nil
        }
        return nil
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

    /// 打卡型：本周点阵（独立底行，补签/备注入口在副行与长按菜单）
    /// 过去完成=习惯色实点 / 漏卡日=淡彩底+加号（点击直达补签）/ 今天=习惯色描边 / 未来=灰空心
    private var weekDots: some View {
        // 周数据缺位（新库/极端时序）兜底为 7 个未完成日，保证「今日描边点」恒在
        let pattern: [Bool] = weekPattern.count == 7 ? weekPattern : Array(repeating: false, count: 7)
        return HStack(spacing: 5) {
            ForEach(0..<7, id: \.self) { day in
                weekDot(day, pattern: pattern)
            }
        }
        .padding(.top, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "本周已记录\(pattern.filter { $0 }.count)天"))
    }

    @ViewBuilder
    private func weekDot(_ day: Int, pattern: [Bool]) -> some View {
        if day < pattern.count - 1 {
            if pattern[day] {
                Circle()
                    .fill(isCompleted ? Color.white.opacity(0.88) : habit.habitColor)
                    .frame(width: 8, height: 8)
            } else {
                // 漏卡日：淡彩点 + 加号，点击直达补签（44pt 主入口仍在长按菜单）
                Color.clear
                    .frame(width: 20, height: 20)
                    .overlay {
                        ZStack {
                            Circle()
                                .fill(isCompleted ? Color.white.opacity(0.30) : habit.habitColor.opacity(0.26))
                            Text("+")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(isCompleted ? .white : habit.habitColor)
                        }
                        .frame(width: 10, height: 10)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        HapticManager.light()
                        retroContext = HabitRetroactiveSheetContext(
                            habit: habit,
                            preselectedDay: weekDayDate(day)
                        )
                    }
            }
        } else if day == pattern.count - 1 {
            Circle()
                .strokeBorder(isCompleted ? Color.white : habit.habitColor, lineWidth: 2)
                .frame(width: 9, height: 9)
        } else {
            Circle()
                .strokeBorder(
                    isCompleted ? Color.white.opacity(0.40) : Color.holoToolTextSecondary.opacity(0.40),
                    lineWidth: 1.5
                )
                .frame(width: 8, height: 8)
        }
    }

    /// weekPattern 下标 → 该日 Date（下标 0 = 本周第一天）
    private func weekDayDate(_ day: Int) -> Date {
        let calendar = Calendar.current
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return calendar.date(byAdding: .day, value: day, to: weekStart) ?? Date()
    }

    // MARK: - 补签入口（点阵漏卡日）

    /// 打卡型：当日记录补/改备注
    private var checkInNoteSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                TextField("备注（可选，如：状态不错）", text: $checkInNoteText)
                    .holoText(.body)
                    .padding(10)
                    .background(Color.holoToolSurface)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                    .onChange(of: checkInNoteText) { _, newValue in
                        if newValue.count > 100 { checkInNoteText = String(newValue.prefix(100)) }
                    }
                Spacer()
            }
            .padding(HoloSpacing.lg)
            .background(Color.holoToolBackground)
            .navigationTitle("打卡备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { showCheckInNote = false }
                        .foregroundColor(.holoToolTextSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { saveCheckInNote() }
                        .holoText(.body)
                        .foregroundColor(.holoPrimary)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func saveCheckInNote() {
        if let record = HabitRepository.shared.findTodayCheckInRecord(for: habit) {
            let trimmed = checkInNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
            try? HabitRepository.shared.updateRecord(record, value: nil, note: trimmed.isEmpty ? nil : trimmed)
        }
        showCheckInNote = false
    }

    /// 计数类：进度行（条 6pt + 圆体数字）+ 按钮行（− 描边 30 / ＋ 实底 37，热区 44）
    /// 「−」仅在今日有记录时出现（手滑多记可直接回退）
    private var countRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if let target = habit.targetValueDouble, target > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(isCompleted ? Color.white.opacity(0.25) : Color.holoToolInset)
                            Capsule()
                                .fill(countAccentColor)
                                .frame(width: geo.size.width * min((todayValue ?? 0) / target, 1))
                        }
                    }
                    .frame(height: 6)
                    .animation(allowsMotion ? HoloAnimation.standard : nil, value: todayValue)
                }

                Text(countText)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(countTextColor)
                    .fixedSize()
            }
            .padding(.top, 2)

            HStack(spacing: 9) {
                Spacer(minLength: 0)

                if (todayValue ?? 0) > 0 {
                    circularButton(
                        systemName: "minus",
                        iconSize: 13,
                        visual: 30,
                        fill: .clear,
                        stroke: isCompleted ? Color.white.opacity(0.55) : habit.habitColor
                    ) {
                        undoLatestRecord()
                    }
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }

                circularButton(
                    systemName: "plus",
                    iconSize: 16,
                    visual: 37,
                    fill: isOverLimit
                          ? Color.holoErrorDark
                          : (isCompleted ? Color.white.opacity(0.28) : habit.habitColor),
                    stroke: .clear
                ) {
                    increment()
                }
            }
            .animation(allowsMotion ? HoloAnimation.standard : nil, value: todayValue)
        }
    }

    /// 圆形操作钮：视觉直径小于 44 时热区仍扩到 44（隐形扩大，不占卡内布局）
    private func circularButton(
        systemName: String,
        iconSize: CGFloat,
        visual: CGFloat,
        fill: Color,
        stroke: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Color.clear
                .frame(width: 44, height: 44)
                .overlay {
                    ZStack {
                        Circle().fill(fill)
                        if stroke != .clear {
                            Circle().strokeBorder(stroke, lineWidth: 1.4)
                        }
                        Image(systemName: systemName)
                            .font(.system(size: iconSize, weight: .bold))
                            .foregroundColor(fill == .clear
                                             ? (isCompleted ? .white : habit.habitColor)
                                             : .white)
                    }
                    .frame(width: visual, height: visual)
                }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
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
        return isCompleted ? .white : .holoToolText
    }

    /// 测量类：值行（当前值 + 单位 + 撤销）+ 整宽「记录」主按钮
    private var measureRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                if let value = todayValue ?? latestHistoricalValue {
                    (Text(habit.formatValue(value))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(measureValueColor)
                     + Text(" \(habit.unitText)")
                        .font(.system(size: 11))
                        .foregroundColor(isCompleted ? .white.opacity(0.75) : .holoToolTextSecondary))
                }

                Spacer(minLength: 0)

                if todayValue != nil {
                    Color.clear
                        .frame(width: 44, height: 36)
                        .overlay(alignment: .trailing) {
                            Text("撤销")
                                .font(.system(size: 12.5))
                                .foregroundColor(isCompleted ? .white.opacity(0.75) : .holoToolTextSecondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { showUndoConfirm = true }
                }
            }

            Button {
                inputValue = ""
                inputNote = ""
                showValueInput = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "pencil.tip.crop.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Text("记录")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    Capsule().fill(isCompleted ? Color.white.opacity(0.28) : habit.habitColor)
                )
            }
            .buttonStyle(.plain)
        }
        .animation(allowsMotion ? HoloAnimation.enter : nil, value: todayValue)
    }

    /// 测量类当前值颜色：超标红（复刻原卡片），点亮后白
    private var measureValueColor: Color {
        if isOverLimit && !isCompleted { return .holoError }
        return isCompleted ? .white : habit.habitColor
    }

    // MARK: - 背景（两态：未完成纸白 / 完成钳制实底 + 光泽）

    /// 完成态底色：习惯色经暖化钳制（压饱和压亮度保白字可读，色相不动）
    private var doneSurface: Color {
        Color.holoHabitSurface(habit.habitColor, scheme: colorScheme)
    }

    /// 描边：未完成 = 暖灰细线；完成 = 浅色无描边（彩影撑形）、深色补习惯色 30%
    private var borderStroke: Color {
        if isCompleted {
            return colorScheme == .dark ? habit.habitColor.opacity(0.30) : .clear
        }
        return .holoToolBorder
    }

    private var backgroundLayer: some View {
        ZStack {
            if isCompleted {
                doneSurface
                // 顶部光泽 + 底部微沉：纸片被点亮的体积感
                LinearGradient(
                    colors: [.white.opacity(0.17), .clear],
                    startPoint: UnitPoint(x: 0.1, y: 0),
                    endPoint: UnitPoint(x: 0.62, y: 0.45)
                )
                LinearGradient(
                    colors: [.black.opacity(0.07), .clear],
                    startPoint: .bottom,
                    endPoint: UnitPoint(x: 0.5, y: 0.72)
                )
            } else {
                Color.holoCardBackground
            }
        }
        .animation(allowsMotion ? HoloAnimation.recordSettle : nil, value: isCompleted)
    }

    // MARK: - 长按菜单

    @ViewBuilder
    private var menuItems: some View {
        Group {
            if habit.isNumericType {
                Button(role: .destructive) {
                    showUndoConfirm = true
                } label: {
                    Label("撤销今日最近一笔", systemImage: "arrow.uturn.backward")
                }

                Divider()
            }

            if retroEligibleCount > 0 {
                Button {
                    retroContext = HabitRetroactiveSheetContext(habit: habit, preselectedDay: nil)
                } label: {
                    Label("补签漏卡", systemImage: "arrow.counterclockwise.circle")
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

            if let onPause {
                Button {
                    onPause()
                } label: {
                    Label("暂停", systemImage: "pause.circle")
                }
            }

            Divider()

            Button(role: .destructive) {
                deleteTargetName = habit.name
                showDeleteConfirm = true
            } label: {
                Label("删除习惯", systemImage: "trash")
            }
        }
    }

    // MARK: - 主操作（点磁贴）

    /// 仅打卡型响应主体点击（勾选/取消对称，误触代价为零）。
    /// 数值类加减/记录只走明确按钮——主体点击若映射 +1，手滑按「−」时会误加。
    private func handlePrimaryAction() {
        guard habit.isCheckInType else { return }
        do {
            let wasCompleted = isCompleted
            let newStatus = try HabitRepository.shared.toggleCheckIn(for: habit)
            if newStatus {
                isCompleted = true
                if !wasCompleted && !habit.isBadHabit {
                    HoloMotionFeedbackCenter.shared.completedHabit(habit.id)
                }
                HapticManager.success()
            } else {
                HoloMotionFeedbackCenter.shared.cancelHabitResponse(habit.id)
                withAnimation(reduceMotion ? nil : HoloAnimation.recordSettle) {
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
            let firstOfToday = (todayValue ?? 0) == 0
            _ = try HabitRepository.shared.incrementCount(for: habit)
            let newValue = HabitRepository.shared.getTodayValue(for: habit)
            // 「有记录即完成」语义：今日第一笔触发点亮
            let becameRecorded = firstOfToday && (newValue ?? 0) > 0
            todayValue = newValue
            if becameRecorded {
                isCompleted = true
                if !habit.isBadHabit { HoloMotionFeedbackCenter.shared.completedHabit(habit.id) }
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

            withAnimation(reduceMotion ? nil : HoloAnimation.standard) {
                self.showOverLimitWarning = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(reduceMotion ? nil : HoloAnimation.standard) {
                    self.showOverLimitWarning = false
                }
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
                            .holoText(.body)
                            .foregroundColor(.holoToolText)

                        Text(habit.unitText.isEmpty ? String(localized: "输入数值") : String(localized: "单位：\(habit.unitText)"))
                            .font(.system(size: 12))
                            .foregroundColor(.holoToolTextSecondary)
                    }

                    Spacer()
                }

                TextField("输入数值", text: $inputValue)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .keyboardType(.decimalPad)
                    .focused($isValueInputFocused)
                    .padding()
                    .background(Color.holoToolSurface)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

                TextField("备注（可选，如：膝盖疼只跑2公里）", text: $inputNote)
                    .holoText(.body)
                    .onSubmit { isValueInputFocused = true }
                    .padding(10)
                    .background(Color.holoToolSurface)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                    .onChange(of: inputNote) { _, newValue in
                        if newValue.count > 100 { inputNote = String(newValue.prefix(100)) }
                    }

                Spacer()
            }
            .padding(HoloSpacing.lg)
            .background(Color.holoToolBackground)
            .navigationTitle("记录数值")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        showValueInput = false
                    }
                    .foregroundColor(.holoToolTextSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveValue()
                    }
                    .holoText(.body)
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

        let note = inputNote.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let firstOfToday = todayValue == nil
            _ = try HabitRepository.shared.addNumericRecord(for: habit, value: value, note: note.isEmpty ? nil : note)
            todayValue = HabitRepository.shared.getTodayValue(for: habit)
            showValueInput = false
            if firstOfToday {
                isCompleted = true
                if !habit.isBadHabit { HoloMotionFeedbackCenter.shared.completedHabit(habit.id) }
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

    // MARK: - 删除（长按菜单）

    private func deleteHabit() {
        do {
            try HabitRepository.shared.deleteHabitById(habit.id)
            HapticManager.light()
        } catch {
            logger.error("删除习惯失败: \(error)")
        }
    }

    private func undoLatestRecord() {
        do {
            let removed = try HabitRepository.shared.removeLatestTodayRecord(for: habit)
            guard removed else { return }
            todayValue = HabitRepository.shared.getTodayValue(for: habit)
            if !habit.isCountType {
                latestHistoricalValue = HabitRepository.shared.getLatestValue(for: habit)
            }
            if (todayValue ?? 0) == 0 {
                HoloMotionFeedbackCenter.shared.cancelHabitResponse(habit.id)
                withAnimation(reduceMotion ? nil : HoloAnimation.recordSettle) {
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
            lifetimeTotal = repo.calculateLifetimeTotal(for: habit)
            // 补签入口依据：最近 7 天可补天数（方法内部会过滤类型/坏习惯/频率）
            retroEligibleCount = repo.retroactiveEligibleDays(for: habit).count
        }
    }
}

/// 磁贴墙 ForEach 的稳定条目：id 在构建时快照成纯值。SwiftUI 过渡帧（如删除
/// 最后一个习惯后 LazyVGrid 析构）会对旧条目重新求 id，直接读 @NSManaged 的
/// Habit.id 在对象已删除时是 nil 强桥接崩溃（2026-09-18 模拟器 SIGTRAP 实锤）
struct HabitTileItem: Identifiable {
    let id: UUID
    let habit: Habit
    let index: Int
}

// MARK: - 今日进度头（磁贴墙公共组件）

/// 橙色单色进度条版式：标题行 + 渐变细条，全部完成时标题切换为点亮文案
struct HabitProgressHeader: View {

    let completed: Int
    let total: Int

    /// 全部完成时摘要卡的暖光（克制的成功氛围，不撒花）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("今日")
                        .font(.system(size: 14))
                        .foregroundColor(.holoToolTextSecondary)
                    Text("\(completed)")
                        .font(.system(size: 33, weight: .heavy, design: .rounded))
                        .foregroundColor(.holoPrimary)
                    Text("/ \(total)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary)
                }

                Spacer()

                Text(subtitle)
                    .font(.system(size: 13, weight: isAllDone ? .semibold : .regular))
                    .foregroundColor(isAllDone ? .holoPrimary : .holoToolTextSecondary)
            }

            // 分段进度条：一段=今日应打卡的一个习惯，完成一段亮一段（比连续条更有计数感）
            HStack(spacing: 3) {
                ForEach(0..<max(total, 1), id: \.self) { index in
                    Capsule()
                        .fill(index < completed ? AnyShapeStyle(segmentGradient) : AnyShapeStyle(Color.holoToolInset))
                        .frame(height: 9)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: completed)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.holoPrimary.opacity(0.05), .clear],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.75)
                    )
                )
                .background(Color.holoToolSurface)
        )
        .shadow(
            color: isAllDone ? Color.holoPrimary.opacity(0.22) : Color.black.opacity(0.04),
            radius: isAllDone ? 14 : 8,
            x: 0, y: isAllDone ? 6 : 2
        )
    }

    private var segmentGradient: LinearGradient {
        LinearGradient(colors: [.holoPrimary, .holoPrimaryDark], startPoint: .leading, endPoint: .trailing)
    }

    private var isAllDone: Bool {
        total > 0 && completed == total
    }

    private var subtitle: String {
        if total == 0 { return "" }
        return isAllDone ? String(localized: "完美的一天 ✨") : String(localized: "还有 \(total - completed) 项待点亮")
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Text("磁贴组件预览（需 Habit 数据）")
            .holoText(.sectionTitle)
    }
    .padding()
    .background(Color.holoToolBackground)
}
