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
    /// 转为任务（整篇转化入口，弹出确认面板）
    var onConvertToTask: (() -> Void)?

    private var formatButton: UIButton?

    /// 与系统键盘附件栏一致的紧凑高度：1pt 发丝线 + 48pt 操作区。
    private static let toolbarHeight: CGFloat = 49

    /// 当前格式状态变化时刷新加粗按钮高亮
    var formatState: TypingFormatState = TypingFormatState() {
        didSet { updateBoldHighlight() }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.toolbarHeight)
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
        backgroundColor = .secondarySystemBackground
        translatesAutoresizingMaskIntoConstraints = false

        // 只保留一条系统发丝线，避免旧版多条竖线造成的“表格工具栏”。
        let divider = UIView()
        divider.backgroundColor = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        // 高频动作直接展示；格式与列表的子动作收进系统菜单。
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .equalSpacing
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // 分隔线钉在顶部
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            stack.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])

        stack.addArrangedSubview(makeButton(icon: "number", label: "标签", action: { self.onTag?() }))
        stack.addArrangedSubview(makeButton(icon: "at", label: "引用想法", action: { self.onReference?() }))
        stack.addArrangedSubview(makeButton(icon: "photo", label: "添加图片", action: { self.onImage?() }))
        stack.addArrangedSubview(makeFormatButton())
        stack.addArrangedSubview(makeListButton())
        stack.addArrangedSubview(makeTaskButton())

        // inputAccessoryView 必需：跟随键盘宽度自适应
        autoresizingMask = .flexibleWidth
    }

    // MARK: - 子元素构造

    /// 普通工具：保持 44pt 左右的可点击区域，但通过统一底色和字号降低“图标墙”感。
    private func makeButton(
        icon: String,
        label: String,
        action: @escaping () -> Void,
        tintColor: UIColor = .label
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: icon,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        )
        configuration.baseForegroundColor = tintColor
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        button.configuration = configuration
        button.accessibilityLabel = label
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.addAction(UIAction { _ in
            HapticManager.light()
            action()
        }, for: .touchUpInside)

        return button
    }

    /// 格式入口复用系统菜单；加粗状态通过入口高亮反馈，不长期占一个独立按钮。
    private func makeFormatButton() -> UIButton {
        let button = makeButton(icon: "textformat", label: "文字格式", action: {})
        button.menu = UIMenu(children: [
            UIAction(title: "加粗", image: UIImage(systemName: "bold")) { _ in
                HapticManager.light()
                self.onBold?()
            }
        ])
        button.showsMenuAsPrimaryAction = true
        formatButton = button
        updateBoldHighlight()
        return button
    }

    /// 列表类型属于同一类低频选择，放进一个系统菜单，减少横向工具数量。
    private func makeListButton() -> UIButton {
        let button = makeButton(icon: "list.bullet", label: "列表", action: {})
        button.menu = UIMenu(children: [
            UIAction(title: "无序列表", image: UIImage(systemName: "list.bullet")) { _ in
                HapticManager.light()
                self.onUnorderedList?()
            },
            UIAction(title: "有序列表", image: UIImage(systemName: "list.number")) { _ in
                HapticManager.light()
                self.onOrderedList?()
            }
        ])
        button.showsMenuAsPrimaryAction = true
        return button
    }

    /// 任务是 Holo 的核心动作，但仍使用标准 44pt 图标按钮，避免大色块抢走编辑焦点。
    private func makeTaskButton() -> UIButton {
        let button = makeButton(
            icon: "checklist",
            label: "转为任务",
            action: { self.onConvertToTask?() },
            tintColor: UIColor(Color.holoPrimary)
        )
        button.accessibilityLabel = "转为任务"
        button.accessibilityHint = "将选中的文字转为任务；未选中文字时提取整篇想法"
        return button
    }

    /// 加粗时仅高亮“格式”入口，菜单展开后仍以文字明确具体动作。
    private func updateBoldHighlight() {
        guard let formatButton else { return }
        var configuration = formatButton.configuration
        configuration?.baseForegroundColor = formatState.isBold
            ? UIColor(Color.holoPrimary)
            : .label
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = formatState.isBold
            ? UIColor(Color.holoPrimary.opacity(0.12))
            : .clear
        background.cornerRadius = 9
        configuration?.background = background
        formatButton.configuration = configuration
    }
}
