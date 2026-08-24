//
//  AppLockManager.swift
//  Holo
//
//  应用锁状态机与验证
//  锁定判定 + FaceID/系统密码验证（.deviceOwnerAuthentication）+ 系统级锁窗口
//
//  显示双通道：
//  1. HoloApp 根部 ZStack 常驻闸门层——冷启动首帧即锁，防内容闪现；
//  2. 独立 UIWindow（层级高于一切 App 内容）——热回时盖住 fullScreenCover/sheet，
//     防止付费墙、CSV 导入预览等系统级浮层绕过锁（方案 §5.3）。
//

import SwiftUI
import UIKit
import Combine
import LocalAuthentication

@MainActor
final class AppLockManager: ObservableObject {

    static let shared = AppLockManager()

    private let settings = AppLockSettings.shared

    // MARK: - Published State

    /// 是否处于锁定状态；冷启动时「开启即锁」，在首帧渲染前同步确定
    @Published private(set) var isLocked: Bool

    /// 后台快照遮罩：App 离开前台时盖住内容，防止多任务切换器看到页面
    @Published private(set) var isShowingPrivacyShield = false

    /// 是否正在等待系统验证回调
    @Published private(set) var isEvaluating = false

    /// 锁屏副文案（按设备生物识别能力）
    private(set) var unlockHint = "使用面容 ID 或手机密码解锁"

    // MARK: - Private State

    /// 最近一次真正进入后台的时刻（下拉控制中心/系统弹窗不会触发）
    private var lastBackgroundedAt: Date?

    /// 本次活跃期间是否进过后台；只有真正「离开过」才在回前台时做锁定判定
    private var hasEnteredBackgroundSinceActive = false

    private var observers: [NSObjectProtocol] = []
    private var lockWindow: UIWindow?

    // MARK: - Init

    private init() {
        // 冷启动必锁：开启即锁，首帧前同步读取，绝不先渲染内容再上锁
        self.isLocked = AppLockSettings.shared.isEnabled

        // 测试宿主：不建窗口、不监听生命周期（守则：勿在测试进程启动业务服务）
        guard !TestHostEnvironment.isHostedByXCTest else { return }

        unlockHint = Self.currentUnlockHint()
        observeLifecycle()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Lifecycle

    private func observeLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleWillResignActive() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleDidEnterBackground() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleDidBecomeActive() }
        })
    }

    /// 即将失去活跃（含下拉控制中心/系统弹窗）：立即上遮罩，赶在系统拍快照之前
    private func handleWillResignActive() {
        guard settings.isEnabled else { return }
        isShowingPrivacyShield = true
        updateWindowVisibility()
    }

    private func handleDidEnterBackground() {
        hasEnteredBackgroundSinceActive = true
        lastBackgroundedAt = Date()
    }

    private func handleDidBecomeActive() {
        isShowingPrivacyShield = false

        // 冷启动/未开启/已锁定时不做宽限判定；锁定态下由锁屏 onAppear 驱动自动验证
        guard settings.isEnabled, !isLocked, hasEnteredBackgroundSinceActive else {
            updateWindowVisibility()
            return
        }
        hasEnteredBackgroundSinceActive = false

        if Self.shouldLock(
            lastBackgroundedAt: lastBackgroundedAt,
            now: Date(),
            grace: settings.graceStyle.seconds
        ) {
            isLocked = true
            updateWindowVisibility()
            attemptUnlock()
            return
        }
        updateWindowVisibility()
    }

    /// 宽限判定纯函数（单测覆盖；时间全部由调用方注入）
    static func shouldLock(lastBackgroundedAt: Date?, now: Date, grace: TimeInterval) -> Bool {
        guard let last = lastBackgroundedAt else { return true }
        return now.timeIntervalSince(last) >= grace
    }

    // MARK: - Unlock

    /// 锁屏视图出现时自动验证一次；幂等（isEvaluating 防重入）
    func lockScreenDidAppear() {
        if isLocked {
            attemptUnlock()
        }
    }

    func attemptUnlock() {
        guard isLocked, !isEvaluating else { return }
        isEvaluating = true

        let context = LAContext()
        let manager = self
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "验证身份以解锁 Holo"
        ) { success, error in
            let laError = error as? LAError
            Task { @MainActor in
                manager.handleUnlockResult(success: success, error: laError)
            }
        }
    }

    private func handleUnlockResult(success: Bool, error: LAError?) {
        isEvaluating = false

        if success {
            isLocked = false
            updateWindowVisibility()
            return
        }

        if error?.code == .passcodeNotSet {
            // 用户开启应用锁后又在系统设置里关闭了设备密码：
            // 设备自身已无保护，继续锁只会把用户关在门外（方案 §4.4：重置并放行）
            settings.isEnabled = false
            isLocked = false
            updateWindowVisibility()
        }
        // 其余（用户取消/验证失败/系统错误）：保持锁定，锁屏按钮可重试，绝不放行
    }

    // MARK: - Enabling（设置页开启前检查与确认验证）

    enum DeviceLockReadiness: Equatable {
        case ready
        case unavailable(message: String)
    }

    func deviceLockReadiness() -> DeviceLockReadiness {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            return .ready
        }
        if (error as? LAError)?.code == .passcodeNotSet {
            return .unavailable(message: "设备未设置锁屏密码，无法开启应用锁。请先在系统设置中为设备设置密码。")
        }
        return .unavailable(message: "当前设备暂时无法使用应用锁：\(error?.localizedDescription ?? "未知原因")")
    }

    /// 开启应用锁前先验证一次，成功才允许开启（当场体验解锁方式）
    func validateForEnabling() async -> Bool {
        let context = LAContext()
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "验证一次以开启应用锁"
            ) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    private static func currentUnlockHint() -> String {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        switch context.biometryType {
        case .faceID:
            return "使用面容 ID 或手机密码解锁"
        case .touchID:
            return "使用触控 ID 或手机密码解锁"
        default:
            return "使用手机密码解锁"
        }
    }

    // MARK: - Lock Window

    private func updateWindowVisibility() {
        let visible = isLocked || isShowingPrivacyShield
        if visible {
            ensureLockWindow()
            lockWindow?.isHidden = false
        } else {
            lockWindow?.isHidden = true
        }
    }

    private func ensureLockWindow() {
        guard lockWindow == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .unattached && $0.activationState != .background })
        else { return }

        let window = UIWindow(windowScene: scene)
        // 高于 alert 层：盖住 App 内一切呈现（fullScreenCover / sheet 都是普通窗口层）
        window.windowLevel = UIWindow.Level.alert + 1
        window.rootViewController = UIHostingController(rootView: AppLockOverlayView())
        lockWindow = window
    }
}
