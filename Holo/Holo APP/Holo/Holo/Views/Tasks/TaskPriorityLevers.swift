//
//  TaskPriorityLevers.swift
//  Holo
//
//  轻重缓急 P 档滑杆编辑器（2026-10-07 东林拍板紧急分体系）：
//  重要/紧急两根三档滑杆——机械卡位＋弹簧回位＋过档触感（东林要求手感/趣味），
//  紧急分挂在编辑器右上，去向预览随选即时变色。
//  新建任务页展开态与「轻重缓急」编辑弹层共用同一编辑器。
//

import SwiftUI

// MARK: - P 档滑杆（单根）

/// 三档卡位滑杆：滑块永远停在档位上（拖动中也是逐档跳动＝咔哒手感），
/// 松手弹簧回位；特殊态（重要性未判断/紧急度自动）无实心滑块。
struct TaskPriorityLever: View {
    let title: String
    /// 特殊态 chip（重要性=「？」未判断；紧急=「自动」按日期）
    let chipTitle: String
    let chipAccessibilityLabel: String
    let chipActive: Bool
    let onChipTap: () -> Void
    /// 0/1/2 = P3/P2/P1；nil = 特殊态
    @Binding var selectedIndex: Int?
    /// 特殊态下自动折算的幽灵档（仅紧急杆自动态展示）；nil 不显示
    var ghostIndex: Int? = nil
    /// 特殊态是否整体置灰——重要性未判断置灰；紧急自动不置灰（幽灵标即结果）
    var dimsWhenNil: Bool = false

    @State private var dragIndex: Int? = nil
    @State private var isDragging = false

    private var effectiveIndex: Int? { isDragging ? dragIndex : selectedIndex }
    private var isSpecial: Bool { selectedIndex == nil }

    private static let detents: [CGFloat] = [1.0 / 6.0, 0.5, 5.0 / 6.0]
    private static let levelNames = ["P3", "P2", "P1"]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            track
            labels
        }
        .opacity(isSpecial && dimsWhenNil ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.2), value: isSpecial)
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
            Spacer()
            Button {
                HapticManager.selection()
                onChipTap()
            } label: {
                Text(chipTitle)
                    .font(.holoTinyLabel.weight(chipActive ? .semibold : .regular))
                    .foregroundColor(chipActive ? .holoPrimary : .holoTextSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(chipActive ? Color.holoPrimary.opacity(0.10) : Color.holoCardBackground))
                    .overlay(Capsule().strokeBorder(chipActive ? Color.holoPrimary.opacity(0.45) : Color.holoDivider, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(chipAccessibilityLabel))
            .accessibilityAddTraits(chipActive ? [.isSelected] : [])
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                // 凹槽
                Capsule().fill(Color.holoDivider)
                // 墨迹填充：到当前档（P1 升温加重）
                if let index = effectiveIndex {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.holoPrimary.opacity(0.20),
                                    Color.holoPrimary.opacity(index == 2 ? 0.60 : 0.38)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(22, width * Self.detents[index]))
                }
                // 刻度点：走过的档点亮
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(index <= (effectiveIndex ?? -1) ? Color.holoPrimary.opacity(0.85) : Color.holoBorder)
                        .frame(width: 4.5, height: 4.5)
                        .position(x: width * Self.detents[index], y: geo.size.height / 2)
                }
                // 自动折算幽灵标（虚线圆＋小钟）
                if isSpecial, let ghost = ghostIndex {
                    Circle()
                        .strokeBorder(Color.holoPrimary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
                        .frame(width: 19, height: 19)
                        .overlay(
                            Image(systemName: "clock")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(.holoPrimary)
                        )
                        .position(x: width * Self.detents[ghost], y: geo.size.height / 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
                // 实心滑块：拖动中微放大（捏住的实感），松手弹回
                if let index = effectiveIndex {
                    Circle()
                        .fill(Color.holoCardBackground)
                        .overlay(
                            Circle().strokeBorder(
                                index == 2 ? Color.holoPrimary : Color.holoBorder,
                                lineWidth: 2
                            )
                        )
                        .shadow(
                            color: index == 2 ? Color.holoPrimary.opacity(0.35) : .black.opacity(0.12),
                            radius: index == 2 ? 5 : 2.5,
                            y: 1.5
                        )
                        .frame(width: 22, height: 22)
                        .scaleEffect(isDragging ? 1.18 : 1.0)
                        .position(x: width * Self.detents[index], y: geo.size.height / 2)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: effectiveIndex)
            .animation(.spring(response: 0.25, dampingFraction: 0.45), value: isDragging)
            .animation(.easeInOut(duration: 0.2), value: isSpecial)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(1, max(0, value.location.x / width))
                        let index = min(2, max(0, Int((fraction * 2).rounded())))
                        if index != dragIndex {
                            HapticManager.light()   // 咔哒过档
                            dragIndex = index
                        }
                        isDragging = true
                    }
                    .onEnded { _ in
                        isDragging = false
                        if let index = dragIndex {
                            selectedIndex = index
                        }
                        dragIndex = nil
                    }
            )
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(effectiveIndex.map { Self.levelNames[$0] } ?? chipTitle))
        .accessibilityAdjustableAction { direction in
            let current = effectiveIndex ?? 0
            switch direction {
            case .increment:
                selectedIndex = min(2, current + 1)
            case .decrement:
                selectedIndex = max(0, current - 1)
            @unknown default:
                break
            }
        }
    }

    private var labels: some View {
        HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                Button {
                    HapticManager.light()
                    selectedIndex = index
                } label: {
                    Text(Self.levelNames[index])
                        .font(.system(size: 11.5, weight: effectiveIndex == index ? .bold : .regular))
                        .foregroundColor(effectiveIndex == index ? .holoPrimary : .holoTextSecondary)
                        .frame(maxWidth: .infinity)
                        .scaleEffect(effectiveIndex == index ? 1.06 : 1.0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(effectiveIndex == index ? [.isSelected] : [])
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: effectiveIndex)
    }
}

