//
//  SheetDismissGuard.swift
//  Holo
//
//  卡片(sheet)下拉关闭守卫
//  配合 .interactiveDismissDisabled 使用：用户下拉试图关闭被拦下的瞬间回调 onAttempt，
//  由页面决定后续（保存后 dismiss / 弹未保存确认），替代「无脑禁用导致下拉彻底没反应」。
//
//  原理：interactiveDismissDisabled(true) 会让卡片处于 isModalInPresentation 状态，
//  此时用户下拉得到橡皮筋回弹，UIKit 通过 UIAdaptivePresentationControllerDelegate 的
//  didAttemptToDismiss 告知「用户想关但被拦」——SwiftUI 没有暴露这个回调，这里用
//  UIViewControllerRepresentable 桥接到所属 sheet 的 presentationController 上。
//
//  用法：
//      .interactiveDismissDisabled(hasUnsavedChanges)
//      .sheetDismissGuard { showDismissAlert = true }
//  无改动时手势不被拦、系统直接下拉关闭；有改动时被拦并触发回调。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SheetDismissGuard

struct SheetDismissGuard: UIViewControllerRepresentable {

    /// 用户下拉试图关闭被拦下时触发
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> GuardViewController {
        GuardViewController(onAttempt: onAttempt)
    }

    func updateUIViewController(_ viewController: GuardViewController, context: Context) {
        viewController.onAttempt = onAttempt
    }

    // MARK: - GuardViewController

    /// 常驻在 sheet 内容层级里的轻量 VC，上溯 parent 链找到所属 sheet 的
    /// presentationController 并把自己设为 delegate。
    /// delegate 是 weak，而本 VC 由 SwiftUI hosting 层强持有，生命周期与 sheet 内容一致。
    final class GuardViewController: UIViewController, UIAdaptivePresentationControllerDelegate {

        init(onAttempt: (() -> Void)?) {
            self.onAttempt = onAttempt
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        var onAttempt: (() -> Void)? {
            didSet {
                guard isViewLoaded && view.window != nil else { return }
                bindIfNeeded()
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            bindIfNeeded()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            // sheet 关闭后与 presentationController 解绑，避免残留 delegate
            // 影响同宿主容器下一次呈现的 sheet
            if let controller = parentSheetPresentation, controller.delegate === self {
                controller.delegate = nil
            }
        }

        /// 沿 parent 链上溯到 sheet 根 hosting controller，取其 presentationController
        private var parentSheetPresentation: UIPresentationController? {
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            return root.presentationController
        }

        private func bindIfNeeded() {
            guard let controller = parentSheetPresentation else { return }
            if controller.delegate !== self {
                controller.delegate = self
            }
        }

        // MARK: UIAdaptivePresentationControllerDelegate

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            onAttempt?()
        }
    }
}

// MARK: - View Extension

extension View {
    /// 卡片下拉关闭守卫：用户下拉试图关闭、但被 .interactiveDismissDisabled 拦下时触发 onAttempt。
    /// 必须与 .interactiveDismissDisabled 同用——手势未被拦时系统直接关闭，不会走到回调。
    func sheetDismissGuard(onAttempt: @escaping () -> Void) -> some View {
        background(SheetDismissGuard(onAttempt: onAttempt))
    }
}
