//
//  KeyboardAvoidanceDisabler.swift
//  Holo
//
//  禁用 UIHostingController 的系统键盘避让
//
//  背景：iOS 17 的 SwiftUI 键盘避让对「不在 ScrollView 内的聚焦 TextField」会直接
//  平移整个 hosting view（不是通过 safeArea 调整），.ignoresSafeArea(.keyboard)
//  在这种场景下不可靠（Apple 论坛 658432 多年未修）。本组件通过 UIKit 层的
//  UIHostingController.safeAreaRegions（iOS 16.4+）从根源关闭键盘避让，
//  让「顶部搜索框 + 底部键盘」这种互不重叠的布局纹丝不动。
//
//  影响范围：HomeView 常驻层（ZStack 叠放的所有模块 + 模块内 push 的页面）
//  共用同一个 root hosting controller，本组件挂 HomeView 即对它们统一生效。
//  sheet / fullScreenCover 有独立的 hosting controller，不受影响，仍保留系统避让。

import SwiftUI
import UIKit

/// 在 hosting controller 上禁用键盘 safe area 区域（保留容器安全区）
/// 通过 UIViewRepresentable 把自己插入视图层级，再沿响应链找到所属 UIHostingController。
/// 注意：Swift 泛型不协变，UIHostingController<具体View> 不能 as? 成 UIHostingController<AnyView>，
/// 这里用 Mirror 反射拿到实例后按 UIKit 公开属性赋值（safeAreaRegions 是公开 API）。
struct KeyboardAvoidanceDisabler: UIViewRepresentable {

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        // 视图挂载进层级后，沿响应链向上找所属 hosting controller
        DispatchQueue.main.async { [weak view] in
            guard let hosting = view?.findHostingController() else { return }
            // 默认是 [.container, .keyboard]；去掉 .keyboard 即关闭键盘避让
            hosting.safeAreaRegions = .container
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

extension UIView {
    /// 沿视图层级向上查找 UIHostingController（用运行时类名识别，规避泛型不协变问题）
    func findHostingController() -> (UIViewController & HostingControllerAccess)? {
        var responder: UIResponder? = next
        while let current = responder {
            if let vc = current as? UIViewController,
               vc.isHostingController {
                return vc as? (UIViewController & HostingControllerAccess)
            }
            responder = current.next
        }
        return nil
    }
}

/// 暴露 UIHostingController 的 safeAreaRegions 访问器
/// （协议约束 + 运行时类型检查：UIHostingController 在 iOS 16.4+ 满足此协议）
@available(iOS 16.4, *)
protocol HostingControllerAccess: UIViewController {
    var safeAreaRegions: SafeAreaRegions { get set }
}

extension UIHostingController: HostingControllerAccess {}

extension UIViewController {
    /// 是否为 UIHostingController 的任何具体泛型实例
    fileprivate var isHostingController: Bool {
        String(describing: type(of: self)).contains("UIHostingController")
    }
}

// MARK: - View 扩展

extension View {
    /// 关闭所在 hosting controller 的系统键盘避让（对顶部搜索框等布局有效）
    func disableKeyboardAvoidance() -> some View {
        background(KeyboardAvoidanceDisabler())
    }
}
