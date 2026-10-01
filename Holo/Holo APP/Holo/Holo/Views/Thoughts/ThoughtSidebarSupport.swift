//
//  ThoughtSidebarSupport.swift
//  Holo
//
//  想法模块侧边栏基础设施（2026-09-24 方案 §5.5-5.10 / §6.5）
//
//  侧栏导航对所有用户开放；相关笔记/洞察等 AI 能力行仍由 SemanticV3
//  独立控制，未上线即隐藏。
//  ThoughtBrowseScope 是浏览范围唯一事实源；置顶与标签树展开是本机导航偏好，
//  首版不跨设备同步（方案 §6.5）。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 侧栏入口

enum ThoughtSidebarRollout {
    /// 保留既有调用点；旧本机灰度设置不再改变导航入口。
    static let isEnabled = true
}

// MARK: - 浏览范围（方案 §6.5：单一事实源）

/// 想法模块的浏览范围。「回看」等能力上线后再加 case，不借 AI 标签或
/// Topic ID 假冒。userTag 携带归一化全路径 key（非叶子词——`工作/想法` 与
/// `生活/想法` 不得因叶段同名被合并）。
enum ThoughtBrowseScope: Equatable, Hashable {
    case all
    case topic(UUID)
    case userTag(pathKey: String)
    case archived

    /// 映射到既有 DrawerNode 通道，复用列表筛选重载链（reloadByDrawer）。
    var drawerNode: DrawerNode? {
        switch self {
        case .all: return nil
        case .topic(let id): return .topic(id)
        case .userTag(let pathKey): return .userTag(pathKey)
        case .archived: return .archived
        }
    }

    /// DrawerNode → Scope 反向构造（侧栏容器桥接旧筛选通道用）。
    /// 旧通道的 aiTag 名 → 归一化全路径；侧栏没有的节点返回 nil（调用方保持现状）。
    init?(from node: DrawerNode) {
        switch node {
        case nil, .allNotes:
            self = .all
        case .topic(let id):
            self = .topic(id)
        case .userTag(let pathKey):
            self = .userTag(pathKey: pathKey)
        case .aiTag(let name):
            self = .userTag(pathKey: ThoughtTagNormalizer.key(ThoughtTagNormalizer.displayPath(name)))
        case .archived:
            self = .archived
        case .unclassified, .aiOrganize:
            return nil
        }
    }
}

// MARK: - 置顶（导航偏好，本机持久化）

struct ThoughtSidebarPin: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case topic, userTag }

    var kind: Kind
    var topicID: UUID?
    var tagPathKey: String?

    var id: String {
        switch kind {
        case .topic: return "topic:\(topicID?.uuidString ?? "")"
        case .userTag: return "tag:\(tagPathKey ?? "")"
        }
    }

    var scope: ThoughtBrowseScope? {
        switch kind {
        case .topic:
            guard let topicID else { return nil }
            return .topic(topicID)
        case .userTag:
            guard let tagPathKey, !tagPathKey.isEmpty else { return nil }
            return .userTag(pathKey: tagPathKey)
        }
    }
}

enum ThoughtSidebarPreference {
    static let pinnedKey = "thoughts.sidebar.pinned"
    static let expandedKey = "thoughts.sidebar.expandedTagPaths"

    static func loadPins() -> [ThoughtSidebarPin] {
        guard let data = UserDefaults.standard.data(forKey: pinnedKey),
              let pins = try? JSONDecoder().decode([ThoughtSidebarPin].self, from: data) else { return [] }
        return pins
    }

    static func savePins(_ pins: [ThoughtSidebarPin]) {
        if let data = try? JSONEncoder().encode(pins) {
            UserDefaults.standard.set(data, forKey: pinnedKey)
        }
    }

    static func loadExpandedTagPaths() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: expandedKey),
              let paths = try? JSONDecoder().decode(Set<String>.self, from: data) else { return [] }
        return paths
    }

    static func saveExpandedTagPaths(_ paths: Set<String>) {
        if let data = try? JSONEncoder().encode(paths) {
            UserDefaults.standard.set(data, forKey: expandedKey)
        }
    }
}

// MARK: - 用户标签树（方案 §5.6：已有斜杠路径按父子关系折叠）

struct ThoughtSidebarTagNode: Identifiable, Equatable {
    var displayName: String
    var fullPathKey: String      // 归一化累计路径 key（含本段）
    var children: [ThoughtSidebarTagNode]

    var id: String { fullPathKey }
}

enum ThoughtSidebarTagTreeBuilder {

