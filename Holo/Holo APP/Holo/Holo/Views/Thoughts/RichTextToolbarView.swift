//
//  RichTextToolbarView.swift
//  Holo
//
//  观点模块 - 富文本格式工具栏
//  提供加粗、图片、无序列表、有序列表按钮
//

import SwiftUI

// MARK: - RichTextToolbarView

/// 富文本编辑格式工具栏
struct RichTextToolbarView: View {

    @Binding var pendingAction: MarkdownEditorAction?
    @Binding var formatState: TypingFormatState
    var onAddImage: (() -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HoloSpacing.sm) {
                tagTriggerButton
                referenceTriggerButton
                divider
                boldButton
                imageButton
                divider
                unorderedListButton
                orderedListButton
            }
            .padding(.horizontal, HoloSpacing.xs)
        }
        .padding(.vertical, HoloSpacing.xs)
    }

    // MARK: - 触发按钮

    /// # 标签触发按钮
    private var tagTriggerButton: some View {
        ToolbarButton(icon: "number", label: "标签") {
            pendingAction = .insertTriggerCharacter("#")
        }
    }

    /// @ 引用触发按钮
    private var referenceTriggerButton: some View {
        ToolbarButton(icon: "at", label: "引用") {
            pendingAction = .insertTriggerCharacter("@")
        }
    }

    // MARK: - 格式按钮

    /// 加粗按钮
    private var boldButton: some View {
        ToolbarButton(icon: "bold", label: "加粗", isActive: formatState.isBold) {
            pendingAction = .toggleBold
        }
    }

    /// 图片按钮
    private var imageButton: some View {
        ToolbarButton(icon: "photo", label: "添加图片") {
            onAddImage?()
        }
    }

    /// 无序列表按钮
    private var unorderedListButton: some View {
        ToolbarButton(icon: "list.bullet", label: "无序列表") {
            pendingAction = .insertUnorderedList
        }
    }

    /// 有序列表按钮
    private var orderedListButton: some View {
        ToolbarButton(icon: "list.number", label: "有序列表") {
            pendingAction = .insertOrderedList
        }
    }

    /// 分隔线
    private var divider: some View {
        Rectangle()
            .fill(Color.holoBorder)
            .frame(width: 1, height: 24)
            .padding(.horizontal, 2)
    }
}

// MARK: - ToolbarButton

/// 工具栏按钮组件
private struct ToolbarButton: View {
    let icon: String
    let label: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: {
            HapticManager.light()
            action()
        }) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: isActive ? .bold : .medium))
                    .foregroundColor(isActive ? .holoPrimary : .holoTextPrimary)
                    .frame(width: 36, height: 28)
            }
        }
        .accessibilityLabel(label)
    }
}

// MARK: - RichTextToolbarAccessoryView

/// 作为 UITextView.inputAccessoryView 的纯 UIKit 工具栏。
///
/// 为什么不用 UIHostingController 桥接：
/// Hosting Controller 的尺寸报告与布局在 inputAccessoryView 容器内不可预测
///（safeArea 推移、intrinsicContentSize 报不准），导致吸附位置错、图标错位。
/// 纯 UIKit 下每个元素坐标由 AutoLayout 约束精确写死，是 inputAccessoryView 最标准的用法。
final class RichTextToolbarAccessoryView: UIView {

    /// 按钮点击回调
    var onTag: (() -> Void)?
    var onReference: (() -> Void)?
    var onBold: (() -> Void)?
    var onImage: (() -> Void)?
    var onUnorderedList: (() -> Void)?
    var onOrderedList: (() -> Void)?

    private var buttons: [UIButton] = []
    private var boldButton: UIButton?

    /// 工具栏高度（系统据此在键盘上方留出空间）：顶部 1pt 分隔线 + 按钮区 44pt
    private static let toolbarHeight: CGFloat = 45

    /// 当前格式状态变化时刷新加粗按钮高亮
    var formatState: TypingFormatState = TypingFormatState() {
        didSet { updateBoldHighlight() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    convenience init() {
        self.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: Self.toolbarHeight))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        backgroundColor = UIColor(Color.holoCardBackground)
        translatesAutoresizingMaskIntoConstraints = false

        // 顶部 1pt 分隔线（与键盘视觉分隔）
        let divider = UIView()
        divider.backgroundColor = UIColor(Color.holoBorder)
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        // 按钮容器：横向滚动，居中垂直排列所有按钮
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        // 分隔线钉在顶部
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: scroll.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.heightAnchor)
        ])

        // 构建按钮组（中间插入竖向分隔线）
        let groups: [(icon: String, action: () -> Void, isBold: Bool)] = [
            ("number", { self.onTag?() }, false),
            ("at", { self.onReference?() }, false)
        ]
        let middleGroups: [(icon: String, action: () -> Void, isBold: Bool)] = [
            ("bold", { self.onBold?() }, true),
            ("photo", { self.onImage?() }, false)
        ]
        let lastGroups: [(icon: String, action: () -> Void, isBold: Bool)] = [
            ("list.bullet", { self.onUnorderedList?() }, false),
            ("list.number", { self.onOrderedList?() }, false)
        ]

        for item in groups {
            stack.addArrangedSubview(makeButton(icon: item.icon, action: item.action, isBold: item.isBold))
        }
        stack.addArrangedSubview(makeDivider())
        for item in middleGroups {
            stack.addArrangedSubview(makeButton(icon: item.icon, action: item.action, isBold: item.isBold))
        }
        stack.addArrangedSubview(makeDivider())
        for item in lastGroups {
            stack.addArrangedSubview(makeButton(icon: item.icon, action: item.action, isBold: item.isBold))
        }

        // inputAccessoryView 必需：跟随键盘宽度自适应
        autoresizingMask = .flexibleWidth
    }

    // MARK: - 子元素构造

    /// 按钮：44×44 触摸目标，图标 16pt，居中。非加粗图标 weight=medium，加粗按钮随 formatState 切换 weight。
    private func makeButton(icon: String, action: @escaping () -> Void, isBold: Bool) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let symbol = UIImage(systemName: icon)
        button.setImage(symbol, for: .normal)
        button.tintColor = UIColor(Color.holoTextPrimary)
        button.contentMode = .center
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.addAction(UIAction { _ in
            HapticManager.light()
            action()
        }, for: .touchUpInside)

        if isBold {
            boldButton = button
            updateBoldHighlight()
        }
        buttons.append(button)
        return button
    }

    /// 竖向分隔线：1pt 宽，24pt 高，两侧 2pt 间距
    private func makeDivider() -> UIView {
        let divider = UIView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = UIColor(Color.holoBorder)
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let wrapper = UIView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            divider.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor)
        ])
        return wrapper
    }

    /// 根据当前格式状态刷新加粗按钮的高亮（颜色 + 字重）
    private func updateBoldHighlight() {
        guard let boldButton else { return }
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: formatState.isBold ? .bold : .medium)
        boldButton.setImage(UIImage(systemName: "bold", withConfiguration: config), for: .normal)
        boldButton.tintColor = formatState.isBold ? UIColor(Color.holoPrimary) : UIColor(Color.holoTextPrimary)
    }
}
