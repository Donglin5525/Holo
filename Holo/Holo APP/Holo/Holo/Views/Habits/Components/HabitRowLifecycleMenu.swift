//
//  HabitRowLifecycleMenu.swift
//  Holo
//
//  今天页习惯行长按菜单（2026-10-18 东林拍板：编辑/暂停/归档/删除一手可达，
//  替代原「长按抬起换序」；排序统一走更多 → 今天列表排序弹层）。
//  动作契约与概览弹层 ··· 菜单同款：暂停按 Plus 权益执行、归档/删除先确认、
//  失败 toast 且状态保持原样（§8）。
//

import SwiftUI

extension View {
    /// 今天页行卡长按菜单：编辑 + 生命周期动作（暂停/恢复、归档/取消归档、删除）
    func habitRowLifecycleMenu(_ row: HabitRowSnapshot,
                               onEdit: @escaping (UUID) -> Void) -> some View {
        modifier(HabitRowLifecycleMenuModifier(row: row, onEdit: onEdit))
    }
}

private struct HabitRowLifecycleMenuModifier: ViewModifier {

    let row: HabitRowSnapshot
    let onEdit: (UUID) -> Void

    /// 暂停弹层目标（Plus 契约确认后置位）
    @State private var pauseTarget: Habit?
    /// 归档/删除确认（文案口径与概览弹层一致）
    @State private var pendingAction: PendingLifecycleAction?

    @ObservedObject private var entitlement = HoloEntitlementState.shared

    private enum PendingLifecycleAction {
        case archive, delete
    }

    private var isConfirmShown: Binding<Bool> {
        Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .contextMenu { menuItems }
            .sheet(item: $pauseTarget) { habit in
                HabitPauseSheet(habit: habit)
            }
            .alert(confirmTitle, isPresented: isConfirmShown, presenting: pendingAction) { _ in
                Button(String(localized: "取消"), role: .cancel) { pendingAction = nil }
                Button(confirmButtonTitle, role: .destructive) {
                    performPending()
                }
            } message: { _ in
                Text(confirmMessage)
            }
    }

    // MARK: 菜单项（条目按生命周期动态出，同概览弹层）

    @ViewBuilder
    private var menuItems: some View {
        Button {
            onEdit(row.id)
        } label: {
            Label(String(localized: "编辑习惯"), systemImage: "pencil")
        }
        Divider()
        switch row.lifecycle {
        case .active:
            Button(action: requestPause) {
                Label(
                    entitlement.isPlusActive
                        ? String(localized: "暂停习惯")
                        : String(localized: "暂停习惯 · Plus"),
                    systemImage: "pause.circle"
                )
            }
            Button {
                pendingAction = .archive
            } label: {
                Label(String(localized: "归档习惯"), systemImage: "archivebox")
            }
        case .paused:
            Button {
                perform { try HabitRepository.shared.resumeHabitById(row.id) }
            } label: {
                Label(String(localized: "恢复习惯"), systemImage: "play.circle")
            }
            Button {
                pendingAction = .archive
            } label: {
                Label(String(localized: "归档习惯"), systemImage: "archivebox")
            }
        case .archived:
            Button {
                perform { try HabitRepository.shared.unarchiveHabitById(row.id) }
            } label: {
                Label(String(localized: "取消归档"), systemImage: "archivebox")
            }
        }
        Divider()
        Button(role: .destructive) {
            pendingAction = .delete
        } label: {
            Label(String(localized: "删除习惯"), systemImage: "trash")
        }
    }

    // MARK: 动作

    /// 暂停按 Plus 权益执行（与设置表单同款契约：真实权益确认后才开弹层）
    private func requestPause() {
        if entitlement.isPlusActive {
            pauseTarget = HabitRepository.shared.findHabit(by: row.id)
        } else {
            HoloPlusActionCoordinator.shared.requirePlus(context: .habitPause) {
                await MainActor.run {
                    pauseTarget = HabitRepository.shared.findHabit(by: row.id)
                }
            }
        }
    }

    /// 生命周期动作：成功就地刷新（habitDataDidChange 广播）；失败 toast 且状态保持原样
    private func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            HoloToastCenter.shared.show(String(localized: "操作没有成功，状态保持原样。请重试。"), type: .info)
        }
    }

    private func performPending() {
        switch pendingAction {
        case .archive:
            perform { try HabitRepository.shared.archiveHabitById(row.id) }
        case .delete:
            perform { try HabitRepository.shared.deleteHabitById(row.id) }
        case nil:
            break
        }
        pendingAction = nil
    }

    // MARK: 确认文案（与概览弹层同口径）

    private var confirmTitle: String {
        pendingAction == .archive
            ? String(localized: "归档这个习惯？")
            : String(localized: "删除这个习惯？")
    }

    private var confirmButtonTitle: String {
        pendingAction == .archive
            ? String(localized: "确认归档")
            : String(localized: "删除习惯与记录")
    }

    private var confirmMessage: String {
        if pendingAction == .archive {
            return String(localized: "归档「\(row.name)」后，它会从今天隐藏，历史记录全部保留。")
        }
        return String(localized: "删除「\(row.name)」及全部记录？这项删除无法恢复。")
    }
}
