//
//  SpendingProjectDetailView.swift
//  Holo
//
//  固定支出详情页（订阅 / 分期 / 大件）
//  遵循 Holo 纸本无卡规范：顶部融合主视觉 + 衬线价格与倒计时 + 独立到期提醒配置（撞墙再弹 Plus）
//

import SwiftUI
import CoreData

struct SpendingProjectDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var project: SpendingProject
    let onChanged: () -> Void

    @State private var reminderEnabled: Bool
    @State private var reminderLeadDays: Int32
    @State private var autoGenerate: Bool
    @State private var isPaused: Bool
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false
    @State private var showEditSheet = false
    @State private var showAppearancePicker = false
    @State private var pendingDeletionID: NSManagedObjectID?

    init(project: SpendingProject, onChanged: @escaping () -> Void) {
        self.project = project
        self.onChanged = onChanged
        _reminderEnabled = State(initialValue: project.reminderEnabled)
        _reminderLeadDays = State(initialValue: project.reminderLeadDays)
        _autoGenerate = State(initialValue: project.autoGenerateTransaction)
        _isPaused = State(initialValue: project.isPaused)
    }

    var body: some View {
        Group {
            if project.isDeleted || project.managedObjectContext == nil {
                Color.holoToolBackground
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        heroHeader
                        if project.isRecurring {
                            reminderSection
                            recurringRulesSection
                            pauseActionButton
                        } else {
                            oneOffMetricsSection
                        }
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.holoCaption)
                                .foregroundStyle(Color.holoToolError)
                                .padding(.top, HoloSpacing.md)
                        }
                    }
                    .padding(.horizontal, HoloSpacing.page)
                    .padding(.top, HoloSpacing.sm)
                    .padding(.bottom, 120)
                }
            }
        }
        .background(Color.holoToolBackground)
        .navigationTitle(project.isRecurring ? (project.isInstallment ? String(localized: "分期详情") : String(localized: "订阅详情")) : String(localized: "大件详情"))
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.holoToolBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: HoloToolbarPlacement.topBarTrailing) {
                Button(String(localized: "编辑")) { showEditSheet = true }
                    .foregroundStyle(Color.holoToolAction)
            }
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) { showDeleteConfirmation = true } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .confirmationDialog(
            project.isRecurring
                ? String(localized: "删除这个固定支出项目？已生成的账本流水会保留。")
                : String(localized: "删除这个大件项目？"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deleteProject() }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showEditSheet) {
            if project.isRecurring {
                SpendingProjectEndConditionSheet(project: project) {
                    syncLocalState()
                    onChanged()
                }
            } else {
                SpendingProjectOneOffEditorSheet(project: project) {
                    syncLocalState()
                    onChanged()
                }
            }
        }
        .sheet(isPresented: $showAppearancePicker) {
            SpendingProjectAppearancePicker(
                currentPlacement: SpendingProjectRepository.shared.resolvePrimaryVisual(for: project),
                currentIcon: project.icon
            ) { selection in
                applyAppearanceSelection(selection)
            }
        }
        .onDisappear { performPendingDeletion() }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        VStack(spacing: HoloSpacing.sm) {
            Button {
                showAppearancePicker = true
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    SpendingProjectIconSlot(project: project, size: 64)
                    Image(systemName: "pencil")
                        .holoIconSize(.xs)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .frame(width: 22, height: 22)
                        .background(Color.holoToolSurface)
                        .clipShape(Circle())
                        .overlay {
                            Circle().strokeBorder(Color.holoToolBorder, lineWidth: 0.75)
                        }
                        .offset(x: 4, y: 4)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("更换外观"))

            Text(project.name)
                .font(.holoHeading)
                .foregroundStyle(Color.holoToolText)
                .padding(.top, HoloSpacing.xs)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(NumberFormatter.currency.string(from: project.amount) ?? "¥0")
                    .font(.holoHeroNumber(size: 32))
                    .foregroundStyle(Color.holoToolText)
                    .monospacedDigit()
                if project.isRecurring {
                    Text("/ \(project.resolvedFrequency.shortUnitTitle)")
                        .font(.holoCaption)
                        .foregroundStyle(Color.holoToolTextSecondary)
                }
            }

            if let badge = heroCountdownText {
                Text(badge)
                    .font(.holoLabel)
                    .foregroundStyle(isUrgentDue ? Color.holoToolAction : Color.holoToolTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(isUrgentDue ? Color.holoToolAction.opacity(0.10) : Color.holoToolInset)
                    .clipShape(Capsule())
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.md)
        .overlay(alignment: .bottom) { HoloHairlineDivider() }
    }

    private var isUrgentDue: Bool {
        guard let days = project.daysUntilNextOccurrence() else { return false }
        return days >= 0 && days <= 7
    }

    private var heroCountdownText: String? {
        if !project.isRecurring {
            return String(localized: "已持有 \(project.ownershipElapsedDays) 天 · 日均 \(NumberFormatter.currency.string(from: (project.dailyCost ?? 0) as NSDecimalNumber) ?? "¥0")")
        }
        if isPaused { return String(localized: "已停订") }
        guard project.hasRemainingOccurrences, let next = project.nextOccurrenceDate else {
            return String(localized: "已完成")
        }
        let dateStr = BillDueReminderScheduler.dueDateFormatter.string(from: next)
        if let days = project.daysUntilNextOccurrence() {
            if days == 0 { return String(localized: "今天到期 · \(dateStr)") }
            if days == 1 { return String(localized: "明天到期 · \(dateStr)") }
            if days > 1 { return String(localized: "\(days) 天后到期 · \(dateStr)") }
        }
        return String(localized: "下次扣款 · \(dateStr)")
    }

    // MARK: - 到期提醒区（无前置免费额度标签，撞墙再弹 Plus）

    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HoloSectionHeader("到期提醒")
                .padding(.top, HoloSpacing.lg)
                .padding(.bottom, HoloSpacing.xs)

            HStack {
                Text("续费前提醒我")
                    .font(.holoBody)
                    .foregroundStyle(Color.holoToolText)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { reminderEnabled },
                    set: { handleReminderToggle($0) }
                ))
                .labelsHidden()
                .tint(Color.holoToolAction)
            }
            .frame(minHeight: 46)

            if reminderEnabled {
                HoloHairlineDivider()
                HStack(spacing: HoloSpacing.sm) {
                    ForEach(BillDueReminderScheduler.leadDayOptions, id: \.self) { days in
                        let isSelected = reminderLeadDays == days
                        Button {
                            HapticManager.light()
                            updateReminderLeadDays(days)
                        } label: {
                            Text(leadDayLabel(days))
                                .font(.holoLabel)
                                .foregroundStyle(isSelected ? Color.holoToolAction : Color.holoToolTextSecondary)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(isSelected ? Color.holoToolAction.opacity(0.10) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                                        .strokeBorder(isSelected ? Color.holoToolAction : Color.holoToolBorder, lineWidth: 0.75)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 12)

                notificationPreviewCard
                    .padding(.bottom, HoloSpacing.sm)
            }
            HoloHairlineDivider()
        }
    }

    private var notificationPreviewCard: some View {
        let previewDue = project.nextOccurrenceDate ?? Date()
        let dueDay = Calendar.current.startOfDay(for: previewDue)
        let title = BillDueReminderScheduler.notificationTitle(name: project.name, leadDays: Int(reminderLeadDays))
        let bodyText = BillDueReminderScheduler.notificationBody(
            amount: project.amountDecimal,
            frequency: project.resolvedFrequency,
            dueDay: dueDay,
            autoGenerateTransaction: autoGenerate
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("通知预览")
                    .font(.holoTinyLabel)
                    .foregroundStyle(Color.holoToolTextSecondary)
                Spacer()
                Text(previewTriggerDateText(dueDay: dueDay))
                    .font(.holoTinyLabel)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .monospacedDigit()
            }
            Text(title)
                .font(.holoCaption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.holoToolText)
            Text(bodyText)
                .font(.holoLabel)
                .foregroundStyle(Color.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolInset)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
    }

    // MARK: - 扣款规则区

    private var recurringRulesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HoloSectionHeader("扣款规则")
                .padding(.top, HoloSpacing.lg)
                .padding(.bottom, HoloSpacing.xs)

            HStack {
                Text("到期自动写入账本")
                    .font(.holoBody)
                    .foregroundStyle(Color.holoToolText)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { autoGenerate },
                    set: { handleAutoGenerateToggle($0) }
                ))
                .labelsHidden()
                .tint(Color.holoToolAction)
            }
            .frame(minHeight: 46)
            HoloHairlineDivider()

            detailPropRow(String(localized: "周期"), project.resolvedFrequency.title)
            if let monthly = project.monthlyCommitment, project.resolvedFrequency != .monthly {
                detailPropRow(String(localized: "折合每月"), NumberFormatter.currency.string(from: monthly as NSDecimalNumber) ?? "¥0")
            }
            if project.isInstallment {
                detailPropRow(String(localized: "分期进度"), String(localized: "已还 \(project.occurrencesGenerated) / \(project.maxOccurrences) 期"))
            }
            if let accountId = project.accountId, let account = FinanceRepository.shared.findAccount(by: accountId) {
                detailPropRow(String(localized: "扣款账户"), account.name)
            }
            if let categoryId = project.categoryId, let category = FinanceRepository.shared.findCategory(by: categoryId) {
                detailPropRow(String(localized: "消费分类"), category.name)
            }
            if project.occurrencesGenerated > 0 {
                let totalPaid = project.amountDecimal * Decimal(project.occurrencesGenerated)
                detailPropRow(
                    String(localized: "累计已付"),
                    String(localized: "\(project.occurrencesGenerated) 期 · \(NumberFormatter.currency.string(from: totalPaid as NSDecimalNumber) ?? "¥0")")
                )
            }
        }
    }

    private var pauseActionButton: some View {
        Button {
            togglePause()
        } label: {
            Text(isPaused ? String(localized: "恢复订阅") : String(localized: "停止订阅（保留历史记录）"))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.holoSecondaryFullWidth)
        .padding(.top, HoloSpacing.lg)
    }

    // MARK: - 大件持有区

    private var oneOffMetricsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HoloSectionHeader("持有信息")
                .padding(.top, HoloSpacing.lg)
                .padding(.bottom, HoloSpacing.xs)

            detailPropRow(String(localized: "购买日期"), Self.fullDateFormatter.string(from: project.startDate))
            detailPropRow(String(localized: "已持有天数"), String(localized: "\(project.ownershipElapsedDays) 天"))
            detailPropRow(String(localized: "日均持有成本"), NumberFormatter.currency.string(from: (project.dailyCost ?? 0) as NSDecimalNumber) ?? "¥0")
            if let categoryId = project.categoryId, let category = FinanceRepository.shared.findCategory(by: categoryId) {
                detailPropRow(String(localized: "消费分类"), category.name)
            }

            Text("大件仅用于追踪持有天数与日均成本，不会生成账本流水，也不会重复计入消费或余额。")
                .font(.holoLabel)
                .foregroundStyle(Color.holoToolTextSecondary)
                .padding(.top, HoloSpacing.md)
        }
    }

    private func detailPropRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.holoBody)
                    .foregroundStyle(Color.holoToolTextSecondary)
                Spacer()
                Text(value)
                    .font(.holoBody)
                    .foregroundStyle(Color.holoToolText)
                    .monospacedDigit()
            }
            .frame(minHeight: 46)
            HoloHairlineDivider()
        }
    }

    // MARK: - Actions

    private func handleReminderToggle(_ newValue: Bool) {
        if newValue, !BillDueReminderScheduler.canEnableReminder(for: project) {
            HoloPlusActionCoordinator.shared.requirePlus(context: .subscriptionReminder) {
                await MainActor.run {
                    applyReminderChange(enabled: true, leadDays: reminderLeadDays)
                }
            }
            return
        }
        applyReminderChange(enabled: newValue, leadDays: reminderLeadDays)
    }

    private func applyReminderChange(enabled: Bool, leadDays: Int32) {
        do {
            try SpendingProjectRepository.shared.updateReminder(for: project, enabled: enabled, leadDays: leadDays)
            reminderEnabled = enabled
            reminderLeadDays = leadDays
            if enabled {
                BillDueReminderScheduler.requestAuthorizationIfNeeded()
            }
            BillDueReminderScheduler.shared.refresh()
            onChanged()
        } catch {
            errorMessage = String(localized: "更新提醒失败")
        }
    }

    private func updateReminderLeadDays(_ days: Int32) {
        applyReminderChange(enabled: reminderEnabled, leadDays: days)
    }

    private func handleAutoGenerateToggle(_ newValue: Bool) {
        do {
            try SpendingProjectRepository.shared.updateAutoGenerate(for: project, enabled: newValue)
            autoGenerate = newValue
            onChanged()
        } catch {
            errorMessage = String(localized: "更新自动记账失败")
        }
    }

    private func togglePause() {
        do {
            try SpendingProjectRepository.shared.updatePause(for: project, isPaused: !isPaused)
            isPaused.toggle()
            BillDueReminderScheduler.shared.refresh()
            onChanged()
        } catch {
            errorMessage = String(localized: "更新状态失败")
        }
    }

    private func applyAppearanceSelection(_ selection: SpendingProjectAppearanceSelection) {
        Task { @MainActor in
            do {
                try await SpendingProjectRepository.shared.applyAppearance(selection, for: project)
                onChanged()
            } catch {
                HoloToastCenter.shared.show(String(localized: "外观未能更新，请稍后再试"), type: .error)
            }
        }
    }

    private func syncLocalState() {
        reminderEnabled = project.reminderEnabled
        reminderLeadDays = project.reminderLeadDays
        autoGenerate = project.autoGenerateTransaction
        isPaused = project.isPaused
    }

    private func deleteProject() {
        pendingDeletionID = project.objectID
        dismiss()
    }

    private func performPendingDeletion() {
        guard let projectID = pendingDeletionID else { return }
        pendingDeletionID = nil
        do {
            try SpendingProjectRepository.shared.deleteProject(id: projectID)
            onChanged()
        } catch {
            errorMessage = String(localized: "删除项目失败")
        }
    }

    private func leadDayLabel(_ days: Int32) -> String {
        switch days {
        case 0: return String(localized: "当天")
        default: return String(localized: "提前 \(days) 天")
        }
    }

    private func previewTriggerDateText(dueDay: Date) -> String {
        let time = BillDueReminderScheduler.shared.reminderTime
        let triggerDay = Calendar.current.date(byAdding: .day, value: -Int(reminderLeadDays), to: dueDay) ?? dueDay
        let dateStr = BillDueReminderScheduler.dueDateFormatter.string(from: triggerDay)
        return String(format: "%@ %02d:%02d", dateStr, time.hour, time.minute)
    }

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()
}