// MARK: - 双杆编辑器（新建页展开态 / 轻重缓急弹层共用）

struct TaskClassificationLeverEditor: View {
    @Binding var importance: TaskImportance
    @Binding var urgencyMode: TaskUrgencyMode
    /// auto 折算依据的有效截止（nil=未设）
    let effectiveDue: Date?

    var now: Date = Date()
    var calendar: Calendar = TaskAnalyticsPeriod.makeCalendar()

    private var previewQuadrant: TaskQuadrant {
        TaskQuadrantResolver.quadrant(
            importance: importance,
            mode: urgencyMode,
            effectiveDue: effectiveDue,
            now: now,
            calendar: calendar
        )
    }

    private var score: Int? {
        TaskQuadrantResolver.urgencyScore(
            importance: importance,
            mode: urgencyMode,
            effectiveDue: effectiveDue,
            now: now,
            calendar: calendar
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            scoreHeader
            HStack(alignment: .top, spacing: HoloSpacing.lg) {
                TaskPriorityLever(
                    title: String(localized: "重要吗"),
                    chipTitle: "？",
                    chipAccessibilityLabel: String(localized: "暂不判断，收进待整理"),
                    chipActive: importance == .unknown,
                    onChipTap: { importance = .unknown },
                    selectedIndex: Binding(
                        get: { importance.leverIndex },
                        set: { index in
                            if let index, let value = TaskImportance(leverIndex: index) {
                                importance = value
                            }
                        }
                    ),
                    dimsWhenNil: true
                )
                TaskPriorityLever(
                    title: String(localized: "有多急"),
                    chipTitle: String(localized: "自动"),
                    chipAccessibilityLabel: String(localized: "按截止日期自动折算"),
                    chipActive: urgencyMode == .auto,
                    onChipTap: { urgencyMode = .auto },
                    selectedIndex: Binding(
                        get: { urgencyMode.leverIndex },
                        set: { index in
                            if let index, let value = TaskUrgencyMode(leverIndex: index) {
                                urgencyMode = value
                            }
                        }
                    ),
                    ghostIndex: TaskQuadrantResolver.urgencyLevel(
                        mode: .auto,
                        effectiveDue: effectiveDue,
                        now: now,
                        calendar: calendar
                    ).leverIndex
                )
            }
            Text(TaskQuadrantResolver.urgencyExplanation(
                mode: urgencyMode,
                effectiveDue: effectiveDue,
                now: now,
                calendar: calendar
            ))
            .font(.holoTinyLabel)
            .foregroundColor(.holoTextSecondary)
            destRow
        }
    }

    private var scoreHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Spacer()
            if let score {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(localized: "紧急分"))
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                    Text("\(score)")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundColor(.holoPrimary)
                    Text("/9")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextPlaceholder)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: score)
            } else {
                Text(String(localized: "紧急分 — · 先判断重要性"))
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }
        }
    }

    private var destRow: some View {
        HStack(spacing: 6) {
            Text(String(localized: "将进入"))
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Text("「\(previewQuadrant.displayTitle)」")
                .font(.holoCaption.weight(.semibold))
                .foregroundColor(previewQuadrant.tintColor)
            Text("· \(previewQuadrant.guidance)")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                .fill(previewQuadrant.backgroundColor)
        )
        .animation(.easeInOut(duration: 0.25), value: previewQuadrant)
    }
}
