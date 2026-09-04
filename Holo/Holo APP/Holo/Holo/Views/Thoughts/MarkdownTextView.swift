//
//  MarkdownTextView.swift
//  Holo
//
//  观点模块 - Markdown 编辑器
//  编辑态使用富文本渲染，保存时再序列化回 markdown 文本
//

import SwiftUI
import UIKit

// MARK: - MarkdownEditorAction

/// 编辑器格式化动作
enum MarkdownEditorAction: Equatable {
    case toggleBold
    case toggleItalic
    case toggleUnderline
    /// 设置文字颜色；黑色也是普通颜色，不通过“清除颜色”表达
    case setColor(hex: String)
    case insertUnorderedList
    case insertOrderedList
    case insertText(String)
    /// 工具栏 #/@ 按钮：原文插入触发字符并进入搜索态
    case insertTriggerCharacter(String)
    /// 候选面板选中标签：触发区间整体替换为标签 Token
    case insertTagToken(id: UUID, displayPath: String)
    /// 候选面板选中想法：触发区间整体替换为引用 Token
    case insertReferenceToken(id: UUID, displayText: String, snapshot: String)
    /// 选中文字转任务后，在选区末尾插入轻量「任务」关系 Token，并保留真实作用范围
    case insertTaskMark(taskId: UUID, displayText: String, sourceRange: NSRange)
    /// 整篇提取多个任务：按原文范围批量插入关系 Token，保证每个任务都能回看作用文字
    case insertTaskMarks([TaskMarkInsertion])
    /// 工具栏「转为任务」：编辑器内读取当前选区——有选中文字只转选中部分，无选中转整篇
    case convertToTask
    /// 把当前选中的 Token 转为普通文本（移除标签 / 取消引用）
    case removeSelectedToken
    /// 主动关闭候选面板（保留已输入文字，本次触发不再自动弹出）
    case dismissSuggestion
}

/// 任务关系标记的待插入数据。sourceRange 相对于插入前的编辑器可见文本。
struct TaskMarkInsertion: Equatable {
    let taskId: UUID
    let displayText: String
    let sourceRange: NSRange
}

/// 候选面板的硬件键盘操作；没有候选面板时不拦截编辑器原生按键。
enum SuggestionKeyboardCommand: Equatable {
    case moveSelection(offset: Int)
    case commitSelection
    case dismiss
}

/// 编辑器内部复制载荷：系统剪贴板展示纯文本，Holo 编辑器之间额外恢复结构化节点。
fileprivate struct SemanticClipboardPayload {
    let data: Data
    let plainText: String
}

// MARK: - TypingFormatState

/// 当前光标处的格式状态，用于工具栏按钮高亮反馈
struct TypingFormatState: Equatable {
    var isBold: Bool = false
    var isItalic: Bool = false
    var isUnderline: Bool = false
    /// 当前光标处文字颜色（nil = 无颜色）
    var colorHex: String? = nil

    /// 是否有任一格式处于激活态（工具栏「格式」入口据此高亮）
    var anyFormatActive: Bool {
        isBold || isItalic || isUnderline || colorHex != nil
    }
}

// MARK: - MarkdownTextView

/// 支持 Markdown 编辑的文本视图
/// 编辑时展示富文本效果，底层仍使用 markdown 字符串存储
struct MarkdownTextView: UIViewRepresentable {

    @Environment(\.sizeCategory) private var sizeCategory

    /// Holo 编辑器内部剪贴板类型；对外仍保留系统纯文本/富文本数据，避免跨应用粘贴受影响。
    fileprivate static let semanticPasteboardType = "com.holo.thoughts.rich-content"

    @Binding var text: String
    @Binding var pendingAction: MarkdownEditorAction?
    /// 动态高度绑定，由视图自动计算并报告给父视图
    @Binding var dynamicHeight: CGFloat
    /// 当前光标处的格式状态，用于工具栏按钮高亮反馈
    @Binding var formatState: TypingFormatState
    /// 当前 #/@ 触发上下文（候选面板数据源，nil=关闭面板）
    @Binding var triggerContext: EditorTriggerContext?
    /// 当前被选中的 Token（点按 Token 后展示操作菜单）
    @Binding var selectedToken: HoloContentNode?
    /// 当前光标在编辑器视图内的 rect（编辑器局部坐标空间）
    /// 触发时由父视图读取，把候选浮层吸附到光标上方；不触发时为 .zero
    @Binding var caretRect: CGRect

    /// 是否启用富文本渲染
    var showHighlight: Bool = true
    /// 新建想法时自动进入输入状态；编辑已有想法不自动弹键盘，先保证阅读连续性。
    var autoFocus: Bool = false
    /// UIKit 文本容器内边距，便于外层悬浮按钮预留空间
    var textContainerInset: UIEdgeInsets = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
    /// 编辑已有想法时的结构化内容（恢复 Token；nil=纯文本）
    var initialRichJSON: String? = nil
    /// 空内容占位提示（在 UITextView 内渲染，避免中文输入法组字阶段与 content 绑定不同步导致重叠）
    var placeholder: String? = nil
    /// 节点模型变化回调（保存时取 richContentJSON 用）
    var onNodesChange: (([HoloContentNode]) -> Void)? = nil
    /// 键盘工具栏「转为任务」回调：整篇转化入口
    var onConvertToTask: (() -> Void)? = nil
    /// 选区菜单「转为任务」回调：同时传出选中的纯文本和真实 UTF-16 选区
    var onConvertSelection: ((String, NSRange) -> Void)? = nil
    /// 候选面板硬件键盘操作回调
    var onSuggestionCommand: ((SuggestionKeyboardCommand) -> Void)? = nil
    /// 候选面板打开时接管 Escape；有条目时再接管方向键和回车。
    var suggestionKeyboardEnabled: Bool = false
    /// 候选面板当前是否有可供方向键/回车操作的条目；没有条目时仍保留 Escape 关闭面板。
    var suggestionKeyboardHasItems: Bool = false

    /// 编辑态和阅读态共用同一种 UITextView 构造方式。
    static func makeTaskAwareTextView() -> UITextView {
        UITextView(frame: .zero)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = SelfSizingTextView(frame: .zero)
        textView.delegate = context.coordinator
        let coordinator = context.coordinator
        textView.onSemanticCopy = { [weak textView, weak coordinator] range in
            guard let textView else { return nil }
            return coordinator?.semanticClipboardPayload(in: textView, range: range)
        }
        textView.onSemanticPaste = { [weak textView, weak coordinator] data in
            guard let textView else { return false }
            return coordinator?.pasteSemanticContent(data, in: textView) ?? false
        }
        textView.onPlainTextPaste = { [weak textView, weak coordinator] string in
            guard let textView else { return false }
            return coordinator?.pastePlainText(string, in: textView) ?? false
        }
        textView.onSuggestionCommand = { [weak coordinator] command in
            coordinator?.onSuggestionCommand?(command)
        }
        textView.suggestionKeyboardEnabled = suggestionKeyboardEnabled
        textView.suggestionKeyboardHasItems = suggestionKeyboardHasItems
        textView.font = Self.baseFont
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = Self.baseTextColor
        textView.backgroundColor = .clear
        textView.textContainerInset = textContainerInset
        // 与阅读态保持同一条横向基线；默认 5pt lineFragmentPadding 会让编辑态额外向内缩进。
        textView.textContainer.lineFragmentPadding = 0
        // 始终保持 UITextView 的滚动能力，避免输入期间反复切换 isScrollEnabled 造成光标跳动；
        // 内容高度由 SelfSizingTextView 上报给外层 SwiftUI frame 管理。
        textView.isScrollEnabled = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsEditingTextAttributes = true
        textView.autocorrectionType = .default
        textView.spellCheckingType = .default
        textView.keyboardType = .default
        // 长文时实际滚动由 UITextView 承担；键盘收起也必须挂在同一个滚动容器上，
        // 否则外层 SwiftUI ScrollView 收不到拖拽，用户只能点完成或额外点击空白处。
        textView.keyboardDismissMode = .interactive
        // 禁用系统「自动填充」与 Writing Tools：不走 canPerformAction 过滤，需单独关闭，
        // 否则点按 Token 时会与自定义 Token 菜单重叠弹出
        if #available(iOS 18.0, *) {
            textView.writingToolsBehavior = .none
        }
        textView.inputAssistantItem.leadingBarButtonGroups = []
        textView.inputAssistantItem.trailingBarButtonGroups = []
        textView.typingAttributes = Self.baseAttributes
        // 关闭 iOS 17+ 非编辑态自动滚动到可见区域：避免候选浮层出现时编辑器意外上滚
        textView.alwaysBounceVertical = false
        let initialNodes = RichContentSerializer.nodes(richJSON: initialRichJSON, fallbackPlainText: text)
        let initialAttributedText = showHighlight
            ? Self.makeAttributedText(from: initialNodes)
            : NSAttributedString(string: text, attributes: Self.baseAttributes)
        textView.attributedText = Self.applyingEditorLineSpacing(to: initialAttributedText)

        // 以节点派生文本为准，保证 JSON 场景下绑定与编辑器内容一致。
        // 存量引用可能通过快照补齐标题，必须同步回 Binding；否则 SwiftUI 下一次刷新
        // 会拿旧的纯文本重建富文本，把刚恢复的 Token 再次降级成普通「@」。
        let initialMarkdown = text
        let canonicalMarkdown = RichContentSerializer.plainText(from: initialNodes)
        if initialRichJSON != nil, canonicalMarkdown != initialMarkdown {
            context.coordinator.setBoundText(canonicalMarkdown)
            context.coordinator.pendingCanonicalMarkdown = canonicalMarkdown
            context.coordinator.staleMarkdownBeforeCanonicalSync = initialMarkdown
        }
        context.coordinator.lastKnownMarkdown = canonicalMarkdown
        context.coordinator.lastAppliedRichJSON = initialRichJSON
        context.coordinator.lastAppliedSizeCategory = sizeCategory
        context.coordinator.nodes = initialNodes
        context.coordinator.onNodesChange = onNodesChange
        context.coordinator.onConvertSelection = onConvertSelection
        context.coordinator.onConvertToTask = onConvertToTask
        context.coordinator.onSuggestionCommand = onSuggestionCommand
        context.coordinator.updateAccessibilityValue(in: textView)
        context.coordinator.onHeightChange = { height in
            DispatchQueue.main.async {
                self.dynamicHeight = height
            }
        }
        context.coordinator.onFormatStateChange = { state in
            DispatchQueue.main.async {
                self.formatState = state
            }
        }
        context.coordinator.onCaretRectChange = { rect in
            DispatchQueue.main.async {
                self.caretRect = rect
            }
        }
        context.coordinator.refreshTypingAttributes(for: textView)

        // 工具栏已从 inputAccessoryView 迁到编辑器卡片内部（SwiftUI，见 EditorFormatToolbar）；
        // 所有工具动作统一走 pendingAction(MarkdownEditorAction) 管线，此处不再挂键盘附属条。

