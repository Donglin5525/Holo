//
//  HoloToast.swift
//  Holo
//
//  全局轻量提示（Toast）
//  用于统一处理「写操作失败」「操作完成」等需要给用户即时反馈的场景，
//  替代散落各处的静默 catch / 手写 noticeToast。
//
//  用法（任意位置，一行调用）：
//    HoloToastCenter.shared.show("保存失败，请重试", type: .error)
//
//  展示层基于独立 overlay window，不受 sheet / fullScreenCover 层级影响，
//  调用方无需关心在哪个页面、是否在弹出层内。
//

import SwiftUI
import UIKit
import Combine

// MARK: - HoloToastCenter

/// 全局 Toast 状态中心（单例，任意位置可调用）
final class HoloToastCenter: ObservableObject {

    static let shared = HoloToastCenter()

    /// 当前展示的提示；nil 表示无提示
    @Published var current: ToastMessage? = nil

    private var dismissTask: Task<Void, Never>? = nil

    private init() {}

    /// 展示一条提示
    /// - Parameters:
    ///   - text: 提示文案
    ///   - type: 提示类型（决定图标与配色）
    ///   - duration: 自动消失时长，默认 2.5 秒
    func show(_ text: String, type: ToastType = .info, duration: TimeInterval = 2.5) {
        // 取消上一次的自动消失计时，让新提示完整展示
        dismissTask?.cancel()
        current = ToastMessage(text: text, type: type)

        // 同步触发对应触觉反馈，让用户「感觉到」结果
        switch type {
        case .success: HapticManager.success()
        case .error: HapticManager.error()
        case .warning: HapticManager.warning()
        case .info: HapticManager.light()
        }

        // 确保 overlay window 已挂载
        OverlayWindowController.shared.ensureInstalled()

        let token = current
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, current?.id == token?.id else { return }
            if current?.id == token?.id { current = nil }
        }
    }

    /// 立即清除当前提示
    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

// MARK: - ToastMessage / ToastType

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let type: ToastType
}

/// 提示类型：决定左侧图标与文字配色
enum ToastType: Equatable {
    case info       // 一般提示（灰底）
    case success    // 成功（绿底）
    case warning    // 警告（橙底）
    case error      // 错误（红底）

    var icon: String {
        switch self {
        case .info:    return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info:    return .holoTextSecondary
        case .success: return .holoSuccess
        case .warning: return .holoPrimary
        case .error:   return .holoError
        }
    }
}

// MARK: - Overlay Window（展示层）

/// 用一个独立的、不接收触摸的透明 window 承载 Toast，
/// 保证它永远在最上层，不受 sheet / fullScreenCover / NavigationStack 层级影响。
private final class OverlayWindowController {

    static let shared = OverlayWindowController()

    private var overlayWindow: UIWindow? = nil

    private init() {}

    func ensureInstalled() {
        guard overlayWindow == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        let window = ToastPassthroughWindow(windowScene: scene)
        window.windowLevel = .alert + 1  // 高于系统 alert，确保可见
        window.backgroundColor = .clear
        // 用 hosting controller 承载 SwiftUI 视图，不抢走 key window
        let hostingController = UIHostingController(rootView: ToastOverlayView())
        hostingController.view.backgroundColor = .clear
        window.rootViewController = hostingController
        window.isHidden = false
        overlayWindow = window
    }
}

/// 不拦截触摸的 window：Toast 浮层可见但不影响下层交互
private final class ToastPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 让所有触摸穿透到下层 App 窗口
        guard let view = super.hitTest(point, with: event) else { return nil }
        // 仅当命中 Toast 实体内容时才接收（实际 Toast 不需要交互，这里直接全穿透）
        return view === self ? nil : view
    }
}

/// Toast 展示视图（观察单例，顶层居中靠上）
private struct ToastOverlayView: View {

    @ObservedObject private var center = HoloToastCenter.shared

    var body: some View {
        ZStack(alignment: .top) {
            // 占位：让 ZStack 占满 window，Toast 固定在顶部安全区下。
            // 必须禁用命中测试——否则全屏 Color.clear 会拦截下层所有触摸
            // （ToastPassthroughWindow.hitTest 依赖这里返回 nil 才能穿透）
            Color.clear
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if let message = center.current {
                toastView(message)
                    .padding(.top, HoloSpacing.xl)
                    .padding(.horizontal, HoloSpacing.lg)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.22), value: center.current)
    }

    private func toastView(_ message: ToastMessage) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: message.type.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(message.type.tint)
            Text(message.text)
                .font(.holoCaption)
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm + 2)
        .background(Color.black.opacity(0.78))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}
