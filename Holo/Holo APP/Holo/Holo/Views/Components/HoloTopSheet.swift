//
//  HoloTopSheet.swift
//  Holo
//
//  置顶弹层（2026-11-24 东林实报「开着别的页面时，Plus 页 / 截图记账确认页弹不出来，
//  要关掉当前页面才出来」根治）。
//
//  病根：SwiftUI 的 sheet / fullScreenCover 共用一条呈现通道——屏幕上已经开着一个
//  弹层时，后来的呈现请求被排队，等上面那层关掉才补上；挂载点本身被弹层盖住时，
//  请求直接被丢弃（App 根视图的 fullScreenCover 被 sheet 挡住，表现为按钮点击无响应）。
//  此前的绕法是「先收掉挡路弹层、等半秒再弹」，补丁散落多处且认不全所有页面。
//
//  做法：绕开 SwiftUI 的呈现队列，由 UIKit 从当前窗口最顶层控制器 present。不管底下
//  开着什么，新页面直接盖在最上面；底下的页面原样保留，关掉即回到原处。
//
//  使用边界：只给「不依赖当前页面、必须立刻到达用户面前」的页面（Plus 付费墙、
//  截图记账确认页）；普通业务弹层仍用 .sheet，不要全库替换。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 置顶弹层的呈现形态
enum HoloTopSheetStyle {
    /// 与系统 sheet 一致：iPhone 卡片式、可下滑关闭
    case sheet
    /// 全屏覆盖，不可下滑关闭
    case fullScreen
}

private struct HoloTopSheetCloseKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// 置顶弹层内容的关闭动作，由置顶弹层注入；不在置顶弹层里时为 nil。
    /// 页内关闭按钮用它收起自己（置顶页不是 SwiftUI 呈现的，环境的 dismiss() 管不到）。
    var holoTopSheetClose: (() -> Void)? {
        get { self[HoloTopSheetCloseKey.self] }
        set { self[HoloTopSheetCloseKey.self] = newValue }
    }
}

extension View {
    /// 置顶弹层：`item` 非空时把内容盖在当前窗口最顶层（已开着的 sheet / 全屏页之上），
    /// 收起后回调 `onDismiss`。开着期间 `item` 换值 = 原位换内容（不收不重弹）。
    /// iPad 上呈现为系统默认尺寸的表单弹窗（见 HoloTopSheetPresenter）。
    func holoTopSheet<Item: Identifiable & Equatable, SheetContent: View>(
        item: Binding<Item?>,
        style: HoloTopSheetStyle = .sheet,
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        modifier(HoloTopSheetModifier(
            item: item,
            style: style,
            onDismiss: onDismiss,
            sheetContent: content
        ))
    }
}

private struct HoloTopSheetModifier<Item: Identifiable & Equatable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    let style: HoloTopSheetStyle
    let onDismiss: () -> Void
    @ViewBuilder let sheetContent: (Item) -> SheetContent

    func body(content: Content) -> some View {
        #if canImport(UIKit)
        content.background(HoloTopSheetAnchor(
            item: $item,
            style: style,
            onDismiss: onDismiss,
            sheetContent: sheetContent
        ))
        #else
        // macOS 没有 UIKit 呈现栈，退回普通 sheet
        content.sheet(item: $item, onDismiss: onDismiss) { sheetContent($0) }
        #endif
    }
}

#if canImport(UIKit)
/// 置顶页内容 + 注入的关闭动作（包一层是为了让宿主的视图类型在换内容时保持不变）
struct HoloTopSheetPage<Content: View>: View {
    let content: Content
    let close: () -> Void

    var body: some View {
        content.environment(\.holoTopSheetClose, close)
    }
}

/// 置顶页宿主：任何途径的收起（下滑、页内关闭、程序置空）都经自己的生命周期回报一次
final class HoloTopSheetHost<Content: View>: UIHostingController<Content> {
    /// 收起动画落定后回调（仅真正被收起时；被别的页面盖住不算）
    var onDismissed: (() -> Void)?

    /// 弹出动画已落定（viewDidAppear）。落定前发起的 dismiss 会被 UIKit 丢弃
    private(set) var hasAppeared = false
    private var isDismissRequestedBeforeAppear = false
    private var isDismissing = false