        // 占位提示：在 UITextView 内渲染，依据 attributedText 实时显隐（含 IME 组字阶段）
        if let placeholder {
            let label = UILabel()
            label.text = placeholder
            label.font = Self.baseFont
            label.textColor = UIColor(Color.holoTextPlaceholder)
            label.numberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isUserInteractionEnabled = false
            textView.addSubview(label)
            // 对齐文字起始：textContainerInset + textContainer 默认 lineFragmentPadding
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: textView.topAnchor, constant: textContainerInset.top),
                label.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: textContainerInset.left + textView.textContainer.lineFragmentPadding)
            ])
            context.coordinator.placeholderLabel = label
        }
        context.coordinator.updatePlaceholderVisibility(in: textView)

        if autoFocus {
            // makeUIView 返回时 SwiftUI 可能尚未把 UITextView 挂入窗口，交给 UIKit
            // 的 didMoveToWindow 在真正可交互后聚焦，避免新建入口“看起来打开了但不能直接打字”。
            textView.autoFocusWhenAttached = true
        }

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // 同步可能变化的闭包引用（父视图重建时保持最新）
        context.coordinator.onConvertSelection = onConvertSelection
        context.coordinator.onConvertToTask = onConvertToTask
        context.coordinator.onSuggestionCommand = onSuggestionCommand

        // makeUIView 中由 rich JSON 派生出的规范文本写回 Binding 后，SwiftUI 可能先把
        // 创建时的旧纯文本快照回传一次。只忽略这一个已知旧值，避免 Token 被降级；
        // 如果值已经不是旧快照，说明是用户或宿主真正改过的内容，继续正常处理。
        if let pendingCanonicalMarkdown = context.coordinator.pendingCanonicalMarkdown {
            if text == pendingCanonicalMarkdown {
                context.coordinator.pendingCanonicalMarkdown = nil
                context.coordinator.staleMarkdownBeforeCanonicalSync = nil
            } else if text == context.coordinator.staleMarkdownBeforeCanonicalSync {
                context.coordinator.setBoundText(pendingCanonicalMarkdown)
                context.coordinator.lastKnownMarkdown = pendingCanonicalMarkdown
                context.coordinator.pendingCanonicalMarkdown = nil
                context.coordinator.staleMarkdownBeforeCanonicalSync = nil
                return
            } else {
                context.coordinator.pendingCanonicalMarkdown = nil
                context.coordinator.staleMarkdownBeforeCanonicalSync = nil
            }
        }

        if let textView = textView as? SelfSizingTextView {
            textView.suggestionKeyboardEnabled = suggestionKeyboardEnabled
            textView.suggestionKeyboardHasItems = suggestionKeyboardHasItems
        }
        if let action = pendingAction {
            pendingAction = nil
            context.coordinator.perform(action: action, on: textView, markdown: $text)
            return
        }

        // 富文本中的 UIFont 不会因为 UITextView.adjustsFontForContentSizeCategory 自动逐段重建；
        // 监听 SwiftUI 的字号环境，按当前节点重新生成，保证编辑态和阅读态的 Dynamic Type 真正生效。
        if context.coordinator.lastAppliedSizeCategory != sizeCategory {
            let currentNodes = context.coordinator.nodes
            let preservedSelection = Self.clampedRange(textView.selectedRange, for: textView.attributedText.length)
            let attributedText = Self.applyingEditorLineSpacing(to: showHighlight
                ? Self.makeAttributedText(from: currentNodes)
                : NSAttributedString(string: RichContentSerializer.plainText(from: currentNodes), attributes: Self.baseAttributes))
            context.coordinator.isProgrammaticChange = true
            textView.attributedText = attributedText
            textView.selectedRange = Self.clampedRange(preservedSelection, for: attributedText.length)
            context.coordinator.isProgrammaticChange = false
            context.coordinator.lastAppliedSizeCategory = sizeCategory
            context.coordinator.refreshTypingAttributes(for: textView)
            context.coordinator.updatePlaceholderVisibility(in: textView)
            context.coordinator.updateAccessibilityValue(in: textView)
            return
        }

        // 编辑器可能先于编辑数据创建：此时会以纯文本初始化，随后 richContentJSON
        // 才异步到达。必须重新水合结构化节点，否则 @/任务看似有颜色，实际却已失去
        // Token 身份，点按会被误判为普通文字或新的 @ 触发器。
        if initialRichJSON != context.coordinator.lastAppliedRichJSON {
            let previousMarkdown = context.coordinator.lastKnownMarkdown
            let newNodes = RichContentSerializer.nodes(richJSON: initialRichJSON, fallbackPlainText: text)
            let preservedSelection = Self.clampedRange(textView.selectedRange, for: textView.attributedText.length)
            let attributedText = Self.applyingEditorLineSpacing(to: showHighlight
                ? Self.makeAttributedText(from: newNodes)
                : NSAttributedString(string: RichContentSerializer.plainText(from: newNodes), attributes: Self.baseAttributes))

            context.coordinator.isProgrammaticChange = true
            textView.attributedText = attributedText
            textView.selectedRange = Self.clampedRange(preservedSelection, for: attributedText.length)
            context.coordinator.isProgrammaticChange = false
            context.coordinator.lastAppliedRichJSON = initialRichJSON
            let canonicalMarkdown = RichContentSerializer.plainText(from: newNodes)
            if context.coordinator.boundText == previousMarkdown {
                context.coordinator.setBoundText(canonicalMarkdown)
            }
            context.coordinator.lastKnownMarkdown = canonicalMarkdown
            context.coordinator.nodes = newNodes
            context.coordinator.onNodesChange?(newNodes)
            context.coordinator.refreshTypingAttributes(for: textView)
            context.coordinator.updatePlaceholderVisibility(in: textView)
            context.coordinator.updateAccessibilityValue(in: textView)
            return
        }

        if !context.coordinator.isProgrammaticChange,
           textView.markedTextRange == nil,
           text != context.coordinator.lastKnownMarkdown {
            let preservedSelection = Self.clampedRange(textView.selectedRange, for: textView.attributedText.length)
            let newNodes = RichContentSerializer.nodes(fromPlainText: text)
            let attributedText = Self.applyingEditorLineSpacing(to: showHighlight
                ? Self.makeAttributedText(from: newNodes)
                : NSAttributedString(string: text, attributes: Self.baseAttributes))
            context.coordinator.isProgrammaticChange = true
            textView.attributedText = attributedText
            textView.selectedRange = Self.clampedRange(preservedSelection, for: attributedText.length)
            context.coordinator.isProgrammaticChange = false
            context.coordinator.lastKnownMarkdown = text
            context.coordinator.nodes = newNodes
            context.coordinator.refreshTypingAttributes(for: textView)
        }
        context.coordinator.updatePlaceholderVisibility(in: textView)
        context.coordinator.updateAccessibilityValue(in: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, triggerContext: $triggerContext, selectedToken: $selectedToken)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        @Binding var triggerContext: EditorTriggerContext?
        @Binding var selectedToken: HoloContentNode?

        var isProgrammaticChange = false
        var lastKnownMarkdown: String = ""
        /// 首次从 rich JSON 水合时，等待 SwiftUI 完成 Binding 回写；期间屏蔽一次旧纯文本快照。
        var pendingCanonicalMarkdown: String?
        var staleMarkdownBeforeCanonicalSync: String?
        /// 编辑期结构化内容模型（事实源）：文本变化时由富文本属性重建，Token 节点不被重渲染销毁
        var nodes: [HoloContentNode] = []
        /// 最近一次应用到 UITextView 的结构化 JSON；用于处理异步初始数据到达
        var lastAppliedRichJSON: String? = nil
        /// 最近一次把富文本按哪个 Dynamic Type 档位渲染
        var lastAppliedSizeCategory: ContentSizeCategory?
        var onHeightChange: ((CGFloat) -> Void)?
        var onFormatStateChange: ((TypingFormatState) -> Void)?
        var onNodesChange: (([HoloContentNode]) -> Void)?
        /// 光标 rect 变化回调（编辑器局部坐标系），父视图据此吸附候选浮层
        var onCaretRectChange: ((CGRect) -> Void)?
    /// 选区菜单「转为任务」回调
    /// 连同真实选区一起传出，避免确认面板呈现期间 UITextView 选区丢失
    var onConvertSelection: ((String, NSRange) -> Void)?
    /// 工具栏「转为任务」（整篇）回调
    var onConvertToTask: (() -> Void)?
    /// 候选面板硬件键盘操作回调
    var onSuggestionCommand: ((SuggestionKeyboardCommand) -> Void)?

        /// 占位提示标签（makeUIView 创建，依据编辑器内容实时显隐）
        weak var placeholderLabel: UILabel?

        /// 刷新占位提示显隐：编辑器有任何文字（含 IME 组字阶段）即隐藏
        func updatePlaceholderVisibility(in textView: UITextView) {
            placeholderLabel?.isHidden = textView.attributedText.length > 0
        }

        /// 当前活跃的 #/@ 触发（候选面板打开期间非空）
        private var activeTrigger: EditorTriggerContext?
        /// 最近一次点按的完整 Token 区间。点按后光标会吸附到 Token 边缘，不能再依赖 selectedRange 找回它。
        private var selectedTokenRange: NSRange?
        /// 上次选区位置（区分点按 vs 键盘移动光标）
        private var lastSelectionLocation: Int = 0
        /// 已发布的触发状态（避免重复写绑定触发 SwiftUI 刷新）
        private var lastPublishedTrigger: EditorTriggerContext?
        /// 被用户手动关闭的触发起点（同一触发片段内不再自动弹出面板）
        private var suppressedTriggerLocation: Int?

        // 用户显式切换的格式状态（Word-like sticky toggle）
        // nil = 无显式状态，走 contextual 推断；非 nil = 强制覆盖 contextual
        var explicitBold: Bool? = nil
        var explicitItalic: Bool? = nil
        var explicitUnderline: Bool? = nil
        /// 用户显式设置的文字颜色（sticky；nil = 无显式颜色）
        var explicitColorHex: String? = nil

        init(text: Binding<String>, triggerContext: Binding<EditorTriggerContext?>, selectedToken: Binding<HoloContentNode?>) {
            self._text = text
            self._triggerContext = triggerContext
            self._selectedToken = selectedToken
        }

        /// 把结构化节点派生出的规范文本写回 SwiftUI，避免通过普通 String 快照绕过绑定。
        func setBoundText(_ value: String) {
            text = value
        }

        var boundText: String {
            text
        }

        func textViewDidChange(_ textView: UITextView) {
            // 占位提示依据 attributedText 实时刷新，必须在 markedText guard 之前：
            // 中文输入法组字阶段 markedTextRange != nil，content 绑定尚未更新，
            // 但 attributedText 已含组字内容，据此立即隐藏占位。
            updatePlaceholderVisibility(in: textView)
            guard !isProgrammaticChange else { return }
            guard textView.markedTextRange == nil else { return }
            normalizeTaskMetadata(after: textView)
            syncMarkdown(from: textView)
            updateTriggerState(textView)
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard !isProgrammaticChange else { return true }

            // Token 原子化：编辑范围触碰 Token 时扩展为完整 Token 操作
            if handleTokenEditInterception(textView, range: range, replacementText: text) {
                return false
            }

            // 任务作用文字是一个连续可编辑范围：常规键入/删除交给 UIKit 原生链路，
            // 让系统保留正常的输入法、光标和撤销合并行为；只需把当前 taskId 放进
            // typingAttributes，新文字就会自然继承任务下划线。粘贴、跨 Token 替换等
            // 非常规动作仍由下方的专用路径处理。
            let taskId = textView.markedTextRange == nil
                ? taskIdForTextChange(range: range, in: textView.attributedText)
                : nil
            if let taskId {
                prepareTaskTypingAttributes(taskId: taskId, on: textView)
            }

            // 只处理回车键的列表续行逻辑
            guard text == "\n" else { return true }

            let currentText = textView.attributedText.string as NSString
            let cursorLocation = range.location

            // 找到当前行的起始位置
            let lineStart = MarkdownTextView.lineStart(in: currentText, before: cursorLocation)

            let lineLength = max(0, cursorLocation - lineStart)
            let currentLine = currentText.substring(with: NSRange(location: lineStart, length: lineLength))

            // 检测无序列表（支持 - * • 三种前缀）
            if let match = Self.listPrefixMatch(pattern: "^[\\-\\*\u{2022}] ", in: currentLine) {
                let contentAfterPrefix = String(currentLine.dropFirst(match.length)).trimmingCharacters(in: .whitespaces)

                // 空列表项：退出列表
                if contentAfterPrefix.isEmpty {
                    let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
                    mutable.deleteCharacters(in: NSRange(location: lineStart, length: lineLength))
                    mutable.insert(NSAttributedString(string: "\n", attributes: textView.typingAttributes), at: lineStart)
                    refreshTaskSourceLengths(in: mutable)
                    removeEmptyTaskMarkers(in: mutable)

                    performProgrammaticEdit(on: textView, actionName: String(localized: "退出无序列表")) {
                        textView.attributedText = mutable
                        textView.selectedRange = NSRange(location: lineStart + 1, length: 0)
                    }
                    syncMarkdown(from: textView)
                    return false
                }

                // 续行：插入新行 + 圆角点前缀
                let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
                let prefixAttrs = MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
                mutable.insert(NSAttributedString(string: "\n\u{2022} ", attributes: prefixAttrs), at: cursorLocation)
                refreshTaskSourceLengths(in: mutable)
                removeEmptyTaskMarkers(in: mutable)

                performProgrammaticEdit(on: textView, actionName: String(localized: "续写无序列表")) {
                    textView.attributedText = mutable
                    textView.selectedRange = NSRange(location: cursorLocation + 3, length: 0)
                }
                syncMarkdown(from: textView)
                return false
            }

            // 检测有序列表
            if let match = Self.listPrefixMatch(pattern: "^(\\d+)\\. ", in: currentLine),
               match.numberValue != nil {
                let prefixEnd = currentLine.index(currentLine.startIndex, offsetBy: match.length, limitedBy: currentLine.endIndex) ?? currentLine.endIndex
                let contentAfterPrefix = String(currentLine[prefixEnd...]).trimmingCharacters(in: .whitespaces)

                if contentAfterPrefix.isEmpty {
                    let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
                    mutable.deleteCharacters(in: NSRange(location: lineStart, length: lineLength))
                    mutable.insert(NSAttributedString(string: "\n", attributes: textView.typingAttributes), at: lineStart)
                    refreshTaskSourceLengths(in: mutable)
                    removeEmptyTaskMarkers(in: mutable)

                    performProgrammaticEdit(on: textView, actionName: String(localized: "退出有序列表")) {
                        textView.attributedText = mutable
                        textView.selectedRange = NSRange(location: lineStart + 1, length: 0)
                    }
                    syncMarkdown(from: textView)
                    return false
                }

                let nextNumber = (match.numberValue ?? 0) + 1
                let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
                let prefixAttrs = MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
                let newPrefix = "\n\(nextNumber). "
                mutable.insert(NSAttributedString(string: newPrefix, attributes: prefixAttrs), at: cursorLocation)
                refreshTaskSourceLengths(in: mutable)
                removeEmptyTaskMarkers(in: mutable)

                performProgrammaticEdit(on: textView, actionName: String(localized: "续写有序列表")) {
                    textView.attributedText = mutable
                    textView.selectedRange = NSRange(location: cursorLocation + (newPrefix as NSString).length, length: 0)
                }
                syncMarkdown(from: textView)
                return false
            }

            if let taskId {
                prepareTaskTypingAttributes(taskId: taskId, on: textView)
            }

            return true
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // IME 组字期间不刷新 typingAttributes，防止自定义格式属性被丢弃
            guard textView.markedTextRange == nil else { return }

            // Token 原子化：光标/选区进入 Token 时先调整，调整后等待重入回调
            if !isProgrammaticChange, adjustSelectionForTokenAtomicity(textView) {
                return
            }

            refreshTypingAttributes(for: textView)
            updateTriggerState(textView)
            reportCaretRect(textView)
            lastSelectionLocation = textView.selectedRange.location
        }

        /// 上报当前光标在编辑器视图坐标系内的 rect（用于候选浮层吸附）
        func reportCaretRect(_ textView: UITextView) {
            // selectedRange.location 可能落在 length 处（文末），用 position(from:offset:) 获取安全 UITextPosition
            let location = min(textView.selectedRange.location, textView.attributedText.length)
            guard let startPosition = textView.position(from: textView.beginningOfDocument, offset: location) else {
                onCaretRectChange?(.zero)
                return
            }
            let rect = textView.caretRect(for: startPosition)
            onCaretRectChange?(rect)
        }

        /// 是否已接管系统编辑菜单交互
        private var didReplaceEditMenuInteraction = false

        func textViewDidBeginEditing(_ textView: UITextView) {
            // 用自定义 delegate 的交互替换系统编辑菜单交互：
            // 选区为完整 Token 时返回空菜单（含 AutoFill 等不走 canPerformAction 的注入项）
            if #available(iOS 16.0, *), !didReplaceEditMenuInteraction {
                didReplaceEditMenuInteraction = true
                for interaction in textView.interactions where interaction is UIEditMenuInteraction {
                    textView.removeInteraction(interaction)
                }
                textView.addInteraction(UIEditMenuInteraction(delegate: self))
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            activeTrigger = nil
            publishTrigger(nil)
            // 注意：不在此处清 selectedToken。
            // 原因：token 操作菜单已改为 .sheet(item: $selectedToken)，sheet 呈现时 UITextView 会失焦，
            // 若此处同步清 selectedToken，会把刚设上的选中态立刻抹掉，菜单弹不出来（旧 confirmationDialog 的竞态根因）。
            // selectedToken 的清空改由 sheet dismiss（用户操作或下滑关闭）负责，链路自洽。
        }

        func perform(
            action: MarkdownEditorAction,
            on textView: UITextView,
            markdown: Binding<String>
        ) {
            guard textView.markedTextRange == nil else { return }

            if !textView.isFirstResponder {
                textView.becomeFirstResponder()
            }

            switch action {
            case .toggleBold:
                toggleInlineStyle(on: textView, attribute: .holoBold, value: true)
            case .toggleItalic:
                toggleInlineStyle(on: textView, attribute: .holoItalic, value: true)
            case .toggleUnderline:
                toggleInlineStyle(on: textView, attribute: .holoUnderline, value: true)
            case .setColor(let hex):
                setInlineColor(hex: hex, on: textView)
            case .insertUnorderedList:
                insertAtLineStart("\u{2022} ", on: textView)
            case .insertOrderedList:
                insertAtLineStart("1. ", on: textView)
            case .insertText(let text):
                insertText(text, on: textView)
            case .insertTriggerCharacter(let character):
                insertTriggerCharacter(character, on: textView)
            case .insertTagToken(let id, let displayPath):
                insertToken(type: .tag, id: id, displayText: displayPath, snapshot: nil, on: textView)
            case .insertReferenceToken(let id, let displayText, let snapshot):
                insertToken(type: .reference, id: id, displayText: displayText, snapshot: snapshot, on: textView)
            case .insertTaskMark(let taskId, let displayText, let sourceRange):
                insertTaskMarks([
                    TaskMarkInsertion(
                        taskId: taskId,
                        displayText: displayText,
                        sourceRange: sourceRange
                    )
                ], on: textView)
            case .insertTaskMarks(let insertions):
                insertTaskMarks(insertions, on: textView)
            case .convertToTask:
                // 有选中文字只转选中部分，无选中转整篇
                let selection = textView.selectedRange
                if selection.length > 0,
                   let substring = textView.attributedText?.attributedSubstring(from: selection) {
                    let visibleSelection = MarkdownTextView.visiblePlainText(
                        from: MarkdownTextView.serializeNodes(from: substring)
                    )
                    let trimmed = visibleSelection.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let visibleRange = MarkdownTextView.visibleRange(
                            forStorageRange: selection,
                            in: textView.attributedText ?? NSAttributedString()
                        ) ?? selection
                        onConvertSelection?(trimmed, visibleRange)
                        return
                    }
                }
                onConvertToTask?()
            case .removeSelectedToken:
                removeSelectedToken(on: textView)
            case .dismissSuggestion:
                dismissSuggestion()
            }

            if textView.markedTextRange == nil {
                syncMarkdown(from: textView)
            }
            markdown.wrappedValue = lastKnownMarkdown
            updatePlaceholderVisibility(in: textView)
        }

        func refreshTypingAttributes(for textView: UITextView) {
            var typingAttributes = MarkdownTextView.baseAttributes
            let location = max(0, min(textView.selectedRange.location, textView.attributedText.length))

            // 先从周围文字推断 contextual 格式
            if textView.selectedRange.length > 0, location < textView.attributedText.length {
                typingAttributes.merge(MarkdownTextView.inlineAttributes(at: location, in: textView.attributedText)) { _, new in new }
            } else if location > 0, location - 1 < textView.attributedText.length {
                typingAttributes.merge(MarkdownTextView.inlineAttributes(at: location - 1, in: textView.attributedText)) { _, new in new }
            }

            // 叠加用户显式切换的格式状态（sticky toggle，Word-like 行为）
            if let bold = explicitBold {
                if bold {
                    typingAttributes[.holoBold] = true
                } else {
                    typingAttributes.removeValue(forKey: .holoBold)
                }
            }
            if let italic = explicitItalic {
                if italic {
                    typingAttributes[.holoItalic] = true
                } else {
                    typingAttributes.removeValue(forKey: .holoItalic)
                }
            }
            if let underline = explicitUnderline {
                if underline {
                    typingAttributes[.holoUnderline] = true
                } else {
                    typingAttributes.removeValue(forKey: .holoUnderline)
                }
            }
            if let colorHex = explicitColorHex {
                typingAttributes[.holoColorHex] = colorHex
                typingAttributes[.foregroundColor] = MarkdownTextView.resolvedTextColor(for: colorHex)
            }

            // 中文输入法组字期间，UIKit 会直接使用 typingAttributes 写入 marked text，
            // 不一定经过 shouldChangeTextIn 的任务范围分支。把当前任务作用范围带进组字属性，
            // 提交中文后新文字才能和普通键盘输入一样继续显示下划线。
            typingAttributes.removeValue(forKey: .holoTaskId)
            typingAttributes.removeValue(forKey: .holoTaskSourceLength)
            if let taskId = taskIdForTextChange(
                range: NSRange(location: location, length: 0),
                in: textView.attributedText
            ) {
                typingAttributes[.holoTaskId] = taskId
                typingAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }

            typingAttributes[.font] = MarkdownTextView.font(from: typingAttributes)
            if typingAttributes[.foregroundColor] == nil {
                typingAttributes[.foregroundColor] = MarkdownTextView.baseTextColor
            }
            // 打字属性必须携带编辑态行距：新输入的每个字符都从这里继承样式。
            // 旧实现为压低空行光标高度把 lineSpacing 清零，导致连续打出的文字全部
            // 失去行距（明显比已渲染文字挤），保存重进后才恢复。空行光标被行距撑高
            // 的问题改由 SelfSizingTextView.caretRect(for:) 统一 clamp 光标高度解决。
            if let paragraphStyle = typingAttributes[.paragraphStyle] as? NSParagraphStyle,
               let mutableStyle = paragraphStyle.mutableCopy() as? NSMutableParagraphStyle,
               let typingFont = typingAttributes[.font] as? UIFont {
                mutableStyle.lineSpacing = MarkdownTextView.editorLineSpacing(for: typingFont)
                typingAttributes[.paragraphStyle] = mutableStyle
            }
            textView.typingAttributes = typingAttributes

            notifyFormatState(typingAttributes)
        }

        private func syncMarkdown(from textView: UITextView) {
            let serializedNodes = MarkdownTextView.serializeNodes(from: textView.attributedText)
            nodes = serializedNodes
            let markdown = RichContentSerializer.plainText(from: serializedNodes)
            lastKnownMarkdown = markdown
            text = markdown
            onNodesChange?(serializedNodes)
            updateAccessibilityValue(in: textView)
        }

        /// 编辑态也使用语义化辅助功能文本，避免 UIKit 把任务附件暴露成 U+FFFC 占位符。
        /// 视觉编辑内容仍由 attributedText 提供；编辑态的 Value 必须保留与底层 UTF-16
        /// 一一对应的长度，否则系统选区/VoiceOver 编辑动作会把“引用：@标题”这类扩展
        /// 语义文字当成真实坐标，选中 Token 后误删相邻正文。完整语义改放到 Hint，阅读态
        /// 仍继续使用 accessibilityText(from:) 的展开口径。
        func updateAccessibilityValue(in textView: UITextView) {
            textView.accessibilityLabel = String(localized: "想法内容")
            textView.accessibilityValue = MarkdownTextView.editableAccessibilityText(from: textView.attributedText)
            textView.accessibilityHint = MarkdownTextView.editableAccessibilityHint(from: nodes)
        }

        // MARK: - 任务作用范围同步

        private struct TaskSourceSpan {
            let taskId: String
            let range: NSRange
            let markerRange: NSRange
        }

        /// 找出每个任务标记前、由同一 taskId 连续装饰的原文范围。
        /// 任务源文字可能被粗体/颜色拆成多个属性段，但业务范围仍按 taskId 连续性计算。
        private func taskSourceSpans(in attributedText: NSAttributedString) -> [TaskSourceSpan] {
            MarkdownTextView.tokenRanges(in: attributedText).compactMap { markerRange in
                guard markerRange.location < attributedText.length,
                      attributedText.attribute(.holoTokenType, at: markerRange.location, effectiveRange: nil) as? String == HoloTokenType.taskMark.rawValue,
                      let taskId = attributedText.attribute(.holoTaskId, at: markerRange.location, effectiveRange: nil) as? String else {
                    return nil
                }

                var sourceStart = markerRange.location
                var cursor = markerRange.location
                while cursor > 0 {
                    var effectiveRange = NSRange(location: 0, length: 0)
                    let value = attributedText.attribute(.holoTaskId, at: cursor - 1, effectiveRange: &effectiveRange) as? String
                    guard value == taskId, effectiveRange.location < cursor else { break }
                    sourceStart = effectiveRange.location
                    cursor = effectiveRange.location
                }

                return TaskSourceSpan(
                    taskId: taskId,
                    range: NSRange(location: sourceStart, length: markerRange.location - sourceStart),
                    markerRange: markerRange
                )
            }
        }

        /// 返回当前编辑是否只涉及一个任务的作用范围。
        /// - 插入：允许光标位于源文字内部或紧贴任务标记之前。
        /// - 替换/删除：只要选区碰到一个任务源，就让替换文字继承该任务关系。
        private func taskIdForTextChange(
            range: NSRange,
            in attributedText: NSAttributedString
        ) -> String? {
            let spans = taskSourceSpans(in: attributedText)
            guard !spans.isEmpty else { return nil }

            let candidates: [TaskSourceSpan]
            if range.length == 0 {
                candidates = spans.filter {
                    range.location >= $0.range.location
                        && range.location <= NSMaxRange($0.range)
                }
            } else {
                candidates = spans.filter {
                    NSIntersectionRange(range, $0.range).length > 0
                }
            }

            // 选区覆盖普通引用/标签 Token 时，Token 本身也携带了任务归属，
            // 但它位于 marker 之前的源文字范围之外。若只看 source span，
            // 键盘替换或粘贴覆盖 Token 后新文字会脱离任务下划线。
            // 仅对非空替换范围读取被触碰 Token，避免光标停在 Token 边界时误继承关系。
            let taskIds = Set(candidates.map(\.taskId)).union(
                MarkdownTextView.taskScopeIDsTouchingRange(
                    range,
                    in: attributedText
                )
            )
            guard taskIds.count == 1 else { return nil }
            return taskIds.first
        }

        /// 让 UIKit 原生输入继承当前任务作用范围。
        /// 不在每个字符进入时重建整个 attributedText，避免破坏输入法组字、光标位置
        /// 和系统对连续键入的撤销合并。
        private func prepareTaskTypingAttributes(taskId: String, on textView: UITextView) {
            var attributes = MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
            attributes.removeValue(forKey: .holoTaskSourceLength)
            attributes[.holoTaskId] = taskId
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            textView.typingAttributes = attributes
        }

        /// 根据当前连续源范围回写 attachment 的 sourceLength，供保存/重进时精确恢复。
        private func refreshTaskSourceLengths(in attributedText: NSMutableAttributedString) {
            for span in taskSourceSpans(in: attributedText) {
                let sourceLength = max(0, span.range.length)
                let currentLength = (attributedText.attribute(
                    .holoTaskSourceLength,
                    at: span.markerRange.location,
                    effectiveRange: nil
                ) as? NSNumber)?.intValue
                guard currentLength != sourceLength else { continue }
                attributedText.addAttribute(
                    .holoTaskSourceLength,
                    value: sourceLength,
                    range: span.markerRange
                )
            }
        }

        // MARK: - 编辑器撤销桥

        /// `attributedText` 整体赋值不会稳定地产生 UIKit 撤销单元。
        /// 编辑器的格式、Token 和任务操作都必须把「文字 + Token 属性 + 光标」作为一个状态保存，
        /// 否则用户撤销时可能只退回文字，引用身份却已经丢失。
        private func registerUndo(
            on textView: UITextView,
            restoring attributedText: NSAttributedString,
            selectedRange: NSRange,
            actionName: String
        ) {
            let beforeText = NSAttributedString(attributedString: textView.attributedText)
            let beforeSelection = textView.selectedRange
            guard !beforeText.isEqual(to: attributedText) || beforeSelection != selectedRange else { return }

            textView.undoManager?.registerUndo(withTarget: self) { [weak textView] coordinator in
                guard let textView else { return }
                coordinator.restoreEditorState(
                    in: textView,
                    attributedText: attributedText,
                    selectedRange: selectedRange,
                    actionName: actionName
                )
            }
            textView.undoManager?.setActionName(actionName)
        }

        /// 恢复编辑器状态，并为重做注册反向状态；这样 undo/redo 都保持同一条链路。
        private func restoreEditorState(
            in textView: UITextView,
            attributedText: NSAttributedString,
            selectedRange: NSRange,
            actionName: String
        ) {
            let currentText = NSAttributedString(attributedString: textView.attributedText)
            let currentSelection = textView.selectedRange
            textView.undoManager?.registerUndo(withTarget: self) { [weak textView] coordinator in
                guard let textView else { return }
                coordinator.restoreEditorState(
                    in: textView,
                    attributedText: currentText,
                    selectedRange: currentSelection,
                    actionName: actionName
                )
            }
            textView.undoManager?.setActionName(actionName)

            let undoManager = textView.undoManager
            undoManager?.disableUndoRegistration()
            isProgrammaticChange = true
            textView.attributedText = attributedText
            textView.selectedRange = MarkdownTextView.clampedRange(
                selectedRange,
                for: attributedText.length
            )
            lastSelectionLocation = textView.selectedRange.location
            isProgrammaticChange = false
            undoManager?.enableUndoRegistration()

            refreshTypingAttributes(for: textView)
            syncMarkdown(from: textView)
            updateTriggerState(textView)
            reportCaretRect(textView)
        }

        /// 执行一次程序化编辑并把编辑前的状态注册为一个撤销单元。
        @discardableResult
        private func performProgrammaticEdit(
            on textView: UITextView,
            actionName: String,
            _ mutation: () -> Void
        ) -> NSAttributedString {
            let previousText = NSAttributedString(attributedString: textView.attributedText)
            let previousSelection = textView.selectedRange

            isProgrammaticChange = true
            mutation()
            isProgrammaticChange = false

            registerUndo(
                on: textView,
                restoring: previousText,
                selectedRange: previousSelection,
                actionName: actionName
            )
            return NSAttributedString(attributedString: textView.attributedText)
        }

        /// 光标态格式没有文字变化，也需要纳入撤销链，否则用户点一次加粗后无法撤回这个输入状态。
        private func registerTypingUndo(
            on textView: UITextView,
            restoring typingAttributes: [NSAttributedString.Key: Any],
            explicitBold: Bool?,
            explicitItalic: Bool?,
            explicitUnderline: Bool?,
            explicitColorHex: String?,
            actionName: String
        ) {
            textView.undoManager?.registerUndo(withTarget: self) { [weak textView] coordinator in
                guard let textView else { return }
                coordinator.restoreTypingState(
                    in: textView,
                    typingAttributes: typingAttributes,
                    explicitBold: explicitBold,
                    explicitItalic: explicitItalic,
                    explicitUnderline: explicitUnderline,
                    explicitColorHex: explicitColorHex,
                    actionName: actionName
                )
            }
            textView.undoManager?.setActionName(actionName)
        }

        private func restoreTypingState(
            in textView: UITextView,
            typingAttributes: [NSAttributedString.Key: Any],
            explicitBold: Bool?,
            explicitItalic: Bool?,
            explicitUnderline: Bool?,
            explicitColorHex: String?,
            actionName: String
        ) {
            let currentTypingAttributes = textView.typingAttributes
            let currentExplicitBold = self.explicitBold
            let currentExplicitItalic = self.explicitItalic
            let currentExplicitUnderline = self.explicitUnderline
            let currentExplicitColorHex = self.explicitColorHex

            textView.undoManager?.registerUndo(withTarget: self) { [weak textView] coordinator in
                guard let textView else { return }
                coordinator.restoreTypingState(
                    in: textView,
                    typingAttributes: currentTypingAttributes,
                    explicitBold: currentExplicitBold,
                    explicitItalic: currentExplicitItalic,
                    explicitUnderline: currentExplicitUnderline,
                    explicitColorHex: currentExplicitColorHex,
                    actionName: actionName
                )
            }
            textView.undoManager?.setActionName(actionName)

            let undoManager = textView.undoManager
            undoManager?.disableUndoRegistration()
            self.explicitBold = explicitBold
            self.explicitItalic = explicitItalic
            self.explicitUnderline = explicitUnderline
            self.explicitColorHex = explicitColorHex
            textView.typingAttributes = typingAttributes
            undoManager?.enableUndoRegistration()
            notifyFormatState(typingAttributes)
        }

        // MARK: - 语义剪贴板

        /// 复制时同时写入 Holo 节点 JSON；系统仍保留自己的纯文本数据，跨应用粘贴不受影响。
        fileprivate func semanticClipboardPayload(in textView: UITextView, range: NSRange) -> SemanticClipboardPayload? {
            guard let copyRange = expandedTokenRange(range, in: textView), copyRange.length > 0 else {
                return nil
            }
            let selectedText = textView.attributedText.attributedSubstring(from: copyRange)
            // 任务标记是依附在正文上的关系附件，不是可独立复制的正文内容。
            // 复制“正文 + 任务标记”时保留文字、引用和标签，但不把没有来源文字的任务附件
            // 带到另一个编辑器，避免粘贴后出现孤立任务或跨 App 变成空字符串。
            let nodes = MarkdownTextView.clipboardSafeNodes(
                from: MarkdownTextView.serializeNodes(from: selectedText)
            )
            guard !nodes.isEmpty,
                  let json = try? RichContentSerializer.jsonString(from: nodes) else {
                return nil
            }
            guard let data = json.data(using: .utf8) else { return nil }
            return SemanticClipboardPayload(
                data: data,
                plainText: MarkdownTextView.visiblePlainText(from: nodes)
            )
        }

        /// 应用内粘贴优先恢复节点身份，避免 @引用/标签/任务被降级为普通文字。
        func pasteSemanticContent(_ data: Data, in textView: UITextView) -> Bool {
            guard let json = String(data: data, encoding: .utf8),
                  let nodes = try? RichContentSerializer.nodes(fromJSONString: json),
                  !nodes.isEmpty else {
                return false
            }

            // 兼容旧剪贴板或其他 Holo 版本写入的任务附件：任务关系必须和来源文字一起建立，
            // 单独粘贴任务标记没有可解释的作用范围，直接忽略该节点。
            let pasteNodes = MarkdownTextView.clipboardSafeNodes(from: nodes)
            guard !pasteNodes.isEmpty else { return false }

            let replacement = MarkdownTextView.applyingEditorLineSpacing(
                to: MarkdownTextView.makeAttributedText(from: pasteNodes)
            )
            let requestedRange = MarkdownTextView.clampedRange(
                textView.selectedRange,
                for: textView.attributedText.length
            )
            // 选区若触碰 Token，按 Token 原子性整体替换；若光标落在 Token 内部则拒绝本次粘贴，
            // 防止系统把不可拆分引用从中间截断。
            guard let targetRange = expandedTokenRange(requestedRange, in: textView) else {
                return true
            }

            // 应用内结构化粘贴也要遵循目标位置的任务作用范围；否则从任务文字中间粘贴
            // 一段普通的 Holo 内容，会出现“看起来插进任务里，实际下划线断开”的语义裂缝。
            let intersectingTokens = MarkdownTextView.tokenRanges(in: textView.attributedText).filter {
                NSIntersectionRange($0, targetRange).length > 0
            }
            let replacesTaskMarker = intersectingTokens.contains { tokenRange in
                guard let node = MarkdownTextView.makeTokenNode(
                    from: textView.attributedText.attributes(at: tokenRange.location, effectiveRange: nil)
                ) else { return false }
                if case .taskMark = node { return true }
                return false
            }
            let destinationTaskId: String? = replacesTaskMarker
                ? nil
                : taskIdForTextChange(range: targetRange, in: textView.attributedText)
            let taskAwareReplacement = NSMutableAttributedString(attributedString: replacement)
            if let destinationTaskId {
                applyTaskScope(taskId: destinationTaskId, to: taskAwareReplacement)
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            removeTaskDecorations(
                for: intersectingTokens,
                from: textView.attributedText,
                in: mutable
            )
            mutable.replaceCharacters(in: targetRange, with: taskAwareReplacement)
            refreshTaskSourceLengths(in: mutable)
            removeEmptyTaskMarkers(in: mutable)
            performProgrammaticEdit(on: textView, actionName: String(localized: "粘贴 Holo 内容")) {
                textView.attributedText = mutable
                textView.selectedRange = NSRange(
                    location: targetRange.location + taskAwareReplacement.length,
                    length: 0
                )
            }
            lastSelectionLocation = textView.selectedRange.location
            refreshTypingAttributes(for: textView)
            syncMarkdown(from: textView)
            updateTriggerState(textView)
            return true
        }

        /// 外部富文本只取纯文字，避免网页/其他 App 的字体、颜色和背景污染 Holo 编辑器。
        func pastePlainText(_ string: String, in textView: UITextView) -> Bool {
            guard !string.isEmpty else { return false }

            let requestedRange = MarkdownTextView.clampedRange(
                textView.selectedRange,
                for: textView.attributedText.length
            )
            if handleTokenEditInterception(
                textView,
                range: requestedRange,
                replacementText: string
            ) {
                return true
            }

            let replacement = makeTaskAwareReplacement(
                string,
                range: requestedRange,
                in: textView
            )
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            mutable.replaceCharacters(in: requestedRange, with: replacement)
            refreshTaskSourceLengths(in: mutable)
            removeEmptyTaskMarkers(in: mutable)
            performProgrammaticEdit(on: textView, actionName: String(localized: "粘贴文字")) {
                textView.attributedText = mutable
                textView.selectedRange = NSRange(
                    location: requestedRange.location + replacement.length,
                    length: 0
                )
            }
            refreshTypingAttributes(for: textView)
            syncMarkdown(from: textView)
            updateTriggerState(textView)
            return true
        }

        /// 统一构造普通文字进入编辑器时的属性：保留当前输入格式，并继承目标任务范围。
        /// 键盘输入、语音插入、普通粘贴和工具栏插入都必须经过同一条规则。
        private func makeTaskAwareReplacement(
            _ string: String,
            range: NSRange,
            in textView: UITextView
        ) -> NSAttributedString {
            var attributes = MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
            // typingAttributes 可能来自中文组字前的任务范围；每次普通插入都必须按新的目标位置重算，
            // 避免光标移出任务后仍把旧 taskId 带到普通正文中。
            attributes.removeValue(forKey: .holoTaskId)
            attributes.removeValue(forKey: .holoTaskSourceLength)
            if let taskId = taskIdForTextChange(range: range, in: textView.attributedText) {
                attributes[.holoTaskId] = taskId
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            return NSAttributedString(string: string, attributes: attributes)
        }

        /// 中文组字提交后统一刷新任务标记的 sourceLength，并清理可能已经没有作用文字的标记。
        /// 仅修改属性和附件，不重建整段文本，避免破坏输入法的光标位置。
        private func normalizeTaskMetadata(after textView: UITextView) {
            let previousSelection = textView.selectedRange
            isProgrammaticChange = true
            refreshTaskSourceLengths(in: textView.textStorage)
            let removedMarkerRanges = removeEmptyTaskMarkers(in: textView.textStorage)
            isProgrammaticChange = false

            let removedBeforeCaret = removedMarkerRanges
                .filter { $0.location < previousSelection.location }
                .reduce(0) { $0 + $1.length }
            let adjustedSelection = NSRange(
                location: max(0, previousSelection.location - removedBeforeCaret),
                length: previousSelection.length
            )
            textView.selectedRange = MarkdownTextView.clampedRange(
                adjustedSelection,
                for: textView.attributedText.length
            )
            lastSelectionLocation = textView.selectedRange.location
            refreshTypingAttributes(for: textView)
        }

        /// 给一段新插入的结构化内容继承目标任务作用范围。
        private func applyTaskScope(taskId: String, to attributedText: NSMutableAttributedString) {
            guard attributedText.length > 0 else { return }
            let range = NSRange(location: 0, length: attributedText.length)
            attributedText.addAttribute(.holoTaskId, value: taskId, range: range)
            attributedText.addAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: range
            )
        }

        /// 将与 Token 相交的选区扩展为完整 Token；光标落在 Token 内部时返回 nil。
        private func expandedTokenRange(_ range: NSRange, in textView: UITextView) -> NSRange? {
            let tokenRanges = MarkdownTextView.tokenRanges(in: textView.attributedText)
            if range.length == 0,
               tokenRanges.contains(where: {
                   range.location > $0.location && range.location < NSMaxRange($0)
               }) {
                return nil
            }

            var expanded = range
            for tokenRange in tokenRanges where NSIntersectionRange(expanded, tokenRange).length > 0 {
                expanded = NSUnionRange(expanded, tokenRange)
            }
            return expanded
        }

        // MARK: - Token 原子化

        /// Token 编辑拦截：删除/替换范围触碰 Token 时扩展为完整 Token；Token 内部禁止插入
        /// - Returns: true 表示已拦截（调用方应返回 false）
        private func handleTokenEditInterception(_ textView: UITextView, range: NSRange, replacementText text: String) -> Bool {
            let tokenRanges = MarkdownTextView.tokenRanges(in: textView.attributedText)
            guard !tokenRanges.isEmpty else { return false }

            // 纯插入且光标在 Token 内部 → 禁止（正常被光标吸附挡住，这里兜底）
            if range.length == 0 {
                return tokenRanges.contains { range.location > $0.location && range.location < $0.location + $0.length }
            }

            // 编辑范围与 Token 相交 → 扩展为完整 Token 范围执行替换
            let intersecting = tokenRanges.filter { NSIntersectionRange($0, range).length > 0 }
            guard !intersecting.isEmpty else { return false }

            var unionRange = range
            for tokenRange in intersecting {
                unionRange = NSUnionRange(unionRange, tokenRange)
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            // 键盘直接删除任务附件时，也必须移除它在原文上的专属下划线；
            // 否则当前编辑器仍像有任务，保存重进后却只剩普通文字。
            removeTaskDecorations(
                for: intersecting,
                from: textView.attributedText,
                in: mutable
            )

            var replacementAttributes = MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
            let replacesTaskMarker = intersecting.contains { tokenRange in
                guard let node = MarkdownTextView.makeTokenNode(
                    from: textView.attributedText.attributes(at: tokenRange.location, effectiveRange: nil)
                ) else { return false }
                if case .taskMark = node { return true }
                return false
            }
            if !replacesTaskMarker,
               let taskId = taskIdForTextChange(range: unionRange, in: textView.attributedText) {
                replacementAttributes[.holoTaskId] = taskId
                replacementAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            let replacement = NSAttributedString(string: text, attributes: replacementAttributes)
            mutable.replaceCharacters(in: unionRange, with: replacement)
            refreshTaskSourceLengths(in: mutable)
            removeEmptyTaskMarkers(in: mutable)

            performProgrammaticEdit(on: textView, actionName: String(localized: "编辑引用")) {
                textView.attributedText = mutable
                textView.selectedRange = NSRange(location: unionRange.location + replacement.length, length: 0)
            }

            syncMarkdown(from: textView)
            updateTriggerState(textView)
            return true
        }

        /// 删除或替换 Token 前，清理其中 taskMark 对前文建立的专属下划线。
        /// 统一给键盘删除、普通粘贴和语义粘贴使用，避免三条路径留下不同的残余状态。
        private func removeTaskDecorations(
            for tokenRanges: [NSRange],
            from source: NSAttributedString,
            in mutable: NSMutableAttributedString
        ) {
            for tokenRange in tokenRanges {
                guard tokenRange.location < source.length,
                      let node = MarkdownTextView.makeTokenNode(
                          from: source.attributes(at: tokenRange.location, effectiveRange: nil)
                      ) else { continue }
                guard case .taskMark(_, let taskId, _, let sourceLength) = node else { continue }
                let sourceRange = NSRange(
                    location: max(0, tokenRange.location - max(0, sourceLength)),
                    length: min(max(0, sourceLength), tokenRange.location)
                )
                removeTaskSourceDecoration(
                    taskId: taskId,
                    sourceRange: sourceRange,
                    from: mutable
                )
            }
        }

        /// 任务作用文字被全部删除后，关系已经没有可标识的正文范围；同步移除孤立的任务标记。
        /// 否则编辑器会留下一个“任务”附件，但用户看不到它对应的文字，重进后也无法判断作用对象。
        @discardableResult
        private func removeEmptyTaskMarkers(in attributedText: NSMutableAttributedString) -> [NSRange] {
            let emptyMarkerRanges = taskSourceSpans(in: attributedText)
                .filter { $0.range.length == 0 }
                .map(\.markerRange)
                .sorted { $0.location > $1.location }

            var removedRanges: [NSRange] = []
            for markerRange in emptyMarkerRanges {
                let safeRange = MarkdownTextView.clampedRange(markerRange, for: attributedText.length)
                guard safeRange.length > 0 else { continue }
                attributedText.deleteCharacters(in: safeRange)
                removedRanges.append(safeRange)
            }
            return removedRanges
        }

        /// Token 原子化选区调整：光标进入 Token 内部时吸附到较近边缘；
        /// 点按 Token 不制造系统选区（避免触发系统编辑菜单），直接发布 Token 选中态弹自定义菜单；
        /// 选区横跨 Token 一部分时扩展为完整 Token
        /// - Returns: true 表示选区已被调整（等待重入回调）
        private func adjustSelectionForTokenAtomicity(_ textView: UITextView) -> Bool {
            let tokenRanges = MarkdownTextView.tokenRanges(in: textView.attributedText)
            guard !tokenRanges.isEmpty else { return false }

            let selection = textView.selectedRange

            if selection.length == 0 {
                // 移动距离 >1 视为点按：吸附到较近边缘并直接弹 Token 菜单（不保留选区）
                let isTap = abs(selection.location - lastSelectionLocation) > 1
                // Token 起点必须允许键盘光标停留并继续向右穿过；只有点按落在起点时，
                // 才把它视为命中 Token。否则从正文按右箭头到引用前会被永远吸回起点。
                guard let token = tokenRanges.first(where: {
                    let start = $0.location
                    let end = NSMaxRange($0)
                    return selection.location > start && selection.location < end
                        || (isTap && selection.location == start)
                }) else { return false }

                let distanceToStart = selection.location - token.location
                let distanceToEnd = token.location + token.length - selection.location
                let snappedLocation: Int
                if isTap {
                    snappedLocation = distanceToStart <= distanceToEnd ? token.location : token.location + token.length
                } else {
                    // 键盘穿越 Token 时按移动方向一次性跳到另一侧，避免在长引用中逐字卡住。
                    snappedLocation = selection.location > lastSelectionLocation
                        ? token.location + token.length
                        : token.location
                }
                let newSelection = NSRange(
                    location: snappedLocation,
                    length: 0
                )

                if isTap,
                   let node = MarkdownTextView.makeTokenNode(from: textView.attributedText.attributes(at: token.location, effectiveRange: nil)) {
                    publishSelectedToken(node, range: token)
                }

                lastSelectionLocation = newSelection.location
                textView.selectedRange = newSelection
                return true
            }

            // 选区横跨 Token 一部分 → 扩展覆盖完整 Token
            var unionRange = selection
            var didExpand = false
            for token in tokenRanges where NSIntersectionRange(unionRange, token).length > 0 {
                let newUnion = NSUnionRange(unionRange, token)
                if newUnion.location != unionRange.location || newUnion.length != unionRange.length {
                    unionRange = newUnion
                    didExpand = true
                }
            }

            guard didExpand else { return false }
            lastSelectionLocation = unionRange.location
            textView.selectedRange = unionRange
            return true
        }

        // MARK: - 触发检测与 Token 操作

        /// 触发检测：光标处于 #/@ 片段时发布搜索上下文，否则关闭候选面板
        private func updateTriggerState(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            let detected = TriggerDetector.detect(
                text: textView.attributedText.string as NSString,
                cursor: textView.selectedRange.location
            )

            // 结构化引用/标签的可见文本本身也包含 #/@。光标从已有 Token
            // 内部吸附到边缘时，不能把它重新解释成“正在输入新的引用/标签”，
            // 否则用户只是点了一下已有 @ 引用，编辑器就会弹出候选面板并盖住正文。
            if let detected,
               MarkdownTextView.triggerIntersectsToken(detected, in: textView.attributedText) {
                activeTrigger = nil
                publishTrigger(nil)
                return
            }

            // 同一触发片段被手动关闭后保持关闭；片段消失（删除触发字符）后重置抑制
            if let detected {
                if detected.range.location == suppressedTriggerLocation {
                    activeTrigger = nil
                    publishTrigger(nil)
                    return
                }
            } else {
                suppressedTriggerLocation = nil
            }

            activeTrigger = detected
            publishTrigger(detected)
        }

        /// 手动关闭候选面板：保留已输入文字，本次触发片段内不再弹出
        private func dismissSuggestion() {
            suppressedTriggerLocation = activeTrigger?.range.location
            activeTrigger = nil
            publishTrigger(nil)
        }

        private func publishTrigger(_ context: EditorTriggerContext?) {
            guard context != lastPublishedTrigger else { return }
            lastPublishedTrigger = context
            DispatchQueue.main.async { [weak self] in
                self?.triggerContext = context
            }
        }

        /// 清除 Token 选中态（菜单操作完成或编辑结束后调用）
        private func publishSelectedToken(_ node: HoloContentNode?, range: NSRange? = nil) {
            if node == nil {
                selectedTokenRange = nil
            } else if node == selectedToken, range == selectedTokenRange {
                return
            } else {
                selectedTokenRange = range
            }
            DispatchQueue.main.async { [weak self] in
                self?.selectedToken = node
            }
        }

        /// 工具栏触发按钮：在光标处插入 # 或 @，并立即进入搜索态
        private func insertTriggerCharacter(_ character: String, on textView: UITextView) {
            let safeRange = MarkdownTextView.clampedRange(textView.selectedRange, for: textView.attributedText.length)
            let currentText = textView.attributedText.string as NSString
            // 工具栏是用户的明确意图：如果光标紧贴英文/数字、路径分隔符等禁止触发字符，
            // 自动补一个空格，让插入后的 #/@ 既符合正文可读性，也能正常打开候选面板。
            let needsLeadingSpace = safeRange.location > 0
                && !InlineTagDetector.isTriggerPosition(safeRange.location, in: currentText as String)
            let insertionText = (needsLeadingSpace ? " " : "") + character
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let insertion = makeTaskAwareReplacement(
                insertionText,
                range: safeRange,
                in: textView
            )
            mutable.replaceCharacters(in: safeRange, with: insertion)

            performProgrammaticEdit(on: textView, actionName: String(localized: "插入触发字符")) {
                textView.attributedText = mutable
                textView.selectedRange = NSRange(location: safeRange.location + insertion.length, length: 0)
            }

            refreshTypingAttributes(for: textView)
            updateTriggerState(textView)
        }

        /// 候选选中：把触发区间整体替换为 Token，尾随一个空格，光标移到空格后（一次完整 undo 单元）
        private func insertToken(type: HoloTokenType, id: UUID, displayText: String, snapshot: String?, on textView: UITextView) {
            guard let trigger = activeTrigger else { return }

            // Token 自带阅读态的紧凑行距；若 Token 落在行首，该行行距会由它决定，
            // 插入前统一替换为编辑态行距，避免 Token 行比正文行明显更紧。
            let tokenText = MarkdownTextView.applyingEditorLineSpacing(
                to: MarkdownTextView.makeTokenAttributedText(type: type, id: id, displayText: displayText, snapshot: snapshot)
            )
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let safeRange = MarkdownTextView.clampedRange(trigger.range, for: mutable.length)
            let taskAwareToken = NSMutableAttributedString(attributedString: tokenText)
            let destinationTaskId = taskIdForTextChange(range: safeRange, in: textView.attributedText)
            if let destinationTaskId {
                applyTaskScope(taskId: destinationTaskId, to: taskAwareToken)
            }
            mutable.replaceCharacters(in: safeRange, with: taskAwareToken)

            let spaceLocation = safeRange.location + taskAwareToken.length
            let space = makeTaskAwareReplacement(
                " ",
                range: NSRange(location: NSMaxRange(safeRange), length: 0),
                in: textView
            )
            mutable.insert(space, at: spaceLocation)

            // Token 会改变底层 UTF-16 长度；如果它落在任务作用范围内，
            // 必须在同一次编辑里重算任务标记的 sourceLength，否则保存重进后下划线会错位。
            refreshTaskSourceLengths(in: mutable)
            removeEmptyTaskMarkers(in: mutable)

            performProgrammaticEdit(on: textView, actionName: type == .reference ? String(localized: "插入引用") : String(localized: "插入标签")) {
                textView.attributedText = mutable
                textView.selectedRange = NSRange(location: spaceLocation + 1, length: 0)
            }
            lastSelectionLocation = spaceLocation + 1

            activeTrigger = nil
            publishTrigger(nil)
            refreshTypingAttributes(for: textView)
        }

        /// 选中文字转任务：保留选区文字，在其末尾追加关系 Token，并给作用范围加持久下划线。
        /// sourceRange 在弹出确认面板前捕获，避免面板呈现导致 UITextView 当前选区丢失。
        private func insertTaskMarks(
            _ insertions: [TaskMarkInsertion],
            on textView: UITextView
        ) {
            guard let mutable = MarkdownTextView.attributedTextByInsertingTaskMarks(
                insertions,
                into: textView.attributedText
            ) else { return }

            // 如果用户把同一段文字再次转为另一个任务，新的 taskId 会覆盖原作用范围；
            // 旧标记此时已经没有任何可见文字，必须在同一次编辑里清掉，避免正文末尾留下
            // 无法解释、也无法点击定位的孤立「任务」附件。
            refreshTaskSourceLengths(in: mutable)
            removeEmptyTaskMarkers(in: mutable)

            performProgrammaticEdit(on: textView, actionName: String(localized: "转为任务")) {
                textView.attributedText = mutable
                textView.selectedRange = NSRange(location: mutable.length, length: 0)
            }
            lastSelectionLocation = mutable.length
            refreshTypingAttributes(for: textView)
        }

        /// 把选中的 Token 转为普通文本（保留文字、去除 #/@ 前缀与 Token 关系）
        private func removeSelectedToken(on textView: UITextView) {
            let tokenRanges = MarkdownTextView.tokenRanges(in: textView.attributedText)
            let selection = textView.selectedRange
            let lookupRange = selectedTokenRange ?? selection
            guard let tokenRange = tokenRanges.first(where: {
                lookupRange.length == 0
                    ? $0.location == lookupRange.location
                    : NSIntersectionRange($0, lookupRange).length > 0
            }),
                  let node = MarkdownTextView.makeTokenNode(from: textView.attributedText.attributes(at: tokenRange.location, effectiveRange: nil)) else { return }

            let plainText: String?
            var taskIdToRemove: UUID?
            var taskSourceLength: Int?
            var actionName = String(localized: "移除 Token")
            switch node {
            case .tag(_, let displayPath):
                plainText = displayPath
                actionName = String(localized: "移除标签")
            case .reference(_, let displayText, _):
                plainText = displayText
                actionName = String(localized: "取消引用")
            case .taskMark(_, let taskId, _, let sourceLength):
                // 任务状态 Token 是纯标记，取消时删除标记，并移除它在原文上的专属下划线
                taskIdToRemove = taskId
                taskSourceLength = sourceLength
                plainText = nil
                actionName = String(localized: "取消任务标记")
            case .text:
                return
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            if let taskIdToRemove {
                let sourceLength = max(0, taskSourceLength ?? 0)
                let sourceRange = NSRange(
                    location: max(0, tokenRange.location - sourceLength),
                    length: min(sourceLength, tokenRange.location)
                )
                removeTaskSourceDecoration(taskId: taskIdToRemove, sourceRange: sourceRange, from: mutable)
            }
            if let plainText {
                let tokenAttributes = textView.attributedText.attributes(
                    at: tokenRange.location,
                    effectiveRange: nil
                )
                mutable.replaceCharacters(
                    in: tokenRange,
                    with: NSAttributedString(
                        string: plainText,
                        attributes: MarkdownTextView.plainTextAttributes(afterRemovingToken: tokenAttributes)
                    )
                )
            } else {
                mutable.deleteCharacters(in: tokenRange)
            }

            // 取消引用/标签同样会改变任务作用范围的底层长度；删除孤立任务标记，
            // 保证 Token 的增删与任务关系始终以同一份富文本快照持久化。
            refreshTaskSourceLengths(in: mutable)
            removeEmptyTaskMarkers(in: mutable)

            let replacementLength = plainText.map { ($0 as NSString).length } ?? 0
            performProgrammaticEdit(on: textView, actionName: actionName) {
                textView.attributedText = mutable
                textView.selectedRange = NSRange(location: tokenRange.location + replacementLength, length: 0)
            }

            publishSelectedToken(nil)
            refreshTypingAttributes(for: textView)
        }

        /// 移除任务标记对原文作用范围的装饰，但保留用户原本设置的下划线。
        private func removeTaskSourceDecoration(
            taskId: UUID,
            sourceRange: NSRange,
            from attributedText: NSMutableAttributedString
        ) {
            let safeRange = MarkdownTextView.clampedRange(sourceRange, for: attributedText.length)
            guard safeRange.length > 0 else { return }
            var sourceRanges: [NSRange] = []
            attributedText.enumerateAttribute(.holoTaskId, in: safeRange, options: []) { value, range, _ in
                guard let value = value as? String, value == taskId.uuidString else { return }
                sourceRanges.append(range)
            }

            for range in sourceRanges {
                // 一个任务作用范围内可能同时存在用户手动下划线和任务下划线。
                // 先记录每个子区间的手动格式，再整体移除任务装饰，避免读取 range.location
                // 只判断首字符导致混合格式被误删。
                var userUnderlineRanges: [NSRange] = []
                attributedText.enumerateAttribute(.holoUnderline, in: range, options: []) { value, subrange, _ in
                    guard (value as? Bool) == true else { return }
                    userUnderlineRanges.append(subrange)
                }

                attributedText.removeAttribute(.holoTaskId, range: range)
                attributedText.removeAttribute(.underlineStyle, range: range)
                for userUnderlineRange in userUnderlineRanges {
                    attributedText.addAttribute(
                        .underlineStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: userUnderlineRange
                    )
                }
            }
        }

        private func toggleInlineStyle(on textView: UITextView, attribute: NSAttributedString.Key, value: Bool) {
            let safeRange = MarkdownTextView.clampedRange(textView.selectedRange, for: textView.attributedText.length)

            if safeRange.length == 0 {
                let previousTypingAttributes = textView.typingAttributes
                let previousExplicitBold = explicitBold
                let previousExplicitItalic = explicitItalic
                let previousExplicitUnderline = explicitUnderline
                let previousExplicitColorHex = explicitColorHex
                var typingAttributes = textView.typingAttributes
                let isActive = (typingAttributes[attribute] as? Bool) == true
                if isActive {
                    typingAttributes.removeValue(forKey: attribute)
                } else {
                    typingAttributes[attribute] = value
                }
                typingAttributes[.font] = MarkdownTextView.font(from: typingAttributes)
                if typingAttributes[.foregroundColor] == nil {
                    typingAttributes[.foregroundColor] = MarkdownTextView.baseTextColor
                }
                textView.typingAttributes = typingAttributes

                // 更新 sticky toggle 状态
                if attribute == .holoBold { explicitBold = !isActive }
                if attribute == .holoItalic { explicitItalic = !isActive }
                if attribute == .holoUnderline { explicitUnderline = !isActive }
                notifyFormatState(typingAttributes)
                registerTypingUndo(
                    on: textView,
                    restoring: previousTypingAttributes,
                    explicitBold: previousExplicitBold,
                    explicitItalic: previousExplicitItalic,
                    explicitUnderline: previousExplicitUnderline,
                    explicitColorHex: previousExplicitColorHex,
                    actionName: String(localized: "修改输入样式")
                )
                return
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            // 引用/标签/任务标记是语义 Token，不是普通文字。跨 Token 选区执行格式动作时，
            // 只处理普通文字子区间，避免把 Token 的品牌色、附件身份和不可拆分语义重写掉。
            let editableRanges = MarkdownTextView.nonTokenRanges(
                in: safeRange,
                attributedText: mutable
            )
            guard !editableRanges.isEmpty else {
                refreshTypingAttributes(for: textView)
                return
            }
            let shouldEnable = editableRanges.contains {
                !MarkdownTextView.rangeHasAttribute(attribute, in: mutable, range: $0)
            }

            mutable.beginEditing()
            for range in editableRanges {
                let attrs = mutable.attributes(at: range.location, effectiveRange: nil)
                var updated = attrs
                if shouldEnable {
                    updated[attribute] = value
                } else {
                    updated.removeValue(forKey: attribute)
                }
                MarkdownTextView.applyResolvedAttributes(updated, to: mutable, range: range)
            }
            mutable.endEditing()

            performProgrammaticEdit(on: textView, actionName: String(localized: "修改文字样式")) {
                textView.attributedText = mutable
                textView.selectedRange = safeRange
            }
            refreshTypingAttributes(for: textView)
        }

        /// 设置文字颜色：有选区只修改选中文字；无选区设置后续输入颜色。
        /// 颜色不是粗体那样的开关，选区操作结束后不应把颜色偷偷带到用户随后点开的其他位置。
        private func setInlineColor(hex: String, on textView: UITextView) {
            let safeRange = MarkdownTextView.clampedRange(textView.selectedRange, for: textView.attributedText.length)

            if safeRange.length == 0 {
                let previousTypingAttributes = textView.typingAttributes
                let previousExplicitBold = explicitBold
                let previousExplicitItalic = explicitItalic
                let previousExplicitUnderline = explicitUnderline
                let previousExplicitColorHex = explicitColorHex
                explicitColorHex = hex
                // 无选区：refreshTypingAttributes 会用 explicitColorHex 叠加 typingAttributes
                refreshTypingAttributes(for: textView)
                registerTypingUndo(
                    on: textView,
                    restoring: previousTypingAttributes,
                    explicitBold: previousExplicitBold,
                    explicitItalic: previousExplicitItalic,
                    explicitUnderline: previousExplicitUnderline,
                    explicitColorHex: previousExplicitColorHex,
                    actionName: String(localized: "修改输入颜色")
                )
                return
            }

            // Token 的颜色是关系身份的一部分；颜色动作只作用于普通文字，
            // 避免选区跨过引用后把 Token 变成普通正文色，保存重进又突然跳回橙色。
            let editableRanges = MarkdownTextView.nonTokenRanges(
                in: safeRange,
                attributedText: textView.attributedText
            )
            guard !editableRanges.isEmpty else {
                refreshTypingAttributes(for: textView)
                return
            }

            // 有选区时，颜色属于这段文字本身。清掉编辑器级 sticky 状态，
            // 让用户把光标移到其他段落后继续输入时回到该处的上下文颜色。
            explicitColorHex = nil

            // 有选区：给选区每个字符上色
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            mutable.beginEditing()
            for range in editableRanges {
                let attrs = mutable.attributes(at: range.location, effectiveRange: nil)
                var updated = attrs
                updated[.holoColorHex] = hex
                MarkdownTextView.applyResolvedAttributes(updated, to: mutable, range: range)
            }
            mutable.endEditing()

            performProgrammaticEdit(on: textView, actionName: String(localized: "修改文字颜色")) {
                textView.attributedText = mutable
                textView.selectedRange = safeRange
            }
            refreshTypingAttributes(for: textView)
        }

        private enum ListKind: Equatable {
            case unordered
            case ordered
        }

        private struct ExistingListPrefix {
            let range: NSRange
            let kind: ListKind
        }

        private struct ListEdit {
            let range: NSRange
            let newLength: Int
        }

        private func existingListPrefix(
            in text: NSString,
            at lineStart: Int
        ) -> ExistingListPrefix? {
            guard lineStart <= text.length else { return nil }
            let remainingLength = text.length - lineStart
            let newlineRange = text.range(
                of: "\n",
                options: [],
                range: NSRange(location: lineStart, length: remainingLength)
            )
            let lineEnd = newlineRange.location == NSNotFound
                ? text.length
                : newlineRange.location
            let line = text.substring(
                with: NSRange(location: lineStart, length: max(0, lineEnd - lineStart))
            )

            if let match = Self.listPrefixMatch(pattern: "^[\\-\\*\u{2022}] ", in: line) {
                return ExistingListPrefix(
                    range: NSRange(location: lineStart, length: match.length),
                    kind: .unordered
                )
            }
            if let match = Self.listPrefixMatch(pattern: "^(\\d+)\\. ", in: line) {
                return ExistingListPrefix(
                    range: NSRange(location: lineStart, length: match.length),
                    kind: .ordered
                )
            }
            return nil
        }

        private func insertAtLineStart(_ prefix: String, on textView: UITextView) {
            let currentText = textView.attributedText.string as NSString
            let safeRange = MarkdownTextView.clampedRange(textView.selectedRange, for: currentText.length)
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)

            // 选中多行后套用列表时，每一行都必须得到前缀；只改第一行会让
            // 用户误以为列表按钮失效。按原始坐标从后往前插入，避免前面的
            // 前缀改变后续行首位置，也保留一次撤销粒度。
            let lineStarts = MarkdownTextView.lineStartLocations(
                in: currentText,
                for: safeRange
            )
            let isOrderedList = prefix == "1. "
            let targetKind: ListKind = isOrderedList ? .ordered : .unordered
            let existingPrefixes = lineStarts.map {
                existingListPrefix(in: currentText, at: $0)
            }
            let shouldRemoveTargetList = !existingPrefixes.isEmpty
                && existingPrefixes.allSatisfy { $0?.kind == targetKind }
            var edits: [ListEdit] = []

            for (index, lineStart) in lineStarts.enumerated().reversed() {
                if shouldRemoveTargetList {
                    guard let existing = existingPrefixes[index] else { continue }
                    mutable.deleteCharacters(in: existing.range)
                    edits.append(ListEdit(range: existing.range, newLength: 0))
                    continue
                }

                let linePrefix = isOrderedList ? "\(index + 1). " : prefix
                if let existing = existingPrefixes[index] {
                    // 同类列表保留原前缀；有序列表则重编号，保证选区内连续。
                    guard targetKind == .ordered || existing.kind != targetKind else { continue }
                    let replacement = makeTaskAwareReplacement(
                        linePrefix,
                        range: existing.range,
                        in: textView
                    )
                    mutable.replaceCharacters(in: existing.range, with: replacement)
                    edits.append(ListEdit(range: existing.range, newLength: replacement.length))
                } else {
                    let insert = makeTaskAwareReplacement(
                        linePrefix,
                        range: NSRange(location: lineStart, length: 0),
                        in: textView
                    )
                    mutable.insert(insert, at: lineStart)
                    edits.append(ListEdit(range: NSRange(location: lineStart, length: 0), newLength: insert.length))
                }
            }

            guard !edits.isEmpty else { return }
            let selectionEnd = NSMaxRange(safeRange)
            let locationShift = edits
                .filter { $0.range.location <= safeRange.location }
                .reduce(0) { $0 + $1.newLength - $1.range.length }
            let selectionLengthShift = edits
                .filter { $0.range.location > safeRange.location && $0.range.location < selectionEnd }
                .reduce(0) { $0 + $1.newLength - $1.range.length }
            let newSelection = NSRange(
                location: safeRange.location + locationShift,
                length: safeRange.length + selectionLengthShift
            )
            refreshTaskSourceLengths(in: mutable)
            removeEmptyTaskMarkers(in: mutable)
            // 列表动作是即时编辑，不会经过一次 Markdown 重渲染；这里同步给当前选区
            // 的每个段落写入悬挂缩进，否则用户刚点完列表时长文本仍会顶到左边。
            let finalText = mutable.string as NSString
            let paragraphStyle = MarkdownTextView.paragraphStyle(forList: !shouldRemoveTargetList)
            for lineStart in MarkdownTextView.lineStartLocations(in: finalText, for: newSelection) {
                let remainingLength = finalText.length - lineStart
                let newlineRange = finalText.range(
                    of: "\n",
                    options: [],
                    range: NSRange(location: lineStart, length: remainingLength)
                )
                let lineEnd = newlineRange.location == NSNotFound
                    ? finalText.length
                    : newlineRange.location
                let lineLength = max(0, lineEnd - lineStart)
                guard lineLength > 0 else { continue }
                mutable.addAttribute(
                    .paragraphStyle,
                    value: paragraphStyle,
                    range: NSRange(location: lineStart, length: lineLength)
                )
            }
            performProgrammaticEdit(on: textView, actionName: String(localized: "插入列表")) {
                textView.attributedText = mutable
                textView.selectedRange = newSelection
            }
            refreshTypingAttributes(for: textView)
        }

        private func insertText(_ text: String, on textView: UITextView) {
            let safeRange = MarkdownTextView.clampedRange(textView.selectedRange, for: textView.attributedText.length)
            let insertionText = ThoughtVoiceTranscriptInsertion.makeInsertionText(
                transcript: text,
                currentContent: textView.attributedText.string,
                selectedRange: safeRange
            )
            guard !insertionText.isEmpty else { return }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let insert = makeTaskAwareReplacement(
                insertionText,
                range: safeRange,
                in: textView
            )
            mutable.replaceCharacters(in: safeRange, with: insert)

            performProgrammaticEdit(on: textView, actionName: String(localized: "插入语音文字")) {
                textView.attributedText = mutable
                textView.selectedRange = NSRange(location: safeRange.location + insert.length, length: 0)
            }
            refreshTypingAttributes(for: textView)
        }

        // MARK: - 列表续行辅助

        /// 列表前缀匹配结果
        private struct ListPrefixResult {
            let length: Int
            let numberValue: Int?
        }

        /// 检测行首是否匹配列表前缀
        private static func listPrefixMatch(pattern: String, in line: String) -> ListPrefixResult? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  match.range.location == 0 else {
                return nil
            }
            let numberValue: Int? = match.numberOfRanges > 1
                ? (Range(match.range(at: 1), in: line).flatMap { Int(String(line[$0])) })
                : nil
            return ListPrefixResult(length: match.range.length, numberValue: numberValue)
        }

        /// 通知外部当前格式状态
        private func notifyFormatState(_ typingAttributes: [NSAttributedString.Key: Any]) {
            onFormatStateChange?(TypingFormatState(
                isBold: (typingAttributes[.holoBold] as? Bool) == true,
                isItalic: (typingAttributes[.holoItalic] as? Bool) == true,
                isUnderline: (typingAttributes[.holoUnderline] as? Bool) == true,
                colorHex: typingAttributes[.holoColorHex] as? String
            ))
        }
    }
}

// MARK: - 富文本转换

// 注：此 extension 保持 internal（勿改回 private）——HoloTests 的 MarkdownTextViewNodePipelineTests
// 依赖 makeAttributedText(from: String) / baseAttributes 入口（2026-08-16 恢复，曾被误私有化导致测试 target 编不过）
extension MarkdownTextView {
    struct RenderStyle {
        var isBold = false
        var isItalic = false
        var isUnderline = false
        var colorHex: String?
        /// 列表项使用悬挂缩进：首行保留项目符号，换行后正文与首行文字对齐。
        var listHeadIndent: CGFloat?
    }

    /// 与卡片/详情正文一致的动态正文基线：系统 Body 17pt、Regular，随 Dynamic Type 缩放。
    static var baseFont: UIFont {
        UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .regular))
    }
    static let baseTextColor = UIColor(Color.holoTextPrimary)
    /// 列表缩进随正文 Dynamic Type 放大，默认字号保持约 24pt 的紧凑阅读基线。
    private static var listContentIndent: CGFloat {
        max(24, baseFont.pointSize * 1.4)
    }
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: baseTextColor,
            .paragraphStyle: baseParagraphStyle()
        ]
    }

    private static func baseParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        return style
    }

    /// 编辑态行高基线：行高 = 字号 × 1.5（中文正文的舒适行距）。
    /// 阅读态（列表卡片/详情页）维持 6pt 的紧凑基线：编辑器优先输入体验，列表优先信息密度。
    /// 行距按当前字号计算，Dynamic Type 放大后比例不漂移。
    static func editorLineSpacing(for font: UIFont) -> CGFloat {
        max(0, font.pointSize * 1.5 - font.lineHeight)
    }

    /// 把整段富文本的行距统一替换为编辑态基线（保留列表悬挂缩进等其他段落设置）。
    /// 打字产生的新文字走 typingAttributes；整段重建（初次渲染、Dynamic Type 变化、
    /// rich JSON 水合、应用内粘贴）走本函数，两条路径保持同一密度。
    static func applyingEditorLineSpacing(to source: NSAttributedString) -> NSAttributedString {
        guard source.length > 0 else { return source }
        let mutable = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.enumerateAttribute(.paragraphStyle, in: fullRange) { _, range, _ in
            let segmentFont = (mutable.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont) ?? baseFont
            guard let style = mutable.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                  let mutableStyle = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            mutableStyle.lineSpacing = editorLineSpacing(for: segmentFont)
            mutable.addAttribute(.paragraphStyle, value: mutableStyle, range: range)
        }
        return mutable
    }

    fileprivate static func paragraphStyle(forList isList: Bool) -> NSParagraphStyle {
        let style = baseParagraphStyle().mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = isList ? listContentIndent : 0
        return style
    }

    static func makeAttributedText(from markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()

        // 兼容旧版本曾生成的「格式标记包住换行」内容，例如 `**\n\n正文**`。
        // 新序列化不会再产生这种结构，但历史数据不能继续把 ** 当作普通文字展示。
        let markdown = repairedMarkdownBoundaryMarkers(markdown)

        // MarkdownParser 会把空行当作块之间的分隔并直接跳过；如果整段文本一次性解析，
        // 「第一段\n\n第二段」重渲染后会变成「第一段\n第二段」。按连续非空行分块解析，
        // 再把原始空行数量写回富文本，保证保存/重进不会改变用户的段落结构。
        let lines = markdown.components(separatedBy: "\n")
        let hasNonBlankLine = lines.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard hasNonBlankLine else {
            return NSAttributedString(string: markdown, attributes: baseAttributes)
        }

        var index = 0
        var hasRenderedBlock = false
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                let blankStart = index
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                }

                let blankLineCount = index - blankStart
                let hasFollowingBlock = index < lines.count
                // 块之间的 k 个空行对应 k+1 个换行；首尾空行则按原数量保留。
                let newlineCount = hasRenderedBlock && hasFollowingBlock
                    ? blankLineCount + 1
                    : blankLineCount
                if newlineCount > 0 {
                    result.append(NSAttributedString(
                        string: String(repeating: "\n", count: newlineCount),
                        attributes: baseAttributes
                    ))
                }
                continue
            }

            let blockStart = index
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            }
            let block = lines[blockStart..<index].joined(separator: "\n")
            let document = MarkdownParser.parse(block)
            for (nodeIndex, node) in document.children.enumerated() {
                append(node: node, to: result, style: RenderStyle())
                if nodeIndex < document.children.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: baseAttributes))
                }
            }
            if !document.children.isEmpty {
                hasRenderedBlock = true
            }
        }

        applyListParagraphStyles(to: result)
        return result
    }

    /// 将旧版格式标记从段落边界外移回有实际内容的行内。
    /// 仅处理编辑器已知的 Markdown 格式标记，不触碰普通正文中的其他字符。
    private static func repairedMarkdownBoundaryMarkers(_ markdown: String) -> String {
        guard markdown.contains("\n") else { return markdown }

        func openingMarker(atStartOf value: String) -> String? {
            if value.hasPrefix("**") { return "**" }
            if value.hasPrefix("++") { return "++" }
            if value.hasPrefix("*") { return "*" }
            if value.hasPrefix("{color:") {
                guard let end = value.firstIndex(of: "}") else { return nil }
                return String(value[...end])
            }
            return nil
        }

        let closingMarkers = ["{/color}", "**", "++", "*"]
        var body = markdown
        var leadingCandidate = body
        var leadingMarkers = ""
        while let marker = openingMarker(atStartOf: leadingCandidate) {
            leadingMarkers += marker
            leadingCandidate.removeFirst(marker.count)
        }

        // 只有格式标记后紧跟换行，才说明它是旧版本错误包住段落边界的标记。
        // 正常的「**行内文字**」不能被当成边界修复，否则会丢失闭合标记。
        let leadingNewlineCount = leadingCandidate.prefix { $0 == "\n" }.count
        if !leadingMarkers.isEmpty, leadingNewlineCount > 0 {
            let newlines = String(leadingCandidate.prefix(leadingNewlineCount))
            body = newlines + leadingMarkers + String(leadingCandidate.dropFirst(leadingNewlineCount))
        }

        var trailingCandidate = body
        var trailingMarkers = ""
        while let marker = closingMarkers.first(where: { trailingCandidate.hasSuffix($0) }) {
            trailingMarkers = marker + trailingMarkers
            trailingCandidate.removeLast(marker.count)
        }

        // 同理，只有闭合标记后面还有换行，才把它移到最后一个实际内容行之前。
        // 没有尾部换行时保留原始候选，避免误删正常行内格式的闭合标记。
        let trailingNewlineCount = trailingCandidate.reversed().prefix { $0 == "\n" }.count
        if !trailingMarkers.isEmpty, trailingNewlineCount > 0 {
            let contentLength = trailingCandidate.count - trailingNewlineCount
            let content = String(trailingCandidate.prefix(contentLength))
            let newlines = String(trailingCandidate.suffix(trailingNewlineCount))
            body = content + trailingMarkers + newlines
        }

        return body
    }

    static func append(node: MarkdownNode, to result: NSMutableAttributedString, style: RenderStyle) {
        switch node {
        case let textNode as TextNode:
            result.append(NSAttributedString(string: textNode.text, attributes: attributes(for: style)))

        case let paragraph as ParagraphNode:
            appendInlineNodes(paragraph.children, to: result, style: style)

        case let bold as BoldNode:
            var nextStyle = style
            nextStyle.isBold = true
            appendInlineNodes(bold.children, to: result, style: nextStyle)

        case let italic as ItalicNode:
            var nextStyle = style
            nextStyle.isItalic = true
            appendInlineNodes(italic.children, to: result, style: nextStyle)

        case let underline as UnderlineNode:
            var nextStyle = style
            nextStyle.isUnderline = true
            appendInlineNodes(underline.children, to: result, style: nextStyle)

        case let colored as ColoredNode:
            var nextStyle = style
            nextStyle.colorHex = colored.colorHex
            appendInlineNodes(colored.children, to: result, style: nextStyle)

        case let tag as InlineTagNode:
            var tagAttrs = attributes(for: style)
            tagAttrs[.foregroundColor] = UIColor(Color.holoPrimary)
            result.append(NSAttributedString(string: "#\(tag.tagName)", attributes: tagAttrs))

        case let item as UnorderedListItemNode:
            var listStyle = style
            listStyle.listHeadIndent = Self.listContentIndent
            var bulletAttrs = attributes(for: listStyle)
            bulletAttrs[.foregroundColor] = UIColor(Color.holoTextSecondary)
            result.append(NSAttributedString(string: "\u{2022} ", attributes: bulletAttrs))
            appendInlineNodes(item.children, to: result, style: listStyle)

        case let item as OrderedListItemNode:
            var listStyle = style
            listStyle.listHeadIndent = Self.listContentIndent
            var numberAttrs = attributes(for: listStyle)
            numberAttrs[.foregroundColor] = UIColor(Color.holoTextSecondary)
            result.append(NSAttributedString(string: "\(item.index). ", attributes: numberAttrs))
            appendInlineNodes(item.children, to: result, style: listStyle)

        default:
            break
        }
    }

    static func appendInlineNodes(_ nodes: [MarkdownNode], to result: NSMutableAttributedString, style: RenderStyle) {
        for node in nodes {
            append(node: node, to: result, style: style)
        }
    }

}

