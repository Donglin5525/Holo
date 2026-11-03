//
//  MacAppRootView.swift
//  HoloMac
//
//  App 根视图：三态启动（连接中 / 恢复引导 / 工作台）。
//
//  2026-10-27 恢复链崩溃 + 启动假死双修复：
//  - 库加载失败终态不再把恢复页叠在工作台 overlay 上（垂死工作台之上的
//    SwiftUI Button 手势会空指针崩溃），改为根视图二选一；
//  - 恢复链交互按钮全部走 AppKit NSButton（MacRecoveryButton），绕开
//    SwiftUI ButtonGesture 手势管线的崩溃路径；
//  - 连接阶段后台执行 + 45 秒超时：容器目录被系统层挂起时，窗口仍能
//    出现并如实呈现「连接中/超时」，不再无窗口假死。
//

import SwiftUI

struct MacAppRootView: View {

    /// 启动三态
    private enum LaunchPhase {
        case connecting
        case failed(String)
        case ready
    }

    @State private var phase: LaunchPhase = .connecting
    /// 恢复页 → 重拉流程页（CloudRepullView 弹层即启动）
    @State private var showRepull = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch phase {
            case .connecting:
                connectingView
            case .failed(let message):
                MacStoreRecoveryOverlay(
                    failureText: message,
                    cloudRepullAvailable: CloudKitRuntimeAvailability.isAvailable,
                    onRepull: { showRepull = true })
                    .sheet(isPresented: $showRepull, onDismiss: {
                        // 重拉完成/中断回根：重检库状态（重建成功则进工作台）
                        checkStoreState(resetFirst: false)
                    }) {
                        MacRepullConfirmHost()
                    }
            case .ready:
                HoloMacApp.makeWorkspaceRoot()
                    .task {
                        await HoloMacApp.runOrganizationStartup()
                    }
                    .onChange(of: scenePhase) { _, phase in
                        guard phase == .active else { return }
                        // 与 iOS 回前台同链：pending 队列续做 + 语义对账续跑（均幂等）
                        ThoughtOrganizationQueue.shared.appWillEnterForeground()
                        Task {
                            await ThoughtSemanticChangeFeed.shared.reconcileAllThoughts()
                            await ThoughtSemanticPipeline.shared.kickQueue()
                        }
                    }
            }
        }
        .task {
            checkStoreState(resetFirst: true)
        }
    }

    // MARK: - 连接中

    private var connectingView: some View {
        VStack(spacing: HoloSpacing.lg) {
            ProgressView()
                .controlSize(.large)
            Text("正在连接本地数据库…")
                .foregroundColor(.holoToolTextSecondary)
            Text("如果长时间停留在此页面，通常是 iCloud 或系统容器服务暂时不可用，稍后重启应用即可恢复；你的数据不会因此丢失。")
                .font(.system(size: 11))
                .foregroundColor(.holoToolTextSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.holoBackground)
    }

    // MARK: - 状态检查（后台执行 + 超时保护）

    /// 后台做容器加载与终态判定。prepareIfNeeded / waitUntilReady 在容器目录
    /// 被系统层挂起时可能长时间不返回——45 秒超时后如实显示超时提示，
    /// 绝不让主线程和窗口被拖死。
    private func checkStoreState(resetFirst: Bool) {
        if resetFirst {
            phase = .connecting
        }
        Task { @MainActor in
            // 返回 (装载错误, 是否超时)：装载先完成→(错误或 nil, false)；45 秒先到→(超时错误, true)
            let outcome = await withTaskGroup(
                of: (error: Error?, timedOut: Bool).self) { group in
                group.addTask {
                    CoreDataStack.shared.prepareIfNeeded()
                    await CoreDataStack.shared.waitUntilReady()
                    return (CoreDataStack.shared.storeLoadError(), false)
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(45))
                    return (StoreCheckTimeout(), true)
                }
                guard let first = await group.next() else { return (nil as Error?, false) }
                group.cancelAll()
                return first
            }
            if outcome.1 {
                phase = .failed(outcome.0?.localizedDescription ?? "连接超时")
            } else if let error = outcome.0 {
                phase = .failed(error.localizedDescription)
            } else {
                phase = .ready
            }
        }
    }

    private struct StoreCheckTimeout: LocalizedError {
        var errorDescription: String? {
            String(localized: "连接本地数据库超时")
        }
    }
}

/// 重拉确认宿主：AppKit 按钮（绕开 SwiftUI ButtonGesture 崩溃）+ 确认后承载
/// CloudRepullView（弹层即启动）。确认文案与 iOS 同口径。
private struct MacRepullConfirmHost: View {

    @State private var confirmed = false

    var body: some View {
        Group {
            if confirmed {
                CloudRepullView()
                    .frame(minWidth: 520, minHeight: 640)
                    .task {
                        await CloudRepullService.shared.start()
                    }
            } else {
                VStack(spacing: HoloSpacing.lg) {
                    Image(systemName: "arrow.triangle.2.circlepath.icloud")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(.holoPrimary)
                    Text("从 iCloud 重新拉取全部数据")
                        .font(.system(size: 17, weight: .semibold))
                    Text("本机当前数据将被删除，并用 iCloud 云端数据完整替换。开始前会自动备份本机数据，完成后可一键恢复。此过程需要保持网络连接，可能需要几分钟，期间不建议使用其他功能。")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, HoloSpacing.lg)
                    MacRecoveryButton(title: String(localized: "确认重新拉取")) {
                        confirmed = true
                    }
                    .padding(.top, HoloSpacing.sm)
                }
                .frame(minWidth: 520, minHeight: 420)
            }
        }
    }
}

/// AppKit 按钮（macOS 恢复链专用）：NSButton 不经过 SwiftUI ButtonGesture
/// 手势管线，规避 2026-10-27 的 MainActor assumeIsolated 空指针崩溃。
struct MacRecoveryButton: NSViewRepresentable {

    let title: String
    var bezelColor: NSColor? = nil
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator,
                              action: #selector(Coordinator.fire))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        if let bezelColor {
            button.bezelColor = bezelColor
            button.contentTintColor = .white
        }
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.title = title
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) {
            self.action = action
        }
        @objc func fire() {
            action()
        }
    }
}