    /// 从「用户认可标签名」构建路径树：`工作/想法` → 工作 → 想法。
    /// 名单口径 = manual / inline / confirmedAI（fetchUserRecognizedTagNames），
    /// 未接受的纯 AI 标签不进入侧栏（方案 §5.6）。
    static func build(from displayNames: [String]) -> [ThoughtSidebarTagNode] {
        // 第一遍：全量路径 key → 节点（父节点随子路径先行/后到都会建齐）
        var byKey: [String: ThoughtSidebarTagNode] = [:]
        for name in displayNames {
            let displayPath = ThoughtTagNormalizer.displayPath(name)
            let segments = displayPath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            var pathKey = ""
            for segment in segments {
                pathKey = pathKey.isEmpty
                    ? ThoughtTagNormalizer.key(segment)
                    : pathKey + "/" + ThoughtTagNormalizer.key(segment)
                if byKey[pathKey] == nil {
                    byKey[pathKey] = ThoughtSidebarTagNode(displayName: segment, fullPathKey: pathKey, children: [])
                }
            }
        }

        // 第二遍：按父 key 收集子节点，自根递归组装
        var childrenOf: [String: [ThoughtSidebarTagNode]] = [:]
        for node in byKey.values {
            if let slash = node.fullPathKey.lastIndex(of: "/") {
                let parentKey = String(node.fullPathKey[..<slash])
                childrenOf[parentKey, default: []].append(node)
            }
        }
        func assemble(_ key: String) -> ThoughtSidebarTagNode {
            var node = byKey[key] ?? ThoughtSidebarTagNode(displayName: key, fullPathKey: key, children: [])
            var kids = childrenOf[key] ?? []
            kids.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            node.children = kids.map { assemble($0.fullPathKey) }
            return node
        }
        var roots = byKey.keys
            .filter { !$0.contains("/") }
            .map { assemble($0) }
        roots.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return roots
    }
}

// MARK: - 侧栏关闭手势

/// 侧栏开启时统一识别向左横滑。UIKit pan 与纵向 ScrollView 可同时识别，
/// 方向一旦锁定就不回头，避免标签树滚动时侧栏跟着抖动。
struct SidebarClosePanModifier: ViewModifier {
    let isEnabled: Bool
    let onTranslate: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat) -> Void

    func body(content: Content) -> some View {
        content.overlay {
            SidebarClosePanOverlay(isEnabled: isEnabled, onTranslate: onTranslate, onEnd: onEnd)
        }
    }
}

private struct SidebarClosePanOverlay: UIViewRepresentable {
    let isEnabled: Bool
    let onTranslate: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SidebarClosePanHostView {
        let view = SidebarClosePanHostView()
        view.coordinator = context.coordinator
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false
        context.coordinator.panGesture = pan
        context.coordinator.overlayView = view
        return view
    }