// MARK: - 节点管线（internal，供单测验证往返一致性）

extension MarkdownTextView {

    /// 已结构化 Token 的可见文字也含有 #/@，不能把它误判成新的输入触发片段。
    /// 该判断独立成纯函数，便于对存量引用和普通文本分别做回归验证。
    static func triggerIntersectsToken(
        _ context: EditorTriggerContext,
        in attributedText: NSAttributedString
    ) -> Bool {
        tokenRanges(in: attributedText).contains {
            NSIntersectionRange($0, context.range).length > 0
        }
    }

    /// 返回非空替换选区触碰到的任务作用范围 ID。
    ///
    /// 普通源文字和引用/标签 Token 都可能携带 holoTaskId；统一从属性读取，
    /// 让键盘替换、粘贴覆盖 Token 时不会因为 Token 不在 source span 内而丢失任务关系。
    static func taskScopeIDsTouchingRange(
        _ range: NSRange,
        in attributedText: NSAttributedString
    ) -> Set<String> {
        guard range.length > 0, attributedText.length > 0 else { return [] }
        let safeRange = clampedRange(range, for: attributedText.length)
        guard safeRange.length > 0 else { return [] }

        var taskIds = Set<String>()
        attributedText.enumerateAttribute(.holoTaskId, in: safeRange, options: []) { value, _, _ in
            if let taskId = value as? String {
                taskIds.insert(taskId)
            }
        }
        return taskIds
    }

