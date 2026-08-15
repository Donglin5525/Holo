//
//  RichTextToolbarView.swift
//  Holo
//
//  观点模块 - 富文本格式工具栏（UIKit inputAccessoryView）
//  精炼布局：[#] [@] [📷] | [B] [Aa▾] | [≡▾] | [✓]
//  加粗一键直达；斜体/下划线/颜色收进「文字样式」菜单；列表收进「列表」菜单
//

import SwiftUI
import UIKit

// MARK: - RichTextToolbarAccessoryView

/// 作为 UITextView.inputAccessoryView 的纯 UIKit 工具栏。
///
/// 为什么不用 UIHostingController 桥接：
/// Hosting Controller 的尺寸报告与布局在 inputAccessoryView 容器内不可预测
///（safeArea 推移、intrinsicContentSize 报不准），导致吸附位置错、图标错位。
/// 纯 UIKit 下每个元素坐标由 AutoLayout 约束精确写死，是 inputAccessoryView 最标准的用法。
final class RichTextToolbarAccessoryView: UIView, UIGestureRecognizerDelegate {

    // MARK: - 按钮点击回调
    var onTag: (() -> Void)?
    var onReference: (() -> Void)?
    var onBold: (() -> Void)?
    var onItalic: (() -> Void)?
    var onUnderline: (() -> Void)?
    /// 颜色：由文字样式菜单触发浮层，浮层选色后回调实际 hex。
    /// 黑色是普通颜色选项，不再提供“重置颜色”这种特殊状态。
    var onColor: ((String) -> Void)?
    var onImage: (() -> Void)?
    var onUnorderedList: (() -> Void)?
    var onOrderedList: (() -> Void)?
    /// 转为任务（整篇转化入口，弹出确认面板）
    var onConvertToTask: (() -> Void)?

