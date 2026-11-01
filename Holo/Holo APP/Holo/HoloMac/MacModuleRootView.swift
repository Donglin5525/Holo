//
//  MacModuleRootView.swift
//  HoloMac
//
//  工作台模块根（2026-10-28 任务模块迁移）：承载「想法 | 任务」模块切换。
//
//  - 切换态存 @AppStorage("mac.activeModule")，重启记忆；
//  - MacModuleSwitcher 自包含读写同一 key（两个工作台侧栏各自放置，无需接线）；
//  - ⌘1/⌘2 菜单经 HoloShortcutBus 广播到此消费；
//  - 想法工作台的启动链（AI 整理等）仍在 MacAppRootView 的 .ready 分支，不受切换影响。
//

import SwiftUI

// MARK: - 模块枚举

enum MacWorkspaceModule: String {
    case thoughts
    case tasks
}

// MARK: - 模块根视图

struct MacModuleRootView: View {

    @AppStorage("mac.activeModule") private var activeModuleRaw: String = MacWorkspaceModule.thoughts.rawValue

    private var activeModule: MacWorkspaceModule {
        MacWorkspaceModule(rawValue: activeModuleRaw) ?? .thoughts
    }

    var body: some View {
        // 2026-10-28 崩溃根因实锤：@StateObject 包全局单例（ThoughtTagConvergenceJob/
        // HoloTaskCompletionCoordinator）——视图被 SwiftUI「构建后丢弃」时单例被连带
        // 释放，重建即悬垂 SIGSEGV。已改为 @ObservedObject（对照 iOS 成熟模式）。
        // 模块层因此可以安全地用条件挂载（互斥渲染），工具栏与 ⌘N 快捷键天然
        // 不叠加不冲突——曾用 ZStack 常驻+透明度切换规避崩溃，实测两个工作台的
        // 工具栏按钮与 keyboardShortcut 会同时挂在窗口上（⌘N 弹错面板），弃用。
        Group {
            if activeModule == .thoughts {
                MacThoughtsWorkspaceView()
            } else {
                MacTasksWorkspaceView()
            }
        }
        .onReceive(HoloShortcutBus.shared.$lastEvent) { event in
            guard let event else { return }
            switch event.action {
            case .switchToThoughts:
                activeModuleRaw = MacWorkspaceModule.thoughts.rawValue
            case .switchToTasks:
                activeModuleRaw = MacWorkspaceModule.tasks.rawValue
            default:
                break
            }
        }
    }
}

// MARK: - 侧栏顶部模块切换区

/// 备忘录式模块区：侧栏 List 上方固定两行。自包含——直接读写
/// @AppStorage("mac.activeModule")，想法/任务两个工作台的侧栏各自放置即可。
struct MacModuleSwitcher: View {

    @AppStorage("mac.activeModule") private var activeModuleRaw: String = MacWorkspaceModule.thoughts.rawValue

    private var activeModule: MacWorkspaceModule {
        MacWorkspaceModule(rawValue: activeModuleRaw) ?? .thoughts
    }

    var body: some View {
        VStack(spacing: 2) {
            row(.thoughts, title: String(localized: "想法"), icon: "lightbulb")
            row(.tasks, title: String(localized: "任务"), icon: "checklist")
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func row(_ module: MacWorkspaceModule, title: String, icon: String) -> some View {
        let selected = module == activeModule
        return Button {
            activeModuleRaw = module.rawValue
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.holoPrimary.opacity(0.12) : Color.clear)
            )
            .foregroundColor(selected ? Color.holoPrimaryDark : Color.holoToolTextSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mac.module.\(module.rawValue)")
    }
}