    /// Token 取消关系后回到普通文字，但保留用户在 Token 上施加的格式和任务作用范围。
    /// 只清理 Token 专属的身份/背景属性，避免“取消引用”顺带把颜色、粗体或下划线抹掉。
    static func plainTextAttributes(
        afterRemovingToken tokenAttributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var preserved = tokenAttributes
        preserved.removeValue(forKey: .holoTokenType)
        preserved.removeValue(forKey: .holoEntityId)
        preserved.removeValue(forKey: .holoTokenInstanceId)
        preserved.removeValue(forKey: .holoDisplayText)
        preserved.removeValue(forKey: .holoSnapshot)
        preserved.removeValue(forKey: .backgroundColor)
        preserved.removeValue(forKey: .attachment)
        return resolvedAttributes(from: preserved)
    }

    /// 节点 → 用户可见的复制文本。普通 text 节点先经过 Markdown 渲染，避免把 `**`、`++`
    /// 等存储标记复制到其他 App；Token 则保留可读的 #/@ 前缀，任务关系标记不输出占位字符。
    static func visiblePlainText(from nodes: [HoloContentNode]) -> String {
        nodes.map { node in
            switch node {
            case .text(let value):
                return makeAttributedText(from: value).string
            case .tag(_, let displayPath):
                return "#\(displayPath)"
            case .reference(_, let displayText, _):
                return "@\(displayText)"
            case .taskMark:
                return ""
            }
        }.joined()
    }

