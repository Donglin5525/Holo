//
//  ScheduleSettingsSection.swift
//  Holo
//
//  设置页「日历」区块：总开关 + 权限引导 + 来源日历勾选
//

import SwiftUI
import EventKit

struct ScheduleSettingsSection: View {
    @StateObject private var store = ScheduleStore.shared
    private let syncEngine = ScheduleSyncEngine.shared
    @State private var isRequestingPermission = false

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "calendar")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)

                Text("日历")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Toggle("", isOn: Binding(
                    get: { store.isEnabled },
                    set: { enabled in
                        Task {
                            if enabled {
                                await store.enable()
                            } else {
                                store.disable()
                            }
                        }
                    }
                ))
                .toggleStyle(.switch)
                .tint(.holoPrimary)
                .labelsHidden()
            }

            if store.isEnabled {
                VStack(spacing: 0) {
                    permissionRow

                    if store.authorizationStatus == .fullAccess {
                        Divider().padding(.leading, HoloSpacing.md)

                        // 任务写入日历（二期）
                        taskSyncRow

                        Divider().padding(.leading, HoloSpacing.md)

                        calendarSelectionRows

                        Divider().padding(.leading, HoloSpacing.md)

                        // AI 可读性告知（设计稿：勾选处文案明示，不另设开关）
                        HStack(alignment: .top, spacing: HoloSpacing.sm) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12))
                                .foregroundColor(.holoPrimary)
                                .padding(.top, 2)

                            Text("勾选的日历可在 Holo 中查看；对话与周规划时 AI 也会读取这些日历来安排时间。日程数据仅在本机与当次 AI 请求中使用。")
                                .font(.system(size: 11))
                                .foregroundColor(.holoTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(HoloSpacing.md)
                    }
                }
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            }
        }
        .onAppear {
            store.loadCompletions()
            if store.isEnabled, store.authorizationStatus == .fullAccess {
                store.refreshCalendars()
                Task { await store.reloadActiveWindow() }
            }
        }
    }

    private var taskSyncRow: some View {
        VStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { syncEngine.isTaskSyncEnabled },
                set: { enabled in
                    syncEngine.isTaskSyncEnabled = enabled
                    if enabled {
                        syncEngine.reconcileNow()
                    }
                }
            )) {
                HStack(spacing: HoloSpacing.md) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.holoPrimary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("任务同步到日历")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Text("带时间段的任务自动写入专属「Holo」日历，手表和系统日历可见；改动双向同步")
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .tint(.holoPrimary)
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, 10)
        }
    }

    // MARK: - 权限行

    @ViewBuilder
    private var permissionRow: some View {
        switch store.authorizationStatus {
        case .fullAccess:
            HStack(spacing: HoloSpacing.md) {
                permissionIcon("checkmark.shield.fill", color: .holoSuccess)
                VStack(alignment: .leading, spacing: 2) {
                    Text("日历权限")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text("已授权，可读取日程")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                }
                Spacer()
            }
            .padding(HoloSpacing.md)

        case .notDetermined:
            Button {
                isRequestingPermission = true
                Task {
                    await store.requestAccessAgain()
                    isRequestingPermission = false
                }
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    permissionIcon("hand.raised.fill", color: .holoPrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("申请日历权限")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Text("需要「完全访问」权限以读取日程")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }
                    Spacer()
                    if isRequestingPermission {
                        ProgressView()
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
                .padding(HoloSpacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        case .denied, .restricted:
            Button {
                openSystemSettings()
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    permissionIcon("exclamationmark.shield.fill", color: .holoError)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("日历权限被拒绝")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Text("iOS 不再重复弹窗，点击前往系统设置开启")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12))
                        .foregroundColor(.holoPrimary)
                }
                .padding(HoloSpacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        @unknown default:
            EmptyView()
        }
    }

    private func permissionIcon(_ name: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: HoloRadius.sm)
                .fill(color.opacity(0.1))
                .frame(width: 40, height: 40)
            Image(systemName: name)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(color)
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - 日历勾选

    @ViewBuilder
    private var calendarSelectionRows: some View {
        if store.availableCalendars.isEmpty {
            HStack {
                Text("未找到可用日历")
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
                Spacer()
            }
            .padding(HoloSpacing.md)
        } else {
            VStack(spacing: 0) {
                ForEach(store.availableCalendars) { info in
                    Button {
                        store.toggleCalendarSelection(info.id)
                    } label: {
                        HStack(spacing: HoloSpacing.md) {
                            Circle()
                                .fill(info.color)
                                .frame(width: 10, height: 10)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(info.title)
                                    .font(.holoBody)
                                    .foregroundColor(.holoTextPrimary)
                                if info.isSubscribed {
                                    Text("订阅日历")
                                        .font(.system(size: 11))
                                        .foregroundColor(.holoTextSecondary)
                                }
                            }

                            Spacer()

                            Image(systemName: info.isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18))
                                .foregroundColor(info.isSelected ? .holoPrimary : .holoTextSecondary.opacity(0.5))
                        }
                        .padding(.horizontal, HoloSpacing.md)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if info.id != store.availableCalendars.last?.id {
                        Divider().padding(.leading, HoloSpacing.md)
                    }
                }
            }
        }
    }
}