    /// 显式空析构并关闭优化：Xcode 26.3 Release（-O 全模块优化）在 EarlyPerfInliner 内联
    /// 本类自动合成的析构时崩溃（ThrowingTaskGroup<String, String> 类型不匹配，编译器 bug），
    /// 导致 1.2.0 无法归档。无析构逻辑，行为不变；升级 Xcode 后可复验移除。
    @_optimize(none)
    deinit {}

    /// 收起本页；还在弹出动画里就等落定后再收
    func requestDismiss() {
        guard !isBeingDismissed else { return }
        if hasAppeared {
            dismiss(animated: true)
        } else {
            isDismissRequestedBeforeAppear = true
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 交互式下滑中途取消会重新出现，清掉半路的收起标记
        isDismissing = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        if isDismissRequestedBeforeAppear {
            isDismissRequestedBeforeAppear = false
            dismiss(animated: true)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed { isDismissing = true }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isDismissing {
            isDismissing = false
            onDismissed?()
        }
    }
}

/// 承载视图：只为拿「进窗口」这一刻（App 刚启动、首帧之前就排队的请求靠它弹出）；不参与触摸
private final class HoloTopSheetAnchorView: UIView {
    var onMovedToWindow: ((UIWindow?) -> Void)?

    /// 同 HoloTopSheetHost：规避 Xcode 26.3 Release 内联合成析构时的编译器崩溃
    @_optimize(none)
    deinit {}

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onMovedToWindow?(window)
    }
}

private struct HoloTopSheetAnchor<Item: Identifiable & Equatable, SheetContent: View>:
    UIViewControllerRepresentable
{
    @Binding var item: Item?
    let style: HoloTopSheetStyle
    let onDismiss: () -> Void
    @ViewBuilder let sheetContent: (Item) -> SheetContent

    func makeUIViewController(context: Context) -> HoloTopSheetPresenter<Item, SheetContent> {
        HoloTopSheetPresenter()
    }

    func updateUIViewController(
        _ presenter: HoloTopSheetPresenter<Item, SheetContent>,
        context: Context
    ) {
        presenter.sync(
            item: item,
            style: style,
            binding: $item,
            onDismiss: onDismiss,
            content: sheetContent
        )
    }

    static func dismantleUIViewController(
        _ presenter: HoloTopSheetPresenter<Item, SheetContent>,
        coordinator: ()
    ) {
        presenter.abort()
    }
}

/// 置顶弹层的呈现协调器：跟随 SwiftUI 状态在最顶层 present / dismiss 宿主控制器。
final class HoloTopSheetPresenter<Item: Identifiable & Equatable, SheetContent: View>:
    UIViewController
{
    private var binding: Binding<Item?>?
    private var onDismiss: () -> Void = {}
    private var style: HoloTopSheetStyle = .sheet
    private var sheetContent: ((Item) -> SheetContent)?

    /// 正在置顶展示的宿主；nil = 当前没有置顶页
    private(set) var hosted: HoloTopSheetHost<HoloTopSheetPage<SheetContent>>?
    /// 首次进窗口时记下的宿主窗口：被全屏页盖住后本视图不在层级里，view.window 会变 nil
    private weak var ownedWindow: UIWindow?
    /// 等转场落定 / 等进窗口 / 等旧页收起期间暂存的待呈现项；期间被清空即放弃
    private var pendingItem: Item?
    /// 当前这次收起是不是 owner 置空 item 发起的——是的话收起后不回写 item
    /// （收起动画期间 owner 可能已经设了新的一页）
    private var isDismissingByOwner = false

    /// 同 HoloTopSheetHost：规避 Xcode 26.3 Release 内联合成析构时的编译器崩溃
    @_optimize(none)
    deinit {}

    func sync(
        item: Item?,
        style: HoloTopSheetStyle,
        binding: Binding<Item?>,
        onDismiss: @escaping () -> Void,
        content: @escaping (Item) -> SheetContent
    ) {
        self.binding = binding
        self.onDismiss = onDismiss
        self.style = style
        self.sheetContent = content
        if let window = view.window { ownedWindow = window }

        if let item {
            if hosted != nil, isDismissingByOwner {
                // 旧页正在收起（owner 发起）：新页先排着，等它落定（见 handleDismissed）。
                // 用户下滑收起时 owner 并不知情、item 没变，不能把同一页排回去重弹
                pendingItem = item
            } else if let hosted, let page = page(for: item) {
                // 已开着：原位换内容，不收不重弹
                hosted.rootView = page
            } else {
                present(item)
            }
        } else {
            pendingItem = nil
            dismissHosted(byOwner: true)
        }
    }

    override func loadView() {
        let anchorView = HoloTopSheetAnchorView()
        anchorView.isUserInteractionEnabled = false
        anchorView.onMovedToWindow = { [weak self] window in
            guard let window else { return }
            self?.ownedWindow = window
            self?.presentPending()
        }
        view = anchorView
    }

    /// 把排着队的请求弹出来（转场落定 / 进窗口 / 旧页收起后）
    private func presentPending() {
        guard let pending = pendingItem else { return }
        pendingItem = nil
        present(pending)
    }

    private func present(_ item: Item) {
        guard let page = page(for: item) else { return }
        guard let top = topMostViewController() else {
            // 宿主还没进窗口（首帧之前）：等出现后再弹
            pendingItem = item
            return
        }
        if let transition = top.transitionCoordinator, top.isBeingPresented || top.isBeingDismissed {
            // 有转场在飞：转场中 present 会被 UIKit 丢弃——等落定后从新的最顶层再弹
            pendingItem = item
            let queued = transition.animate(alongsideTransition: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.presentPending() }
            }
            if !queued {
                // 没排上（无动画转场刚结束：isBeing 复位比转场收尾晚半拍）：下一拍重新判定
                DispatchQueue.main.async { [weak self] in self?.presentPending() }
            }
            return
        }

        let host = HoloTopSheetHost(rootView: page)
        host.view.backgroundColor = .systemBackground
        host.modalPresentationStyle = style == .sheet ? .pageSheet : .fullScreen
        if style == .sheet,
           (top.view?.window ?? ownedWindow)?.traitCollection.horizontalSizeClass == .regular {
            // iPad：用表单弹窗 + 系统默认尺寸。与旧实现（SwiftUI .sheet + holoSheetWidth(.form)）实测
            // 外观等价——iPad Pro 11 寸上逐元素位置一致（内容列 560 宽居中、弹窗约占屏高一半）。
            // 不能用 pageSheet：iPadOS 26 上会撑到接近全屏，且不理会 preferredContentSize；
            // 也不要手动指定尺寸（实测 560×680 反而被压成 540 宽）。UIHostingController 默认会把
            // 内容理想尺寸报给弹窗（弹性内容一报就是整屏），一并关掉。
            host.modalPresentationStyle = .formSheet
            host.sizingOptions = []
        }
        host.onDismissed = { [weak self, weak host] in
            guard let host else { return }
            self?.handleDismissed(host)
        }
        hosted = host
        top.present(host, animated: true)
    }