    /// 应用内剪贴板允许复制正文、引用和标签；任务标记是依附正文的关系附件，不单独跨编辑器传播。
    static func clipboardSafeNodes(from nodes: [HoloContentNode]) -> [HoloContentNode] {
        nodes.filter { node in
            if case .taskMark = node { return false }
            return true
        }
    }

    /// 在富文本中批量写入任务关系标记。
    /// 入参范围统一使用用户可见文本坐标，内部负责映射到包含附件的存储坐标。
    /// 从后往前插入，保证同一批多个来源范围不会因前面的附件改变偏移。
    static func attributedTextByInsertingTaskMarks(
        _ insertions: [TaskMarkInsertion],
        into attributedText: NSAttributedString
    ) -> NSMutableAttributedString? {
        guard !insertions.isEmpty else { return nil }

        let mutable = NSMutableAttributedString(attributedString: attributedText)
        var acceptedRanges: [NSRange] = []

        for insertion in insertions.sorted(by: {
            $0.sourceRange.location > $1.sourceRange.location
        }) {
            guard let requestedRange = storageRange(
                forVisibleRange: insertion.sourceRange,
                in: mutable
            ) else {
                continue
            }

            let sourceRange = trimmedRange(requestedRange, in: mutable.string as NSString)
            let insertLocation = NSMaxRange(sourceRange)
            guard sourceRange.length > 0,
                  insertLocation <= mutable.length,
                  !acceptedRanges.contains(where: {
                      NSIntersectionRange($0, sourceRange).length > 0
                  }) else {
                continue
            }

            mutable.addAttribute(
                .holoTaskId,
                value: insertion.taskId.uuidString,
                range: sourceRange
            )
            mutable.addAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: sourceRange
            )
            mutable.insert(
                // 任务标记与 Token 同理：行首时决定整行行距，用编辑态基线插入
                applyingEditorLineSpacing(to: makeTaskMarkAttributedText(
                    id: UUID(),
                    taskId: insertion.taskId,
                    displayText: insertion.displayText,
                    sourceLength: sourceRange.length
                )),
                at: insertLocation
            )
            acceptedRanges.append(sourceRange)
        }