    func updateUIView(_ uiView: SidebarClosePanHostView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.ensureGestureAttached()
        context.coordinator.panGesture?.isEnabled = isEnabled
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SidebarClosePanOverlay
        var panGesture: UIPanGestureRecognizer?
        weak var overlayView: SidebarClosePanHostView?
        // 侧栏关闭只需在 UIKit 确认 pan 后辨别方向；缩短二次等待距离，
        // 让面板从首次明确的左向移动开始跟手。
        private var gestureLock = HorizontalGestureLock(tuning: HorizontalGestureTuning(
            touchSlop: 2,
            horizontalConfirmDistance: 4,
            verticalConfirmDistance: 6,
            directionDominanceRatio: 1.12))
        private var attachRetryCount = 0

        init(_ parent: SidebarClosePanOverlay) { self.parent = parent }

        deinit {
            if let panGesture { panGesture.view?.removeGestureRecognizer(panGesture) }
        }

        func ensureGestureAttached() {
            guard let panGesture else { return }
            guard let window = overlayView?.window else {
                guard attachRetryCount < 5 else { return }
                attachRetryCount += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.ensureGestureAttached()
                }
                return
            }
            if panGesture.view === window { return }
            panGesture.view?.removeGestureRecognizer(panGesture)
            attachRetryCount = 0
            window.addGestureRecognizer(panGesture)
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            switch gesture.state {
            case .began:
                gestureLock.reset()
            case .changed:
                guard gestureLock.update(translation: translation) == .horizontal,
                      translation.x < 0 else { return }
                parent.onTranslate(translation.x)
            case .ended:
                if gestureLock.axis == .horizontal, translation.x < 0 {
                    parent.onEnd(translation.x, gesture.velocity(in: gesture.view).x)
                } else {
                    parent.onEnd(0, 0)
                }
                gestureLock.reset()
            case .cancelled:
                // 已拖到零宽时 SwiftUI 会停用 pan 并触发取消；沿用真实位移结算，
                // 否则零宽侧栏会被误判为未拖动并弹回展开态。
                if gestureLock.axis == .horizontal, translation.x < 0 {
                    parent.onEnd(translation.x, gesture.velocity(in: gesture.view).x)
                } else {
                    parent.onEnd(0, 0)
                }
                gestureLock.reset()
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            guard parent.isEnabled, let overlayView,
                  !HoloWindowGestureGate.isOverlayPresented(overlayView.window) else { return false }
            return overlayView.bounds.contains(touch.location(in: overlayView))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

private final class SidebarClosePanHostView: UIView {
    weak var coordinator: SidebarClosePanOverlay.Coordinator?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { coordinator?.ensureGestureAttached() }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

// MARK: - 侧栏拉出手势（2026-09-26 三段分区：左缘=返回首页 / 中部右滑=拉出标签树 / 侧栏内左滑=收起）

/// 内容区中部右滑把侧栏拉出来。与关闭 pan 同一套地基：window pan +
/// 轴向锁（只认右向）+ 弹层闸门 + 与 ScrollView 并行识别。
/// shouldReceive 三条让位规则：
/// 1. 起手在左缘排除带内（28pt，UIScreenEdgePan 实际响应带约 20pt）→ 让给返回首页手势；
/// 2. 起手在可横向滚动的 UIScrollView 内（筛选 chips 等）→ 让容器自己滚；
///    纵向列表同为 UIScrollView 但不可横滚，不在此列，右滑照常拉出；
/// 3. isEnabled=false（已停靠/有展开卡片/宽屏）不接收。
struct SidebarOpenPanModifier: ViewModifier {
    let isEnabled: Bool
    /// 左缘返回手势的让位带宽（pt）
    var edgeExclusionWidth: CGFloat = 28
    let onTranslate: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat) -> Void

    func body(content: Content) -> some View {
        content.overlay {
            SidebarOpenPanOverlay(
                isEnabled: isEnabled,
                edgeExclusionWidth: edgeExclusionWidth,
                onTranslate: onTranslate,
                onEnd: onEnd)
        }
    }
}

private struct SidebarOpenPanOverlay: UIViewRepresentable {
    let isEnabled: Bool
    let edgeExclusionWidth: CGFloat
    let onTranslate: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SidebarOpenPanHostView {
        let view = SidebarOpenPanHostView()
        view.coordinator = context.coordinator
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false
        context.coordinator.panGesture = pan
        context.coordinator.overlayView = view
        return view
    }

    func updateUIView(_ uiView: SidebarOpenPanHostView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.ensureGestureAttached()
        context.coordinator.panGesture?.isEnabled = isEnabled
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SidebarOpenPanOverlay
        var panGesture: UIPanGestureRecognizer?
        weak var overlayView: SidebarOpenPanHostView?
        private var gestureLock = HorizontalGestureLock()
        private var attachRetryCount = 0

        init(_ parent: SidebarOpenPanOverlay) { self.parent = parent }

        deinit {
            if let panGesture { panGesture.view?.removeGestureRecognizer(panGesture) }
        }

        func ensureGestureAttached() {
            guard let panGesture else { return }
            guard let window = overlayView?.window else {
                guard attachRetryCount < 5 else { return }
                attachRetryCount += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.ensureGestureAttached()
                }
                return
            }
            if panGesture.view === window { return }
            panGesture.view?.removeGestureRecognizer(panGesture)
            attachRetryCount = 0
            window.addGestureRecognizer(panGesture)
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            switch gesture.state {
            case .began:
                gestureLock.reset()
            case .changed:
                guard gestureLock.update(translation: translation) == .horizontal,
                      translation.x > 0 else { return }
                parent.onTranslate(translation.x)
            case .ended:
                if gestureLock.axis == .horizontal, translation.x > 0 {
                    parent.onEnd(translation.x, gesture.velocity(in: gesture.view).x)
                } else {
                    parent.onEnd(0, 0)
                }
                gestureLock.reset()
            case .cancelled:
                parent.onEnd(0, 0)
                gestureLock.reset()
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            guard parent.isEnabled, let overlayView,
                  !HoloWindowGestureGate.isOverlayPresented(overlayView.window) else { return false }
            let location = touch.location(in: overlayView)
            guard overlayView.bounds.contains(location),
                  location.x >= parent.edgeExclusionWidth else { return false }
            return !Self.isInsideHorizontallyScrollableContainer(touch)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        /// 起手点是否落在可横向滚动的 UIScrollView 内（如列表顶部筛选 chips）。
        /// 判据 contentSize 宽于 bounds（可横滚）；纵向列表不满足，右滑仍可拉出侧栏。
        private static func isInsideHorizontallyScrollableContainer(_ touch: UITouch) -> Bool {
            var view = touch.view
            while let v = view {
                if let scrollView = v as? UIScrollView,
                   scrollView.contentSize.width - scrollView.bounds.width > 1 {
                    return true
                }
                view = v.superview
            }
            return false
        }
    }
}

private final class SidebarOpenPanHostView: UIView {
    weak var coordinator: SidebarOpenPanOverlay.Coordinator?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { coordinator?.ensureGestureAttached() }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