    private func page(for item: Item) -> HoloTopSheetPage<SheetContent>? {
        sheetContent.map { content in
            HoloTopSheetPage(content: content(item)) { [weak self] in
                self?.closeFromPage()
            }
        }
    }

    /// 收起当前置顶页；收尾统一在收起动画落定后（handleDismissed）
    private func dismissHosted(byOwner: Bool) {
        guard let host = hosted else { return }
        isDismissingByOwner = byOwner
        host.requestDismiss()
    }

    /// 页内关闭按钮 / 下滑关闭：owner 不知情，收起后要把 item 同步回空
    private func closeFromPage() {
        dismissHosted(byOwner: false)
    }

    /// 收起动画落定：任何关闭途径都汇总到这里——回调 owner，再弹排着队的下一页
    private func handleDismissed(_ host: HoloTopSheetHost<HoloTopSheetPage<SheetContent>>) {
        host.onDismissed = nil
        if hosted === host { hosted = nil }
        let byOwner = isDismissingByOwner
        isDismissingByOwner = false
        if !byOwner { binding?.wrappedValue = nil }
        onDismiss()
        presentPending()
    }

    /// 挂载点被拆（App 根视图销毁）：不再回调，直接收掉
    func abort() {
        pendingItem = nil
        hosted?.onDismissed = nil
        hosted?.dismiss(animated: false)
        hosted = nil
    }

    private func topMostViewController() -> UIViewController? {
        guard var top = (view.window ?? ownedWindow)?.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
#endif