        return acceptedRanges.isEmpty ? nil : mutable
    }

    /// 阅读态和辅助功能使用的可读文本：保留正文顺序，并把不可见的任务附件展开成语义描述。
    /// UIKit 的 NSTextAttachment 默认可能被读成 U+FFFC，占位符对用户没有意义。
    ///
    /// 结果按节点内容做进程级缓存：卡片/阅读视图每次重渲染（点「…」弹菜单、整理队列
    /// 状态变化）都会重新求值 accessibilityValue，而 text 节点要走完整
    /// Markdown→NSAttributedString 管线才能拿到纯文本（长文几十 ms 的主线程卡顿）；
    /// 渲染输入不变时这里直接命中缓存。
    private static let accessibilityTextCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 200
        return cache
    }()

    /// 按原始内容字符串为键的第二级缓存：卡片每次重渲染（点「…」弹菜单、整理队列
    /// 状态变化都会触发全列表重算）时无需解码 JSON 就能命中朗读文本，把卡片重算
    /// 的内容成本从 O(笔记长度) 降到 O(1)。
    /// 键约定：富文本用 JSON 串本身（不可变 NSString 桥接零拷贝），存量平文本加
    /// "P\0" 前缀防两类内容互相碰撞。
    private static let accessibilityTextBySourceCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        return cache
    }()

    static func accessibilityText(richJSON: String?, fallbackPlainText: String) -> String {
        let sourceKey: NSString = richJSON.flatMap { $0.isEmpty ? nil : ($0 as NSString) }
            ?? ("P\u{0}" + fallbackPlainText) as NSString
        if let cached = accessibilityTextBySourceCache.object(forKey: sourceKey) {
            return cached as String
        }
        let nodes = RichContentSerializer.nodes(richJSON: richJSON, fallbackPlainText: fallbackPlainText)
        let result = accessibilityText(from: nodes)
        accessibilityTextBySourceCache.setObject(result as NSString, forKey: sourceKey)
        return result
    }

    static func accessibilityText(from nodes: [HoloContentNode]) -> String {
        let cacheKey = accessibilityTextCacheKey(nodes) as NSString
        if let cached = accessibilityTextCache.object(forKey: cacheKey) {
            return cached as String
        }
        let result = nodes.map { node in
            switch node {
            case .text(let value):
                return makeAttributedText(from: value).string
            case .tag(_, let displayPath):
                return String(localized: "标签：#\(displayPath)")
            case .reference(_, let displayText, _):
                return String(localized: "引用：@\(displayText)")
            case .taskMark(_, _, let displayText, _):
                return displayText.isEmpty ? String(localized: "已转为任务") : String(localized: "已转为任务：\(displayText)")
            }
        }.joined(separator: " ")
        accessibilityTextCache.setObject(result as NSString, forKey: cacheKey)
        return result
    }

    /// 缓存键：每个字段带长度前缀再拼接，任意内容（含分隔符本身）都不会产生碰撞。
    private static func accessibilityTextCacheKey(_ nodes: [HoloContentNode]) -> String {
        var key = ""
        for node in nodes {
            switch node {
            case .text(let value):
                key += "t\(value.utf16.count)|\(value)"
            case .tag(let id, let displayPath):
                key += "g\(id.uuidString)|\(displayPath)"
            case .reference(let noteId, let displayText, let snapshot):
                key += "r\(noteId.uuidString)|\(displayText.utf16.count)|\(displayText)|\(snapshot.utf16.count)|\(snapshot)"
            case .taskMark(let id, let taskId, let displayText, _):
                key += "k\(id.uuidString)|\(taskId.uuidString)|\(displayText.utf16.count)|\(displayText)"
            }
        }
        return key
    }

    /// 编辑态辅助功能值：与 UITextView 的存储字符串保持相同 UTF-16 长度。
    ///
    /// 引用、标签和任务在富文本内部都是一个原子附件；不能把一个附件展开成多字符
    /// 的“引用：@标题”后再交给可编辑 UITextView，否则系统选区范围会和真实存储坐标
    /// 错位。这里用单字符标记保留编辑坐标，完整标题和任务说明由 Hint 提供。
    static func editableAccessibilityText(from attributedText: NSAttributedString) -> String {
        guard attributedText.length > 0 else { return "" }

        let tokenRanges = tokenRanges(in: attributedText).sorted { $0.location < $1.location }
        let rawString = attributedText.string as NSString
        var result = ""
        var cursor = 0

        for tokenRange in tokenRanges {
            guard tokenRange.location >= cursor,
                  NSMaxRange(tokenRange) <= attributedText.length else { continue }

            if tokenRange.location > cursor {
                result += rawString.substring(
                    with: NSRange(location: cursor, length: tokenRange.location - cursor)
                )
            }

            let rawType = attributedText.attribute(
                .holoTokenType,
                at: tokenRange.location,
                effectiveRange: nil
            ) as? String
            switch HoloTokenType(rawValue: rawType ?? "") {
            case .tag:
                result += "#"
            case .reference:
                result += "@"
            case .taskMark:
                result += "✓"
            case nil:
                // 残缺属性的附件仍按一个字符保留坐标，不让辅助功能范围漂移。
                result += "�"
            }
            cursor = NSMaxRange(tokenRange)
        }

        if cursor < attributedText.length {
            result += rawString.substring(
                with: NSRange(location: cursor, length: attributedText.length - cursor)
            )
        }
        return result
    }

    /// 编辑态辅助功能提示：提供 Token 的完整可读语义，但不参与可编辑文本坐标计算。
    static func editableAccessibilityHint(from nodes: [HoloContentNode]) -> String {
        var parts: [String] = []
        for node in nodes {
            switch node {
            case .tag(_, let displayPath):
                parts.append(String(localized: "标签：#\(displayPath)"))
            case .reference(_, let displayText, _):
                parts.append(String(localized: "引用：@\(displayText)"))
            case .taskMark(_, _, let displayText, _):
                parts.append(displayText.isEmpty ? String(localized: "已转为任务") : String(localized: "已转为任务：\(displayText)"))
            case .text:
                break
            }
        }
        return parts.joined(separator: "；")
    }

    /// 将节点写入应用内语义剪贴板，同时提供可读纯文本给其他 App。
    static func copyNodesToPasteboard(_ nodes: [HoloContentNode]) {
        guard !nodes.isEmpty,
              let json = try? RichContentSerializer.jsonString(from: nodes),
              let data = json.data(using: .utf8) else { return }

        let plainText = visiblePlainText(from: nodes)
        UIPasteboard.general.setItems([[
            "public.utf8-plain-text": plainText,
            "public.text": plainText,
            semanticPasteboardType: data
        ]])
    }

    /// 节点模型 → 富文本：text 节点走 Markdown 渲染，Token 节点渲染为带身份属性的整体样式
    /// 注意：Markdown 格式仅在单个 text 节点内部生效，跨 Token 的格式（如加粗包住 Token）不展开
    /// - Parameter deletedReferenceIds: 目标已删除的引用 ID 集合（阅读态渲染为灰色「原记录已删除」）
    static func makeAttributedText(from nodes: [HoloContentNode], deletedReferenceIds: Set<UUID> = []) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for node in nodes {
            switch node {
            case .text(let value):
                result.append(makeAttributedText(from: value))
            case .tag(let id, let displayPath):
                result.append(makeTokenAttributedText(type: .tag, id: id, displayText: displayPath, snapshot: nil))
            case .reference(let noteId, let displayText, let snapshot):
                let isDeleted = deletedReferenceIds.contains(noteId)
                result.append(makeTokenAttributedText(type: .reference, id: noteId, displayText: displayText, snapshot: snapshot, isDeleted: isDeleted))
            case .taskMark(let id, let taskId, let displayText, let sourceLength):
                // taskMark 位于作用范围之后。按持久化的相对长度回标前文，
                // 不再用重复文本搜索，避免同一句话出现多次时下划线命中错误位置。
                let safeSourceLength = min(max(0, sourceLength), result.length)
                if safeSourceLength > 0 {
                    let sourceRange = NSRange(
                        location: result.length - safeSourceLength,
                        length: safeSourceLength
                    )
                    result.addAttribute(.holoTaskId, value: taskId.uuidString, range: sourceRange)
                    result.addAttribute(
                        .underlineStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: sourceRange
                    )
                }
                result.append(makeTaskMarkAttributedText(
                    id: id,
                    taskId: taskId,
                    displayText: displayText,
                    sourceLength: sourceLength
                ))
            }
        }

        if result.length == 0 {
            return NSAttributedString(string: "", attributes: baseAttributes)
        }

        applyListParagraphStyles(to: result)
        return result
    }

    /// 编辑器把列表前缀作为可编辑正文保存；某些存量内容或 Markdown 解析路径会把
    /// `• ` 当作普通文字而不是列表节点。最终渲染时按可见行补回段落缩进，保证编辑态、
    /// 卡片预览和详情页不会因为解析分支不同而出现第二行顶格。
    private static func applyListParagraphStyles(to attributedText: NSMutableAttributedString) {
        guard attributedText.length > 0 else { return }

        let text = attributedText.string as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        for lineStart in lineStartLocations(in: text, for: fullRange) {
            let remainingLength = text.length - lineStart
            let newlineRange = text.range(
                of: "\n",
                options: [],
                range: NSRange(location: lineStart, length: remainingLength)
            )
            let lineEnd = newlineRange.location == NSNotFound
                ? text.length
                : newlineRange.location
            let lineLength = max(0, lineEnd - lineStart)
            guard lineLength > 0 else { continue }

            let line = text.substring(with: NSRange(location: lineStart, length: lineLength))
            let isUnordered = line.hasPrefix("• ")
                || line.hasPrefix("- ")
                || line.hasPrefix("* ")
            let isOrdered = line.range(
                of: "^\\d+\\. ",
                options: .regularExpression
            ) != nil
            let style = paragraphStyle(forList: isUnordered || isOrdered)
            attributedText.addAttribute(
                .paragraphStyle,
                value: style,
                range: NSRange(location: lineStart, length: lineLength)
            )
        }
    }

    /// 富文本 → 节点模型：Token 属性区间还原为 Token 节点，普通区间按 Markdown 序列化合并为 text 节点
    /// Token 属性残缺（如被部分删除）时降级为普通文本，保证文字不丢
    static func serializeNodes(from attributedText: NSAttributedString) -> [HoloContentNode] {
        guard attributedText.length > 0 else { return [] }

        var nodes: [HoloContentNode] = []
        var textBuffer = ""
        var lastTokenNode: HoloContentNode?
        var lastTokenInstanceId: String?
        var lastTokenEnd = 0

        func flushTextBuffer() {
            guard !textBuffer.isEmpty else { return }
            nodes.append(.text(value: textBuffer))
            textBuffer = ""
        }

        attributedText.enumerateAttributes(in: NSRange(location: 0, length: attributedText.length), options: []) { attrs, range, _ in
            let text = attributedText.attributedSubstring(from: range).string

            if let tokenNode = makeTokenNode(from: attrs) {
                flushTextBuffer()
                // 一个 Token 可能因用户给其中一段加粗、改色或布局刷新而被拆成多个
                // 属性区间。属性区间不是业务节点，连续且身份相同的区间必须合并，
                // 否则保存时会把一次 @ 引用写成多条关系。
                let tokenInstanceId = attrs[.holoTokenInstanceId] as? String
                let sameTokenInstance = tokenInstanceId != nil
                    ? tokenInstanceId == lastTokenInstanceId
                    : lastTokenNode == tokenNode
                if !sameTokenInstance || lastTokenEnd != range.location {
                    nodes.append(tokenNode)
                }
                lastTokenNode = tokenNode
                lastTokenInstanceId = tokenInstanceId
                lastTokenEnd = NSMaxRange(range)
            } else {
                textBuffer += markdownFragment(for: attrs, text: text)
                lastTokenNode = nil
                lastTokenInstanceId = nil
                lastTokenEnd = 0
            }
        }
        flushTextBuffer()

        return nodes
    }
}