    // MARK: - 视图引用
    private var boldButton: UIButton?
    private var formatMenuButton: UIButton?
    /// 格式入口右下角的颜色指示圆点（当前有颜色时显示）
    private lazy var colorIndicator: UIView = {
        let view = UIView()
        view.layer.cornerRadius = 4.5
        view.layer.borderWidth = 1.5
        view.layer.borderColor = UIColor(Color.holoNestedCardBackground).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    /// 颜色浮层背景（含浮层本体；关闭即移除）
    private var colorPaletteBackdrop: UIView?

    private static let toolbarHeight: CGFloat = 46

    /// 当前格式状态变化时刷新加粗/格式入口高亮与颜色指示
    var formatState: TypingFormatState = TypingFormatState() {
        didSet { updateFormatHighlights() }
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

    // MARK: - 布局

    private func setup() {
        // 工具栏是编辑器的一部分，必须使用不透明背景，避免键盘和编辑器底色透出造成视觉脏乱。
        // 使用独立的不透明嵌套层背景，与白色编辑区拉开边界；不使用毛玻璃或透明度。
        backgroundColor = UIColor(Color.holoNestedCardBackground)
        isOpaque = true
        translatesAutoresizingMaskIntoConstraints = false

        // 顶部发丝线
        let topDivider = UIView()
        topDivider.backgroundColor = UIColor(Color.holoDivider)
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topDivider)

        // 按钮组（居中聚集，带分组分隔线）
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            topDivider.topAnchor.constraint(equalTo: topAnchor),
            topDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 0.5),

            stack.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor)
        ])

        // 组1：内容插入
        stack.addArrangedSubview(makeButton(icon: "number", label: "标签") { [weak self] in self?.onTag?() })
        stack.addArrangedSubview(makeButton(icon: "at", label: "引用想法") { [weak self] in self?.onReference?() })
        stack.addArrangedSubview(makeButton(icon: "photo", label: "添加图片") { [weak self] in self?.onImage?() })
        stack.addArrangedSubview(makeDivider())

        // 组2：文字样式
        let bold = makeButton(icon: "bold", label: "加粗") { [weak self] in self?.onBold?() }
        boldButton = bold
        stack.addArrangedSubview(bold)

        let formatMenu = makeFormatMenuButton()
        formatMenuButton = formatMenu
        stack.addArrangedSubview(formatMenu)
        stack.addArrangedSubview(makeDivider())

        // 组3：列表
        stack.addArrangedSubview(makeListMenuButton())
        stack.addArrangedSubview(makeDivider())

        // 组4：核心动作
        stack.addArrangedSubview(makeTaskButton())

        updateFormatHighlights()

        // inputAccessoryView 必需：跟随键盘宽度自适应
        autoresizingMask = .flexibleWidth
    }

    // MARK: - 子元素构造

    private func makeDivider() -> UIView {
        let divider = UIView()
        divider.backgroundColor = UIColor(Color.holoBorder.opacity(0.6))
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return divider
    }

    /// 普通按钮：44pt 点击区，18pt 图标，普通态用次要文字色
    private func makeButton(
        icon: String,
        label: String,
        tintColor: UIColor = UIColor(Color.holoTextSecondary),
        action: @escaping () -> Void
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
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
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

    /// 文字样式入口（菜单）：斜体 / 下划线 / 文字颜色
    /// 任一格式激活时入口高亮；颜色生效时右下角显示当前色圆点
    private func makeFormatMenuButton() -> UIButton {
        // 不使用 textformat：中文系统下该符号的视觉形态容易被看成“格式”文字。
        // 画笔更明确表达“编辑文字样式”，同时保留无障碍名称。
        let button = makeButton(icon: "paintbrush.pointed", label: "文字样式", action: {})
        button.menu = UIMenu(children: [
            UIAction(title: "斜体", image: UIImage(systemName: "italic")) { [weak self] _ in
                HapticManager.light()
                self?.onItalic?()
            },
            UIAction(title: "下划线", image: UIImage(systemName: "underline")) { [weak self] _ in
                HapticManager.light()
                self?.onUnderline?()
            },
            UIAction(title: "文字颜色", image: UIImage(systemName: "paintpalette")) { [weak self] _ in
                HapticManager.light()
                self?.toggleColorPalette()
            }
        ])
        button.showsMenuAsPrimaryAction = true

        // 颜色指示圆点叠在格式入口右下角
        button.addSubview(colorIndicator)
        NSLayoutConstraint.activate([
            colorIndicator.widthAnchor.constraint(equalToConstant: 9),
            colorIndicator.heightAnchor.constraint(equalToConstant: 9),
            colorIndicator.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -5),
            colorIndicator.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -5)
        ])
        return button
    }

    /// 列表入口（菜单）：无序 / 有序
    private func makeListMenuButton() -> UIButton {
        let button = makeButton(icon: "list.bullet", label: "列表", action: {})
        button.menu = UIMenu(children: [
            UIAction(title: "无序列表", image: UIImage(systemName: "list.bullet")) { [weak self] _ in
                HapticManager.light()
                self?.onUnorderedList?()
            },
            UIAction(title: "有序列表", image: UIImage(systemName: "list.number")) { [weak self] _ in
                HapticManager.light()
                self?.onOrderedList?()
            }
        ])
        button.showsMenuAsPrimaryAction = true
        return button
    }

    /// 转为任务：核心动作，常驻品牌色
    private func makeTaskButton() -> UIButton {
        let button = makeButton(
            icon: "checklist",
            label: "转为任务",
            tintColor: UIColor(Color.holoPrimary)
        ) { [weak self] in
            self?.onConvertToTask?()
        }
        button.accessibilityHint = "将选中的文字转为任务；未选中文字时提取整篇想法"
        return button
    }

    // MARK: - 高亮刷新

    private func updateFormatHighlights() {
        if let boldButton {
            applyHighlight(to: boldButton, active: formatState.isBold)
        }
        if let formatMenuButton {
            applyHighlight(to: formatMenuButton, active: formatState.anyFormatActive)
        }
        if let hex = formatState.colorHex {
            colorIndicator.backgroundColor = UIColor(Color(hex: hex))
            colorIndicator.isHidden = false
        } else {
            colorIndicator.isHidden = true
        }
    }

    /// 高亮单个按钮（品牌色图标 + 浅底）；非激活恢复次要色
    private func applyHighlight(to button: UIButton, active: Bool) {
        guard var configuration = button.configuration else { return }
        configuration.baseForegroundColor = active
            ? UIColor(Color.holoPrimary)
            : UIColor(Color.holoTextSecondary)
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = active
            ? UIColor(Color.holoPrimary.opacity(0.12))
            : .clear
        background.cornerRadius = 9
        configuration.background = background
        button.configuration = configuration
    }

    // MARK: - 颜色浮层

    private func toggleColorPalette() {
        if colorPaletteBackdrop != nil {
            hideColorPalette()
        } else {
            showColorPalette()
        }
    }

    private func showColorPalette() {
        guard let window = self.window, colorPaletteBackdrop == nil else { return }

        // 全屏透明背景：拦截外部点击以关闭
        let backdrop = UIView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(hideColorPalette))
        // 关闭手势只处理面板外的点击，不能抢走色点按钮的 touchUpInside。
        // 否则用户看到面板关闭，却没有任何颜色变化，表现为“选色失效”。
        tap.delegate = self
        tap.cancelsTouchesInView = false
        backdrop.addGestureRecognizer(tap)
        backdrop.backgroundColor = .clear
        window.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: window.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: window.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: window.trailingAnchor)
        ])

        let palette = ColorPalettePopover()
        palette.onPick = { [weak self] hex in
            self?.onColor?(hex)
            self?.hideColorPalette()
        }
        backdrop.addSubview(palette)

        let size = CGSize(width: ColorPalettePopover.preferredWidth, height: ColorPalettePopover.preferredHeight)
        let selfFrame = self.superview?.convert(self.frame, to: window) ?? .zero
        let anchorMidX = (formatMenuButton?.convert((formatMenuButton?.bounds ?? .zero), to: window).midX) ?? selfFrame.midX
        let paletteX = max(12, min(anchorMidX - size.width / 2, window.bounds.width - size.width - 12))
        let paletteY = max(window.safeAreaInsets.top + 8, selfFrame.minY - 8 - size.height)
        palette.frame = CGRect(x: paletteX, y: paletteY, width: size.width, height: size.height)

        colorPaletteBackdrop = backdrop
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // 色点及其内部的视觉圆点都属于面板，交给 UIButton 自己处理。
        guard let palette = colorPaletteBackdrop?.subviews.compactMap({ $0 as? ColorPalettePopover }).first else {
            return true
        }
        return !(touch.view?.isDescendant(of: palette) ?? false)
    }

    @objc private func hideColorPalette() {
        colorPaletteBackdrop?.removeFromSuperview()
        colorPaletteBackdrop = nil
    }
}

