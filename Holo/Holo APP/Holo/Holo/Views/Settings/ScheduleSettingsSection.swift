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
    @State private var showPicker = false

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

                        // 来源日历勾选收进独立选择页，这里只留汇总入口
                        calendarSummaryRow
                    }
                }
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
                .navigationDestination(isPresented: $showPicker) {
                    CalendarSourcePickerView()
                }
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

    // MARK: - 来源日历汇总入口

    private var calendarSummaryRow: some View {
        Button {
            showPicker = true
        } label: {
            HStack(spacing: HoloSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .fill(Color.blue.opacity(0.1))
                        .frame(width: 40, height: 40)
                    Image(systemName: "eye")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.blue)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("显示的日历")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text("勾选后才在 Holo 展示、供 AI 读取")
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()

                Text("已选 \(store.availableCalendars.filter(\.isSelected).count)/\(store.availableCalendars.count)")
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextSecondary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(HoloSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