extension MarkdownTextView {

    /// Token 行内样式：品牌色文字 + 浅色背景 + 身份属性（类型/实体 ID/展示快照）
    /// isDeleted=true 时渲染为灰色「原记录已删除」（仅引用 Token 使用，保留身份属性供点击取快照）
    ///
    /// 视觉规格（正文 17pt 基线）：
    /// - 字号 15pt medium：比正文小一档，读作「标签」而不是「一段有底色的正文」；
    /// - baselineOffset 下沉：小字号在正文行框里垂直居中，色块上下不再贴死字形；
    /// - 首尾各一个同属性空格承担水平留白（背景色随之延伸，等效胶囊的左右 padding）；
    /// - #/@ 前缀同色 65% 透明度弱化，主体文字保持全色。
    /// 留白空格只存在于渲染层：序列化与复制都走 holoDisplayText 属性，不会进入存储或外发文本。
    static func makeTokenAttributedText(type: HoloTokenType, id: UUID, displayText: String, snapshot: String?, isDeleted: Bool = false) -> NSAttributedString {
        var attributes = baseAttributes
        attributes[.font] = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .medium))
        attributes[.baselineOffset] = NSNumber(value: -1)
        let tokenColor: UIColor
        if isDeleted {
            tokenColor = UIColor(Color.holoTextSecondary)
            attributes[.foregroundColor] = tokenColor
            attributes[.backgroundColor] = UIColor(Color.holoTextSecondary.opacity(0.12))
        } else {
            // 品牌主色用于背景和强调控件；作为浅色模式正文色时对比度偏低。
            // Token 改用深橙，深色模式使用浅橙，既保留品牌识别又保证长标题可读。
            tokenColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(Color.holoPrimaryLight)
                    : UIColor(Color.holoPrimaryDark)
            }
            attributes[.foregroundColor] = tokenColor
            attributes[.backgroundColor] = UIColor(Color.holoPrimary.opacity(0.12))
        }
        attributes[.holoTokenType] = type.rawValue
        attributes[.holoEntityId] = id.uuidString
        // 实体 ID 可能重复（同一条笔记被连续引用两次），必须额外保留 Token 实例身份。
        attributes[.holoTokenInstanceId] = UUID().uuidString
        attributes[.holoDisplayText] = displayText
        if let snapshot {
            attributes[.holoSnapshot] = snapshot
        }

        let prefix = type == .tag ? "#" : "@"
        let normalizedDisplayText = type == .reference
            ? RichContentSerializer.normalizedReferenceDisplayText(
                displayText: displayText,
                snapshot: snapshot ?? ""
            )
            : displayText
        let visibleText = isDeleted ? String(localized: "原记录已删除") : normalizedDisplayText

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: " ", attributes: attributes))
        var prefixAttributes = attributes
        prefixAttributes[.foregroundColor] = tokenColor.withAlphaComponent(0.65)
        result.append(NSAttributedString(string: prefix, attributes: prefixAttributes))
        result.append(NSAttributedString(string: visibleText, attributes: attributes))
        result.append(NSAttributedString(string: " ", attributes: attributes))
        return result
    }

    /// 任务关系 Token：一个不可拆分的「清单图标 + 任务」附件。
    /// 它比正文更小、更轻，明确属于系统元数据；也不会像长胶囊一样挤压或覆盖用户文字。
    static func makeTaskMarkAttributedText(
        id: UUID,
        taskId: UUID,
        displayText: String,
        sourceLength: Int
    ) -> NSAttributedString {
        var attributes = baseAttributes
        attributes[.holoTokenType] = HoloTokenType.taskMark.rawValue
        attributes[.holoEntityId] = id.uuidString
        // taskMark 的节点 ID 本身就是唯一实例 ID；显式写入统一属性，便于属性拆分后合并。
        attributes[.holoTokenInstanceId] = id.uuidString
        attributes[.holoTaskId] = taskId.uuidString
        attributes[.holoDisplayText] = displayText
        attributes[.holoTaskSourceLength] = max(0, sourceLength)
        let result = NSMutableAttributedString(attachment: TaskLinkAttachment(displayText: displayText))
        result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// 从富文本属性还原 Token 节点；属性不完整时返回 nil（降级为普通文本）
    static func makeTokenNode(from attrs: [NSAttributedString.Key: Any]) -> HoloContentNode? {
        guard let rawType = attrs[.holoTokenType] as? String,
              let type = HoloTokenType(rawValue: rawType),
              let idString = attrs[.holoEntityId] as? String,
              let id = UUID(uuidString: idString),
              let displayText = attrs[.holoDisplayText] as? String else {
            return nil
        }

        switch type {
        case .tag:
            return .tag(id: id, displayPath: displayText)
        case .reference:
            let snapshot = attrs[.holoSnapshot] as? String ?? ""
            return .reference(
                noteId: id,
                displayText: RichContentSerializer.normalizedReferenceDisplayText(
                    displayText: displayText,
                    snapshot: snapshot
                ),
                snapshot: snapshot
            )
        case .taskMark:
            guard let taskIdString = attrs[.holoTaskId] as? String,
                  let taskId = UUID(uuidString: taskIdString) else {
                return nil
            }
            let sourceLength = (attrs[.holoTaskSourceLength] as? NSNumber)?.intValue
                ?? (attrs[.holoTaskSourceLength] as? Int)
                ?? displayText.utf16.count
            return .taskMark(
                id: id,
                taskId: taskId,
                displayText: displayText,
                sourceLength: max(0, sourceLength)
            )
        }
    }

    /// 全部 Token 区间（按 Token 实例 ID 合并被属性拆开的同一 Token，不合并相邻独立实例）
    static func tokenRanges(in attributedText: NSAttributedString) -> [NSRange] {
        guard attributedText.length > 0 else { return [] }
        var ranges: [NSRange] = []
        var lastNode: HoloContentNode?
        var lastTokenInstanceId: String?
        var lastRange: NSRange?

        attributedText.enumerateAttributes(in: NSRange(location: 0, length: attributedText.length), options: []) { attrs, range, _ in
            guard let node = makeTokenNode(from: attrs) else {
                lastNode = nil
                lastRange = nil
                return
            }

            let tokenInstanceId = attrs[.holoTokenInstanceId] as? String
            let sameTokenInstance = tokenInstanceId != nil
                ? tokenInstanceId == lastTokenInstanceId
                : lastNode == node
            if let previous = lastRange,
               sameTokenInstance,
               NSMaxRange(previous) == range.location {
                lastRange = NSUnionRange(previous, range)
                ranges[ranges.count - 1] = lastRange!
            } else {
                ranges.append(range)
                lastNode = node
                lastTokenInstanceId = tokenInstanceId
                lastRange = range
            }
        }
        return ranges
    }

    /// 返回选区中可被普通格式动作修改的文字区间；结构化 Token 作为不可拆分语义保留。
    /// 选区可以跨过多个 Token，结果按原始顺序拆成若干普通文字片段。
    static func nonTokenRanges(
        in range: NSRange,
        attributedText: NSAttributedString
    ) -> [NSRange] {
        let safeRange = clampedRange(range, for: attributedText.length)
        guard safeRange.length > 0 else { return [] }

        let end = NSMaxRange(safeRange)
        var cursor = safeRange.location
        var result: [NSRange] = []

        for tokenRange in tokenRanges(in: attributedText) {
            guard tokenRange.location < end, NSMaxRange(tokenRange) > safeRange.location else {
                continue
            }

            let tokenStart = max(safeRange.location, tokenRange.location)
            if cursor < tokenStart {
                result.append(NSRange(location: cursor, length: tokenStart - cursor))
            }
            cursor = max(cursor, min(end, NSMaxRange(tokenRange)))
            if cursor >= end { break }
        }

        if cursor < end {
            result.append(NSRange(location: cursor, length: end - cursor))
        }
        return result.filter { $0.length > 0 }
    }

    /// 单个属性区间的 Markdown 片段（含 ** / * / ++ / {color:} 标记还原）
    static func markdownFragment(for attrs: [NSAttributedString.Key: Any], text: String) -> String {
        let colorHex = attrs[.holoColorHex] as? String
        let isBold = (attrs[.holoBold] as? Bool) == true
        let isItalic = (attrs[.holoItalic] as? Bool) == true
        let isUnderline = (attrs[.holoUnderline] as? Bool) == true

        let prefix = markdownPrefix(isBold: isBold, isItalic: isItalic, isUnderline: isUnderline, colorHex: colorHex)
        let suffix = markdownSuffix(isBold: isBold, isItalic: isItalic, isUnderline: isUnderline, colorHex: colorHex)

        guard text.contains("\n"), !prefix.isEmpty || !suffix.isEmpty else {
            return prefix + text + suffix
        }

        // 格式区间可能在任务附件/Token 后从换行开始。不能生成「**\n\n正文**」这类
        // 跨段落标记：Markdown 解析器会把前后的星号当作普通字符，保存重进后用户会
        // 看到字面量 **。按行拆开，只给真正有内容的行加格式标记，换行本身保持原样。
        return text
            .components(separatedBy: "\n")
            .map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                return prefix + line + suffix
            }
            .joined(separator: "\n")
    }

    static func markdownPrefix(isBold: Bool, isItalic: Bool, isUnderline: Bool, colorHex: String?) -> String {
        var prefix = ""
        if let colorHex {
            prefix += "{color:\(colorHex)}"
        }
        if isBold {
            prefix += "**"
        }
        if isUnderline {
            prefix += "++"
        }
        if isItalic {
            prefix += "*"
        }
        return prefix
    }

    static func markdownSuffix(isBold: Bool, isItalic: Bool, isUnderline: Bool, colorHex: String?) -> String {
        var suffix = ""
        if isItalic {
            suffix += "*"
        }
        if isUnderline {
            suffix += "++"
        }
        if isBold {
            suffix += "**"
        }
        if colorHex != nil {
            suffix += "{/color}"
        }
        return suffix
    }

    fileprivate static func attributes(for style: RenderStyle) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes
        if let listHeadIndent = style.listHeadIndent,
           let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle,
           let mutableParagraphStyle = paragraphStyle.mutableCopy() as? NSMutableParagraphStyle {
            mutableParagraphStyle.firstLineHeadIndent = 0
            mutableParagraphStyle.headIndent = listHeadIndent
            attributes[.paragraphStyle] = mutableParagraphStyle
        }
        if style.isBold {
            attributes[.holoBold] = true
        }
        if style.isItalic {
            attributes[.holoItalic] = true
        }
        if style.isUnderline {
            attributes[.holoUnderline] = true
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if let colorHex = style.colorHex {
            attributes[.holoColorHex] = colorHex
            attributes[.foregroundColor] = resolvedTextColor(for: colorHex)
        }
        attributes[.font] = font(from: attributes)
        if attributes[.underlineStyle] == nil {
            attributes[.underlineStyle] = 0
        }
        return attributes
    }

    static func resolvedAttributes(from source: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes
        for (key, value) in source {
            attributes[key] = value
        }
        attributes[.font] = font(from: attributes)
        if (attributes[.holoUnderline] as? Bool) == true {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        } else if !hasTaskUnderline(in: attributes) {
            // 任务作用范围使用 underlineStyle 展示，但不使用 holoUnderline，
            // 这样用户取消任务时不会误认为那是手动下划线。普通格式重算时
            // 必须保留这条系统下划线，不能被统一样式清零。
            attributes[.underlineStyle] = 0
        }
        if let colorHex = attributes[.holoColorHex] as? String {
            attributes[.foregroundColor] = resolvedTextColor(for: colorHex)
        } else if attributes[.holoTokenType] == nil {
            // Token 自带的前景色是关系身份视觉的一部分；没有用户颜色时不能被
            // 普通正文基线覆盖。取消 Token 后 token 属性会先被剥离，再回到正文色。
            attributes[.foregroundColor] = baseTextColor
        }
        return attributes
    }

    private static func hasTaskUnderline(in attributes: [NSAttributedString.Key: Any]) -> Bool {
        guard attributes[.holoTaskId] != nil else { return false }
        if let value = attributes[.underlineStyle] as? NSNumber {
            return value.intValue != 0
        }
        if let value = attributes[.underlineStyle] as? Int {
            return value != 0
        }
        return false
    }

    static func applyResolvedAttributes(
        _ attributes: [NSAttributedString.Key: Any],
        to attributedString: NSMutableAttributedString,
        range: NSRange
    ) {
        let resolved = resolvedAttributes(from: attributes)
        attributedString.setAttributes(resolved, range: range)
    }

    static func font(from attributes: [NSAttributedString.Key: Any]) -> UIFont {
        let isBold = (attributes[.holoBold] as? Bool) == true
        let isItalic = (attributes[.holoItalic] as? Bool) == true

        // 直接用 weight 创建字体，避免 withSymbolicTraits 在 .medium base 上效果微弱
        let weight: UIFont.Weight = isBold ? .bold : .regular
        let base = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: UIFont.systemFont(ofSize: 17, weight: weight))

        guard isItalic else { return base }

        var traits = base.fontDescriptor.symbolicTraits
        traits.insert(.traitItalic)
        guard let italicDescriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: italicDescriptor, size: baseFont.pointSize)
    }

    static func clampedRange(_ range: NSRange, for length: Int) -> NSRange {
        let safeLocation = max(0, min(range.location, length))
        let safeLength = max(0, min(range.length, length - safeLocation))
        return NSRange(location: safeLocation, length: safeLength)
    }

    /// 把用户可见文本坐标映射为富文本存储坐标。
    /// 任务关系附件在存储中占一个 U+FFFC，但不属于用户可见正文，因此需要跳过。
    static func storageRange(
        forVisibleRange visibleRange: NSRange,
        in attributedText: NSAttributedString
    ) -> NSRange? {
        guard visibleRange.location >= 0, visibleRange.length >= 0 else { return nil }

        var visibleToStorage: [Int] = []
        visibleToStorage.reserveCapacity(attributedText.length + 1)

        var storageLocation = 0
        while storageLocation < attributedText.length {
            var effectiveRange = NSRange(location: storageLocation, length: 1)
            let attributes = attributedText.attributes(
                at: storageLocation,
                effectiveRange: &effectiveRange
            )
            let isTaskAttachment = (attributes[.holoTokenType] as? String) == HoloTokenType.taskMark.rawValue

            if !isTaskAttachment {
                for offset in storageLocation..<NSMaxRange(effectiveRange) {
                    visibleToStorage.append(offset)
                }
            }
            storageLocation = NSMaxRange(effectiveRange)
        }
        visibleToStorage.append(attributedText.length)

        let visibleLength = visibleToStorage.count - 1
        guard visibleRange.location <= visibleLength,
              NSMaxRange(visibleRange) <= visibleLength else {
            return nil
        }

        let storageStart = visibleToStorage[visibleRange.location]
        let storageEnd = visibleToStorage[NSMaxRange(visibleRange)]
        return NSRange(location: storageStart, length: storageEnd - storageStart)
    }

    /// 把 UITextView 的存储坐标反向映射为用户可见文本坐标。
    /// 任务关系附件在存储中占一个 U+FFFC，但不属于用户选中的正文；选区菜单把范围
    /// 传给任务写入管线前必须先移除这部分偏移，否则正文前已有任务标记时，后文会错位。
    static func visibleRange(
        forStorageRange storageRange: NSRange,
        in attributedText: NSAttributedString
    ) -> NSRange? {
        guard storageRange.location >= 0,
              storageRange.length >= 0,
              NSMaxRange(storageRange) <= attributedText.length else {
            return nil
        }

        var storageToVisible = Array(repeating: 0, count: attributedText.length + 1)
        var storageLocation = 0
        var visibleLocation = 0

        while storageLocation < attributedText.length {
            var effectiveRange = NSRange(location: storageLocation, length: 1)
            let attributes = attributedText.attributes(
                at: storageLocation,
                effectiveRange: &effectiveRange
            )
            let isTaskAttachment = (attributes[.holoTokenType] as? String) == HoloTokenType.taskMark.rawValue

            if isTaskAttachment {
                for boundary in storageLocation...NSMaxRange(effectiveRange) {
                    storageToVisible[boundary] = visibleLocation
                }
            } else {
                for offset in storageLocation..<NSMaxRange(effectiveRange) {
                    storageToVisible[offset] = visibleLocation
                    visibleLocation += 1
                    storageToVisible[offset + 1] = visibleLocation
                }
            }
            storageLocation = NSMaxRange(effectiveRange)
        }

        let visibleStart = storageToVisible[storageRange.location]
        let visibleEnd = storageToVisible[NSMaxRange(storageRange)]
        return NSRange(location: visibleStart, length: visibleEnd - visibleStart)
    }

    /// UIKit 的 selectedRange 使用 UTF-16 偏移；不能用 Swift Character 数量计算行首，
    /// 否则前文含 emoji、旗帜或组合字符时，列表续行会落在错误位置。
    static func lineStart(in text: NSString, before location: Int) -> Int {
        let safeLocation = max(0, min(location, text.length))
        guard safeLocation > 0 else { return 0 }

        let newline = text.range(
            of: "\n",
            options: .backwards,
            range: NSRange(location: 0, length: safeLocation)
        )
        guard newline.location != NSNotFound else { return 0 }
        return NSMaxRange(newline)
    }

    /// 返回选区覆盖到的每一行行首（使用 UIKit 相同的 UTF-16 坐标）。
    /// 选区为空时只返回光标所在行；选区恰好在换行符结束时，不额外包含下一行空行。
    static func lineStartLocations(in text: NSString, for range: NSRange) -> [Int] {
        let safeRange = clampedRange(range, for: text.length)
        let firstStart = lineStart(in: text, before: safeRange.location)
        guard safeRange.length > 0, text.length > 0 else { return [firstStart] }

        let lastProbe = max(
            safeRange.location,
            min(NSMaxRange(safeRange) - 1, text.length - 1)
        )
        let lastStart = lineStart(in: text, before: lastProbe)
        guard lastStart > firstStart else { return [firstStart] }

        var starts = [firstStart]
        var cursor = firstStart
        while cursor < lastStart {
            let remaining = text.length - cursor
            let newline = text.range(
                of: "\n",
                options: [],
                range: NSRange(location: cursor, length: remaining)
            )
            guard newline.location != NSNotFound else { break }
            let nextStart = NSMaxRange(newline)
            guard nextStart <= lastStart else { break }
            starts.append(nextStart)
            cursor = nextStart
        }
        return starts
    }

    /// 去除选区首尾空白，但不改变中间内容和用户选中的相对位置。
    /// 任务转换、复制等动作必须以真实选区为边界，不能通过展示文字反向搜索。
    static func trimmedRange(_ range: NSRange, in text: NSString) -> NSRange {
        var start = max(0, min(range.location, text.length))
        var end = max(start, min(NSMaxRange(range), text.length))

        while start < end {
            let character = text.substring(with: NSRange(location: start, length: 1))
            guard character.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { break }
            start += 1
        }
        while end > start {
            let character = text.substring(with: NSRange(location: end - 1, length: 1))
            guard character.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { break }
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    static func rangeHasAttribute(_ key: NSAttributedString.Key, in attributedText: NSAttributedString, range: NSRange) -> Bool {
        guard range.length > 0 else { return false }

        var allMatch = true
        attributedText.enumerateAttribute(key, in: range, options: []) { value, _, stop in
            if (value as? Bool) != true {
                allMatch = false
                stop.pointee = true
            }
        }
        return allMatch
    }

    static func inlineAttributes(at location: Int, in attributedText: NSAttributedString) -> [NSAttributedString.Key: Any] {
        guard attributedText.length > 0, location < attributedText.length else {
            return [:]
        }

        let attrs = attributedText.attributes(at: location, effectiveRange: nil)
        var inline: [NSAttributedString.Key: Any] = [:]
        if let isBold = attrs[.holoBold] as? Bool, isBold {
            inline[.holoBold] = true
        }
        if let isItalic = attrs[.holoItalic] as? Bool, isItalic {
            inline[.holoItalic] = true
        }
        if let isUnderline = attrs[.holoUnderline] as? Bool, isUnderline {
            inline[.holoUnderline] = true
        }
        if let colorHex = attrs[.holoColorHex] as? String {
            inline[.holoColorHex] = colorHex
            inline[.foregroundColor] = resolvedTextColor(for: colorHex)
        }
        return inline
    }

    /// 颜色面板里的“黑色”承担恢复正文基线的产品语义。
    /// 浅色模式下它保持黑色；深色模式下沿用动态正文色，避免用户恢复颜色后文字变成黑底黑字。
    static func resolvedTextColor(for hex: String) -> UIColor {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalized == "#000000" || normalized == "000000" {
            return UIColor { traits in
                guard traits.userInterfaceStyle == .dark else { return .black }
                return UIColor(Color.holoTextPrimary).resolvedColor(with: traits)
            }
        }
        return UIColor(Color(hex: hex))
    }
}

private extension NSAttributedString.Key {
    static let holoItalic = NSAttributedString.Key("holoMarkdownItalic")
    static let holoUnderline = NSAttributedString.Key("holoMarkdownUnderline")
}

// MARK: - Task token presentation

/// 单字符附件保证任务标记不会被换行拆开；无底色、无边框，维持 iOS 编辑器的内容优先层级。
private final class TaskLinkAttachment: NSTextAttachment {

    override init(data contentData: Data?, ofType uti: String?) {
        super.init(data: contentData, ofType: uti)
        let font = Self.markerFont
        let textWidth = (String(localized: "任务") as NSString).size(withAttributes: [.font: font]).width
        bounds = CGRect(
            x: 0,
            y: -3,
            width: ceil(21 + textWidth + 5),
            height: max(18, ceil(font.lineHeight))
        )
        accessibilityLabel = String(localized: "已转为任务")
    }

    convenience init() {
        self.init(data: nil, ofType: nil)
    }

    convenience init(displayText: String) {
        self.init()
        accessibilityLabel = displayText.isEmpty ? String(localized: "已转为任务") : String(localized: "已转为任务：\(displayText)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func image(
        forBounds imageBounds: CGRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> UIImage? {
        // NSTextAttachment.image 是静态位图；在这里按绘制时的 trait 重新生成，
        // 才能保证 App 运行中切换深浅色后文字仍保持正确对比度。
        Self.makeImage()
    }

    private static func makeImage() -> UIImage {
        let font = markerFont
        let textWidth = (String(localized: "任务") as NSString).size(withAttributes: [.font: font]).width
        let size = CGSize(width: ceil(21 + textWidth + 5), height: max(18, ceil(font.lineHeight)))
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let iconPointSize = max(12, min(16, font.pointSize * 0.95))
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: iconPointSize, weight: .medium)
            let symbol = UIImage(systemName: "checklist", withConfiguration: symbolConfig)?
                .withTintColor(UIColor(Color.holoPrimary), renderingMode: .alwaysOriginal)
            let iconSize = iconPointSize + 1
            symbol?.draw(in: CGRect(x: 5, y: (size.height - iconSize) / 2, width: iconSize, height: iconSize))

            let text = String(localized: "任务") as NSString
            text.draw(
                at: CGPoint(x: 21, y: (size.height - font.lineHeight) / 2),
                withAttributes: [
                    .font: font,
                    .foregroundColor: UIColor.secondaryLabel
                ]
            )
        }
    }

    private static var markerFont: UIFont {
        UIFontMetrics(forTextStyle: .caption1)
            .scaledFont(for: UIFont.systemFont(ofSize: 12, weight: .medium))
    }
}

// MARK: - SelfSizingTextView

/// 自动计算内容高度的 UITextView
/// 通过 sizeThatFits 在布局完成后计算正确高度，避免 intrinsicContentSize 反馈循环
private final class SelfSizingTextView: UITextView {

    /// 应用内复制保留 Holo 节点身份；外部粘贴只保留可见纯文字。
    var onSemanticCopy: ((NSRange) -> SemanticClipboardPayload?)?
    var onSemanticPaste: ((Data) -> Bool)?
    var onPlainTextPaste: ((String) -> Bool)?
    var suggestionKeyboardEnabled = false
    var suggestionKeyboardHasItems = false
    var onSuggestionCommand: ((SuggestionKeyboardCommand) -> Void)?
    /// 新建想法只在首次挂入窗口后自动聚焦一次，避免 makeUIView 时机过早导致请求丢失。
    var autoFocusWhenAttached = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard autoFocusWhenAttached, window != nil else { return }

        autoFocusWhenAttached = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.becomeFirstResponder()
        }
    }

    /// 重写 intrinsicContentSize 返回无固定值，避免 SwiftUI ScrollView 内布局反馈循环
    /// 实际高度由 dynamicHeight binding + .frame(height:) 控制
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override var keyCommands: [UIKeyCommand]? {
        guard suggestionKeyboardEnabled else { return super.keyCommands }
        var commands = [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissSuggestion))
        ]
        if suggestionKeyboardHasItems {
            commands.insert(UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(moveSuggestionUp)), at: 0)
            commands.insert(UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(moveSuggestionDown)), at: 1)
            commands.insert(UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(commitSuggestion)), at: 2)
        }
        return commands
    }

    @objc private func moveSuggestionUp() {
        onSuggestionCommand?(.moveSelection(offset: -1))
    }

    @objc private func moveSuggestionDown() {
        onSuggestionCommand?(.moveSelection(offset: 1))
    }

    @objc private func commitSuggestion() {
        onSuggestionCommand?(.commitSelection)
    }

    @objc private func dismissSuggestion() {
        onSuggestionCommand?(.dismiss)
    }

    /// 空行的行框包含行距，光标会随之比有文字的行高出一截（光标落到空行时突然变大）。
    /// 光标高度统一 clamp 到当前打字字体的行高并垂直居中，与有文字行保持同一节奏；
    /// 只影响光标显示 rect，文字行距不受影响。
    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        let typingFont = (typingAttributes[.font] as? UIFont) ?? font
        guard let typingFont, rect.height > typingFont.lineHeight + 0.5 else { return rect }
        rect.origin.y += (rect.height - typingFont.lineHeight) / 2
        rect.size.height = typingFont.lineHeight
        return rect
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 利用 sizeThatFits 根据当前宽度计算内容所需高度
        let targetSize = CGSize(width: frame.width, height: .greatestFiniteMagnitude)
        let fittedSize = sizeThatFits(targetSize)
        if fittedSize.height > 0 {
            (delegate as? MarkdownTextView.Coordinator)?.onHeightChange?(fittedSize.height)
        }
        // 注意：不再在此动态切换 isScrollEnabled。
        // 原实现按「内容是否超出 frame」在 true/false 间翻转 isScrollEnabled，会让 UITextView
        // 反复重建 text container，导致输入时光标视觉位置刷新被卡住（换行符已插入但屏幕不显示，
        // 表现为「第一次回车没反应、第二次跳两行」）。
        // 现在始终保持 isScrollEnabled = true（makeUIView 初始设定），高度由 dynamicHeight
        // binding 驱动外层 .frame(height:) 把 frame 撑到与内容等高，UITextView 自身无可滚动空间，
        // 滚动手势自然交给外层 SwiftUI ScrollView，无需翻转开关。
    }

    /// 选区恰好是完整 Token 时禁用系统编辑菜单（复制/剪切气泡），避免与自定义 Token 菜单叠加
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if selectedRange.length > 0 {
            let isTokenSelection = MarkdownTextView.tokenRanges(in: attributedText).contains {
                $0.location == selectedRange.location && $0.length == selectedRange.length
            }
            if isTokenSelection {
                // 引用/标签仍可复制；任务标记没有独立正文，不向系统菜单暴露复制动作。
                return action == #selector(copy(_:)) && !selectedRangeIsTaskMarker()
            }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) {
        if selectedRangeIsTaskMarker() {
            // 防止系统快捷键绕过 canPerformAction 后，把 NSTextAttachment 的占位符写入剪贴板。
            return
        }

        guard selectedRange.length > 0,
              let payload = onSemanticCopy?(selectedRange) else {
            super.copy(sender)
            return
        }

        // 只写 Holo 语义数据和可见纯文本，不把 NSTextAttachment 的 U+FFFC 或编辑器样式
        // 泄漏到其他 App；回到 Holo 时再优先用语义数据恢复 Token。
        UIPasteboard.general.setItems([[
            "public.utf8-plain-text": payload.plainText,
            "public.text": payload.plainText,
            MarkdownTextView.semanticPasteboardType: payload.data
        ]])
    }

    /// 判断当前选区是否恰好是单个任务关系附件。
    private func selectedRangeIsTaskMarker() -> Bool {
        guard selectedRange.length > 0 else { return false }
        guard let tokenRange = MarkdownTextView.tokenRanges(in: attributedText).first(where: {
            $0.location == selectedRange.location && $0.length == selectedRange.length
        }),
        let node = MarkdownTextView.makeTokenNode(
            from: attributedText.attributes(at: tokenRange.location, effectiveRange: nil)
        ) else {
            return false
        }
        if case .taskMark = node { return true }
        return false
    }

    override func paste(_ sender: Any?) {
        if let data = UIPasteboard.general.data(
            forPasteboardType: MarkdownTextView.semanticPasteboardType
        ), onSemanticPaste?(data) == true {
            return
        }

        // 即便系统剪贴板同时携带 RTF/HTML，也只把字符串交给编辑器，
        // 由 Coordinator 用 Holo 的当前 typingAttributes 重新构造显示属性。
        if let string = UIPasteboard.general.string,
           onPlainTextPaste?(string) == true {
            return
        }

        super.paste(sender)
    }
}