// MARK: - ColorPalettePopover

/// 颜色轻量浮层：9 个预设色圆（3×3）。黑色是普通颜色，不提供重置按钮。
/// 锚定在键盘工具栏「文字样式」按钮上方，选色后即关
final class ColorPalettePopover: UIView {

    var onPick: ((String) -> Void)?

    static let preferredWidth: CGFloat = 196
    // 每个色点保留 44pt 触控热区，浮层尺寸随之增加，避免小色点难以点中。
    static let preferredHeight: CGFloat = 176

    /// 预设色（与设计系统一致）
    private static let presetHexes: [String] = [
        "#000000", "#F46D38", "#60A5FA",
        "#22C55E", "#EF4444", "#C084FC",
        "#EC4899", "#10B981", "#8B5CF6"
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    convenience init() {
        self.init(frame: CGRect(x: 0, y: 0, width: Self.preferredWidth, height: Self.preferredHeight))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        // 自定义 UIView 默认不接收触摸；如果不显式打开，点击色点会穿透到全屏遮罩，
        // 结果是面板关闭了，但 onPick 从未触发，用户会误以为颜色功能失效。
        isUserInteractionEnabled = true
        backgroundColor = UIColor(Color.holoCardBackground)
        layer.cornerRadius = 14
        layer.borderWidth = 0.5
        layer.borderColor = UIColor(Color.holoBorder.opacity(0.6)).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 6)

        // 9 色圆 3×3
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)

        let columns = 3
        for rowStart in stride(from: 0, to: Self.presetHexes.count, by: columns) {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            let upper = min(rowStart + columns, Self.presetHexes.count)
            for hex in Self.presetHexes[rowStart..<upper] {
                row.addArrangedSubview(makeSwatch(hex))
            }
            grid.addArrangedSubview(row)
        }

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            grid.centerXAnchor.constraint(equalTo: centerXAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
    }

    private func makeSwatch(_ hex: String) -> UIButton {
        let button = UIButton(type: .system)
        let color = UIColor(Color(hex: hex))
        button.translatesAutoresizingMaskIntoConstraints = false
        // 视觉色点保持 32pt，按钮本身保留 Apple 推荐的 44pt 触控热区。
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let swatch = UIView()
        swatch.translatesAutoresizingMaskIntoConstraints = false
        // 视觉圆点不能成为命中目标，否则会截断父级 UIButton 的 touchUpInside。
        // 触摸统一交给 44pt 的按钮热区处理，保证点到圆点和点到留白都能选色。
        swatch.isUserInteractionEnabled = false
        swatch.layer.cornerRadius = 16
        swatch.backgroundColor = color
        swatch.layer.borderWidth = 1
        swatch.layer.borderColor = UIColor(Color.holoBorder.opacity(0.5)).cgColor
        button.addSubview(swatch)
        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: 32),
            swatch.heightAnchor.constraint(equalToConstant: 32),
            swatch.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            swatch.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        button.addAction(UIAction { [weak self] _ in
            HapticManager.light()
            self?.onPick?(hex)
        }, for: .touchUpInside)
        button.accessibilityLabel = hex == "#000000" ? "黑色" : "颜色 \(hex)"
        return button
    }
}