// MARK: - UIEditMenuInteractionDelegate（选区编辑菜单兜底）

@available(iOS 16.0, *)
extension MarkdownTextView.Coordinator: UIEditMenuInteractionDelegate {

    /// 选区编辑菜单：
    /// - 完整 Token 选区 → 返回空菜单（与自定义 Token 菜单互斥）
    /// - 普通文字选区 → 系统菜单（复制/剪切等）+ 追加「转为任务」
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let textView = interaction.view as? UITextView else { return nil }
        let selection = textView.selectedRange
        guard selection.length > 0 else { return nil }

        let isTokenSelection = MarkdownTextView.tokenRanges(in: textView.attributedText).contains {
            $0.location == selection.location && $0.length == selection.length
        }
        if isTokenSelection {
            let isTaskMarker = MarkdownTextView.tokenRanges(in: textView.attributedText).contains { range in
                guard range.location == selection.location,
                      range.length == selection.length,
                      let node = MarkdownTextView.makeTokenNode(
                          from: textView.attributedText.attributes(at: range.location, effectiveRange: nil)
                      ) else { return false }
                if case .taskMark = node { return true }
                return false
            }
            guard !isTaskMarker else {
                // 任务附件没有独立正文，不能让系统复制出空字符串或 U+FFFC 占位符。
                return UIMenu(children: [])
            }

            // 完整引用/标签仍提供复制；移除关系走点击 Token 后的 Holo 操作菜单。
            let copyAction = UIAction(title: String(localized: "复制"), image: UIImage(systemName: "doc.on.doc")) { [weak textView] _ in
                textView?.copy(nil)
            }
            return UIMenu(children: [copyAction])
        }

        // 在菜单构建时立刻捕获选区文字（闭包执行时 selectedRange 可能已被系统改变）
        guard let attrSubstring = textView.attributedText?.attributedSubstring(from: selection),
              !MarkdownTextView.visiblePlainText(
                  from: MarkdownTextView.serializeNodes(from: attrSubstring)
              ).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return UIMenu(children: suggestedActions)
        }
        let capturedText = MarkdownTextView.visiblePlainText(
            from: MarkdownTextView.serializeNodes(from: attrSubstring)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleSelection = MarkdownTextView.visibleRange(
            forStorageRange: selection,
            in: textView.attributedText ?? NSAttributedString()
        ) ?? selection

        // 普通选区：在系统建议菜单后追加「转为任务」
        let convertAction = UIAction(title: String(localized: "转为任务"), image: UIImage(systemName: "text.badge.checkmark")) { [weak self] _ in
            self?.onConvertSelection?(capturedText, visibleSelection)
        }
        return UIMenu(children: suggestedActions + [convertAction])
    }
}
