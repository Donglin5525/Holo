//
//  MacRichTextEditor.swift
//  HoloMac
//
//  想法模块 Mac 编辑核心（Phase C）：NSTextView（AppKit）封装
//
//  与 iOS MarkdownTextView 同一条数据管线的 Mac 端实现：
//  - 打开渲染 / 序列化回写全部复用 MarkdownTextView 共享扩展
//    （makeAttributedText(from:) / serializeNodes(from:) / makeTokenAttributedText…），
//    节点模型（HoloContentNode）与富文本属性键两端同一份；
//  - #/@ 触发检测复用 TriggerDetector（纯函数）；
//  - Token 原子化（点按吸附 / 删除整删 / 禁止内部插入）与任务标记维护
//    （sourceLength 回写 / 空标记清理 / 打字继承下划线）按 iOS 版逐条对齐；
//  - Phase E：「转为任务」补齐（convertToTask 选区分流 + insertTaskMarks
//    经共享 attributedTextByInsertingTaskMarks 写入关系标记）；
//  - IME 组字（marked text）期间不做任何程序化重写与触发检测，与 iOS 铁律一致。
//  Mac 特有：⌘B/⌘I/⌘U 快捷键、候选面板 ↑↓/回车/Esc 走 NSTextViewDelegate 的
//  doCommandBy；编辑器自带 NSScrollView（长文内部滚动，TextEdit 惯例）。
//

import SwiftUI
import AppKit

// MARK: - 跨文件共享的私有属性键 / 存储访问

extension NSAttributedString.Key {
    /// 与 MarkdownTextView 内 fileprivate 声明的键同 rawValue：
    /// 富文本属性按键的字符串值判等，两端序列化读写的是同一个属性。
    static let macHoloItalic = NSAttributedString.Key("holoMarkdownItalic")
    static let macHoloUnderline = NSAttributedString.Key("holoMarkdownUnderline")
}

extension NSTextView {
    /// macOS 的 textStorage 声明为可选；init(frame:) 创建的 NSTextView 恒有存储，
    /// 统一从本入口取非可选存储（不为想象中的异常堆防御，真实异常尽早暴露）
    var editorStorage: NSTextStorage {
        guard let textStorage else {
            fatalError("NSTextView 缺少 textStorage")
        }
        return textStorage
    }
}

// MARK: - NSTextView 子类

/// 编辑器正文视图：快捷键与语义剪贴板挂点。
/// 其余行为全部由 Coordinator（NSTextViewDelegate）承担，与 iOS 版职责划分一致。
final class MacEditorTextView: NSTextView {

    /// ⌘B/⌘I/⌘U：与工具栏按钮走同一条 pendingAction 管线
    var onFormatCommand: ((MarkdownEditorAction) -> Void)?
    /// 语义复制（copy/cut）：选区触碰 Token 时展开到整段并写入 Holo 节点 JSON；返回 true 表示已接管
    var onSemanticCopy: ((NSRange, Bool) -> Bool)?
    /// 语义粘贴（paste）：优先恢复 Holo 节点身份，外部富文本只取纯文字；返回 true 表示已接管
    var onPaste: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers {
            case "b":
                onFormatCommand?(.toggleBold)
                return true
            case "i":
                onFormatCommand?(.toggleItalic)
                return true
            case "u":
                onFormatCommand?(.toggleUnderline)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func copy(_ sender: Any?) {
        if let onSemanticCopy, onSemanticCopy(selectedRange(), false) { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        if let onSemanticCopy, onSemanticCopy(selectedRange(), true) { return }
        super.cut(sender)
    }

    override func paste(_ sender: Any?) {
        if let onPaste, onPaste() { return }
        super.paste(sender)
    }
}

// MARK: - MacRichTextEditor（NSViewRepresentable）

/// Mac 富文本编辑器：能力对齐 iOS MarkdownTextView（正文富文本 / #/@ Token / 任务标记维护）
struct MacRichTextEditor: NSViewRepresentable {

    @Binding var text: String
    /// 工具栏动作管线（与 iOS 同一枚举）
    @Binding var pendingAction: MarkdownEditorAction?
    /// 光标处格式状态（工具栏高亮反馈）
    @Binding var formatState: TypingFormatState
    /// 当前 #/@ 触发上下文（候选面板数据源，nil=关闭面板）
    @Binding var triggerContext: EditorTriggerContext?
    /// 当前被点选的 Token（弹操作菜单）
    @Binding var selectedToken: HoloContentNode?
    /// Token 操作菜单锚定 rect（编辑器容器坐标）
    @Binding var tokenMenuRect: CGRect?
    /// 光标 rect（编辑器容器坐标，候选浮层吸附）
    @Binding var caretRect: CGRect

    /// 编辑已有想法时的结构化内容（恢复 Token；nil=纯文本）
    var initialRichJSON: String? = nil
    /// 新建想法自动聚焦正文；编辑已有想法保持阅读优先
    var autoFocus: Bool = false
    /// 空内容占位提示
    var placeholder: String? = nil
    /// 恢复草稿等场景的强制重建令牌（与 iOS editorReloadToken 同语义）
    var reloadToken: Int = 0
    /// 节点模型变化回调（保存时取 richContentJSON 用）
    var onNodesChange: (([HoloContentNode]) -> Void)? = nil
    /// 候选面板键盘操作（↑↓/回车/Esc）
    var onSuggestionCommand: ((SuggestionKeyboardCommand) -> Void)? = nil
    /// 候选面板打开时接管 Esc；有条目时再接管方向键和回车
    var suggestionKeyboardEnabled: Bool = false
    var suggestionKeyboardHasItems: Bool = false
    /// IME 组字状态变化回调（父视图据此推迟自动保存）
    var onCompositionChange: ((Bool) -> Void)? = nil
    /// 「转为任务」分流回调（Phase E）：有选中文字回传 (选区文本, 选区范围)，
    /// 无选中传 (nil, nil) 表示整篇转化；由父视图落库后弹提取确认面板
    var onConvertToTask: ((String?, NSRange?) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            formatState: $formatState,
            triggerContext: $triggerContext,
            selectedToken: $selectedToken,
            tokenMenuRect: $tokenMenuRect,
            caretRect: $caretRect)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MacEditorTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.font = MarkdownTextView.baseFont
        textView.typingAttributes = MarkdownTextView.baseAttributes
        textView.textColor = MarkdownTextView.baseTextColor
        textView.drawsBackground = false
        textView.isRichText = true
        textView.isSelectable = true
        textView.isEditable = true
        textView.allowsUndo = true
        // 外部链接自动检测会把 URL 变成属性富文本；序列化虽不读 link 属性，
        // 但保留原文更符合「记录想法」的心智，关掉。
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        textView.onFormatCommand = { action in
            // 与 iOS makeUIView 一致：快捷键直接写入 pendingAction 管线
            self.pendingAction = action
        }
        textView.onSemanticCopy = { [weak textView] range, deletes in
            guard let textView else { return false }
            return context.coordinator.performSemanticCopy(in: textView, range: range, deletes: deletes)
        }
        textView.onPaste = { [weak textView] in
            guard let textView else { return false }
            return context.coordinator.performPaste(in: textView)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // 初始内容（与 iOS makeUIView 同序：节点 → 富文本 → 编辑态行距）
        let initialNodes = RichContentSerializer.nodes(richJSON: initialRichJSON, fallbackPlainText: text)
        let initialAttributed = MarkdownTextView.makeAttributedText(from: initialNodes)
        textView.editorStorage.setAttributedString(
            MarkdownTextView.applyingEditorLineSpacing(to: initialAttributed))

        // 以节点派生文本为准（存量引用可能由快照补齐标题），保证 Binding 与编辑器一致
        let canonicalMarkdown = RichContentSerializer.plainText(from: initialNodes)
        context.coordinator.lastKnownMarkdown = canonicalMarkdown
        context.coordinator.lastAppliedRichJSON = initialRichJSON
        context.coordinator.lastAppliedReloadToken = reloadToken
        context.coordinator.nodes = initialNodes
        context.coordinator.onNodesChange = onNodesChange
        context.coordinator.onSuggestionCommand = onSuggestionCommand
        context.coordinator.onCompositionChange = onCompositionChange
        context.coordinator.onConvertToTask = onConvertToTask
        context.coordinator.attachPlaceholder(
            text: placeholder, font: MarkdownTextView.baseFont, in: textView)
        context.coordinator.refreshTypingAttributes(for: textView)

        // 滚动不改变选区，但候选浮层锚点会漂移；滚动时重报光标 rect
        context.coordinator.observeScrollViewClipView(scrollView)

        if initialRichJSON != nil, canonicalMarkdown != text {
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                if coordinator.boundText == text {
                    coordinator.setBoundText(canonicalMarkdown)
                }
            }
        }

        if autoFocus {
            context.coordinator.pendingFocus = true
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MacEditorTextView else { return }
        context.coordinator.onNodesChange = onNodesChange
        context.coordinator.onSuggestionCommand = onSuggestionCommand
        context.coordinator.onCompositionChange = onCompositionChange
        context.coordinator.onConvertToTask = onConvertToTask
        context.coordinator.suggestionKeyboardEnabled = suggestionKeyboardEnabled
        context.coordinator.suggestionKeyboardHasItems = suggestionKeyboardHasItems

        // 新建会话自动聚焦：makeNSView 时窗口可能未挂载，挂载后的首轮更新补做
        if context.coordinator.pendingFocus, textView.window != nil {
            context.coordinator.pendingFocus = false
            textView.window?.makeFirstResponder(textView)
        }

        // 恢复草稿的强制重建：只在「编辑器尚无本地输入且未在组字」时允许。
        // 会话所有权红线（2026-10-26 组字消失事故）：编辑器一旦有本地输入，
        // 它就是正文唯一事实源；reloadToken 语义 = 打开/恢复草稿时的整体重建请求，
        // 正常流程只发生在用户尚未输入时。编辑中收到的令牌变化一律吞掉并保持现状
        // （组字窗口内 setAttributedString = 冲掉正文 + 杀死 IME 会话，字母直出）。
        if context.coordinator.lastAppliedReloadToken != reloadToken {
            context.coordinator.lastAppliedReloadToken = reloadToken
            guard !context.coordinator.hasLocalEdits, !textView.hasMarkedText() else { return }
            context.coordinator.rehydrateContent(
                in: textView, richJSON: initialRichJSON, fallbackText: text)
            return
        }

        // 会话所有权：发生过本地输入后 NSTextView 就是正文事实源，
        // SwiftUI 回放的任意旧快照只能被纠正，不能反向重建编辑器。
        if let protectedMarkdown = context.coordinator.replacementForHostText(text) {
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                if coordinator.boundText != protectedMarkdown {
                    coordinator.restoreBoundText(protectedMarkdown)
                }
            }
            return
        }

        if let action = pendingAction {
            guard !context.coordinator.isPendingActionScheduled else { return }
            context.coordinator.isPendingActionScheduled = true
            let coordinator = context.coordinator
            let actionBinding = $pendingAction
            DispatchQueue.main.async {
                coordinator.perform(action: action, on: textView)
                if actionBinding.wrappedValue == action {
                    actionBinding.wrappedValue = nil
                }
                coordinator.isPendingActionScheduled = false
            }
            return
        }

        // 编辑器可能先于编辑数据创建：richJSON 异步到达后重新水合 Token 身份，
        // 否则 @/任务看似有颜色，实际已失去 Token 身份（与 iOS updateUIView 同口径）
        if !context.coordinator.hasLocalEdits,
           initialRichJSON != context.coordinator.lastAppliedRichJSON,
           !textView.hasMarkedText() {
            context.coordinator.rehydrateContent(
                in: textView, richJSON: initialRichJSON, fallbackText: text)
            return
        }

        // 纯文本初始内容异步到达（编辑已有纯文本想法）：无本地修改时按平文本载入。
        // canonical 写回在途时跳过——此刻绑定是滞后值，按它重建等于冲掉刚水合的内容。
        if !context.coordinator.hasLocalEdits,
           !context.coordinator.isProgrammaticChange,
           !textView.hasMarkedText(),
           context.coordinator.pendingCanonicalBinding == nil,
           text != context.coordinator.lastKnownMarkdown {
            let preservedSelection = MarkdownTextView.clampedRange(
                textView.selectedRange(), for: textView.editorStorage.length)
            let newNodes = RichContentSerializer.nodes(fromPlainText: text)
            let attributedText = MarkdownTextView.applyingEditorLineSpacing(
                to: MarkdownTextView.makeAttributedText(from: newNodes))
            context.coordinator.isProgrammaticChange = true
            textView.editorStorage.setAttributedString(attributedText)
            textView.setSelectedRange(MarkdownTextView.clampedRange(
                preservedSelection, for: attributedText.length))
            context.coordinator.isProgrammaticChange = false
            context.coordinator.lastKnownMarkdown = text
            context.coordinator.nodes = newNodes
            context.coordinator.refreshTypingAttributes(for: textView)
        }
        context.coordinator.updatePlaceholderVisibility(in: textView)
    }
}

// MARK: - Coordinator（NSTextViewDelegate）

extension MacRichTextEditor {

    final class Coordinator: NSObject, NSTextViewDelegate {

        @Binding var text: String
        @Binding var formatState: TypingFormatState
        @Binding var triggerContext: EditorTriggerContext?
        @Binding var selectedToken: HoloContentNode?
        @Binding var tokenMenuRect: CGRect?
        @Binding var caretRect: CGRect

        var isProgrammaticChange = false
        var lastKnownMarkdown = ""
        /// 本次编辑会话是否已产生本地修改（正文事实源归属，与 iOS 同语义）
        private(set) var hasLocalEdits = false
        var isPendingActionScheduled = false
        /// 编辑期结构化内容模型（事实源）
        var nodes: [HoloContentNode] = []
        var lastAppliedRichJSON: String? = nil
        var lastAppliedReloadToken = 0

        var onNodesChange: (([HoloContentNode]) -> Void)?
        var onSuggestionCommand: ((SuggestionKeyboardCommand) -> Void)?
        var onCompositionChange: ((Bool) -> Void)?
        var onConvertToTask: ((String?, NSRange?) -> Void)?
        var suggestionKeyboardEnabled = false
        var suggestionKeyboardHasItems = false
        /// autoFocus 待执行：makeNSView 时窗口可能尚未挂载，updateNSView 补做
        var pendingFocus = false

        /// 当前活跃的 #/@ 触发
        private var activeTrigger: EditorTriggerContext?
        /// rehydrate 的 canonical 绑定写回在途值：落地前纯文本装载分支不得按滞后
        /// 绑定重建存储（否则刚水合的结构化内容会被旧绑定冲掉——IME 自检 P1 实锤）。
        /// updateNSView 在 Coordinator 外读取，保持 internal。
        var pendingCanonicalBinding: String?
        /// 最近一次点按的完整 Token 区间
        private var selectedTokenRange: NSRange?
        private var lastSelectionLocation = 0
        private var lastPublishedTrigger: EditorTriggerContext?
        /// 被用户手动关闭的触发起点（同一触发片段内不再自动弹出面板）
        private var suppressedTriggerLocation: Int?
        /// 最近一次上报的组字状态（跳变检测）
        private var lastReportedComposing = false

        // 用户显式切换的格式状态（sticky toggle，与 iOS 同语义）
        var explicitBold: Bool? = nil
        var explicitItalic: Bool? = nil
        var explicitUnderline: Bool? = nil
        var explicitColorHex: String? = nil

        /// 占位提示（AppKit 原生 label，随内容显隐）
        private var placeholderLabel: NSTextField?

        /// 滚动重报光标的观察者
        private var clipViewObserver: NSObjectProtocol?

        init(
            text: Binding<String>,
            formatState: Binding<TypingFormatState>,
            triggerContext: Binding<EditorTriggerContext?>,
            selectedToken: Binding<HoloContentNode?>,
            tokenMenuRect: Binding<CGRect?>,
            caretRect: Binding<CGRect>
        ) {
            self._text = text
            self._formatState = formatState
            self._triggerContext = triggerContext
            self._selectedToken = selectedToken
            self._tokenMenuRect = tokenMenuRect
            self._caretRect = caretRect
        }

        deinit {
            if let clipViewObserver {
                NotificationCenter.default.removeObserver(clipViewObserver)
            }
        }

        // MARK: - 正文绑定（会话所有权）

        var boundText: String { text }

        /// 初始化/异步加载阶段写回规范文本；尚未建立本地编辑所有权
        func setBoundText(_ value: String) {
            guard text != value else { return }
            text = value
        }

        func publishLocalMarkdown(_ value: String) {
            hasLocalEdits = true
            lastKnownMarkdown = value
            if text != value {
                text = value
            }
        }

        func replacementForHostText(_ incoming: String) -> String? {
            guard hasLocalEdits, incoming != lastKnownMarkdown else { return nil }
            return lastKnownMarkdown
        }

        func restoreBoundText(_ value: String) {
            text = value
        }

        // MARK: - 内容水合

        /// 按 richJSON（或纯文本回退）整体重建编辑器内容（初始加载 / 异步数据到达 / 恢复草稿）。
        /// 无条件防线：本地已有输入或组字进行中时拒绝重建——setAttributedString 会冲掉
        /// 正文并杀死 IME 组字会话（marked text 被程序化替换后，输入法以字母直出收场；
        /// 2026-10-26 组字消失事故实锤，分支入口守卫之外再加函数级兜底，杜绝未来新调用方复踩）。
        func rehydrateContent(in textView: NSTextView, richJSON: String?, fallbackText: String) {
            guard !hasLocalEdits, !textView.hasMarkedText() else { return }
            let hydratedNodes = RichContentSerializer.nodes(richJSON: richJSON, fallbackPlainText: fallbackText)
            let attributed = MarkdownTextView.applyingEditorLineSpacing(
                to: MarkdownTextView.makeAttributedText(from: hydratedNodes))
            let preservedSelection = MarkdownTextView.clampedRange(
                textView.selectedRange(), for: attributed.length)
            isProgrammaticChange = true
            textView.editorStorage.setAttributedString(attributed)
            textView.setSelectedRange(preservedSelection)
            isProgrammaticChange = false
            nodes = hydratedNodes
            let canonicalMarkdown = RichContentSerializer.plainText(from: hydratedNodes)
            lastKnownMarkdown = canonicalMarkdown
            lastAppliedRichJSON = richJSON
            hasLocalEdits = false
            refreshTypingAttributes(for: textView)
            updatePlaceholderVisibility(in: textView)
            activeTrigger = nil
            publishTrigger(nil)
            publishSelectedToken(nil)
            onNodesChange?(hydratedNodes)
            // updateNSView 内同步发布 SwiftUI State 有未定义的重入顺序，延后到下一轮主循环。
            // 写回在途期间禁止纯文本装载分支按滞后绑定重建存储（会话所有权注释见下）。
            pendingCanonicalBinding = canonicalMarkdown
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingCanonicalBinding = nil
                guard self.boundText != canonicalMarkdown else { return }
                self.setBoundText(canonicalMarkdown)
            }
        }

        // MARK: - NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            reportCompositionState(textView)
            updatePlaceholderVisibility(in: textView)
            guard !isProgrammaticChange else { return }
            // IME 组字期间不重写、不检测触发：marked text 由输入法会话独占
            guard !textView.hasMarkedText() else { return }
            normalizeTaskMetadata(after: textView)
            syncMarkdown(from: textView)
            updateTriggerState(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            reportCompositionState(textView)
            guard !textView.hasMarkedText() else { return }

            // Token 菜单打开期间用户点走（选区离开该 Token）→ 关闭菜单
            if !isProgrammaticChange, let menuRange = selectedTokenRange {
                let selection = textView.selectedRange()
                if NSIntersectionRange(selection, menuRange).length == 0 {
                    publishSelectedToken(nil)
                }
            }

            // Token 原子化：光标/选区进入 Token 时先调整，调整后等待重入回调
            if !isProgrammaticChange, adjustSelectionForTokenAtomicity(textView) {
                return
            }
            refreshTypingAttributes(for: textView)
            updateTriggerState(textView)
            reportCaretRect(textView)
            lastSelectionLocation = textView.selectedRange().location
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard !isProgrammaticChange else { return true }
            guard let replacement = replacementString else { return true }

            // 组字按键是 IME 缓冲区操作而非正文编辑，不参与 Token 拦截与列表续行
            guard !textView.hasMarkedText() else { return true }

            // Token 原子化：编辑范围触碰 Token 时扩展为完整 Token 操作
            if handleTokenEditInterception(textView, range: affectedCharRange, replacementText: replacement) {
                return false
            }

            // 任务作用范围内的常规键入：typingAttributes 携带 taskId，新文字自然继承下划线
            let taskId = taskIdForTextChange(range: affectedCharRange, in: textView.editorStorage)
            if let taskId {
                prepareTaskTypingAttributes(taskId: taskId, on: textView)
            }

            // 行首「- / + / *」+ 空格 → 无序列表符「• 」（与 iOS 妙控键盘快打同构）
            if replacement == " ",
               let bulletRange = Self.inlineBulletPrefixRange(
                in: textView.editorStorage.string as NSString, insertLocation: affectedCharRange.location) {
                let mutable = NSMutableAttributedString(attributedString: textView.editorStorage)
                let prefixAttrs = MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
                mutable.replaceCharacters(
                    in: bulletRange,
                    with: NSAttributedString(string: "\u{2022} ", attributes: prefixAttrs))
                refreshTaskSourceLengths(in: mutable)
                removeEmptyTaskMarkers(in: mutable)
                performProgrammaticEdit(on: textView, actionName: String(localized: "无序列表")) {
                    textView.editorStorage.setAttributedString(mutable)
                    textView.setSelectedRange(NSRange(location: bulletRange.location + 2, length: 0))
                }
                syncMarkdown(from: textView)
                return false
            }

            guard replacement == "\n" else { return true }
            return handleListContinuation(
                in: textView, insertLocation: affectedCharRange.location, taskId: taskId)
        }

        /// 候选面板键盘操作：↑↓ 移动、回车提交、Esc 关闭；无面板时不拦截原生按键
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard suggestionKeyboardEnabled else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                if suggestionKeyboardHasItems {
                    onSuggestionCommand?(.moveSelection(offset: -1))
                    return true
                }
            case #selector(NSResponder.moveDown(_:)):
                if suggestionKeyboardHasItems {
                    onSuggestionCommand?(.moveSelection(offset: 1))
                    return true
                }
            case #selector(NSResponder.insertNewline(_:)):
                if suggestionKeyboardHasItems {
                    onSuggestionCommand?(.commitSelection)
                    return true
                }
            case #selector(NSResponder.cancelOperation(_:)):
                // Esc 优先交给系统取消组字：IME 组字期间吞掉 Esc 会让输入法无法
                // 取消当前会话（候选悬浮 + 字母直出的帮凶）；无组字时才用于关面板
                guard !textView.hasMarkedText() else { return false }
                onSuggestionCommand?(.dismiss)
                return true
            default:
                break
            }
            return false
        }

        // MARK: - 组字状态

        private func reportCompositionState(_ textView: NSTextView) {
            let composing = textView.hasMarkedText()
            // macOS 的 textDidChange 不因组字触发：组字开始/结束必须在此刷新占位显隐，
            // 否则 placeholder 与组字文字重叠（iOS UITextView 组字会触发 didChange，无此问题）
            updatePlaceholderVisibility(in: textView)
            guard composing != lastReportedComposing else { return }
            lastReportedComposing = composing
            onCompositionChange?(composing)
        }

        // MARK: - 占位提示与光标 rect

        func attachPlaceholder(text: String?, font: NSFont, in textView: NSTextView) {
            guard let text, !text.isEmpty else { return }
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.textColor = NSColor(named: "TextPlaceholder") ?? .secondaryLabelColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isBezeled = false
            label.isEditable = false
            label.allowsEditingTextAttributes = false
            textView.addSubview(label)
            let inset = textView.textContainerInset
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: textView.topAnchor, constant: inset.height),
                label.leadingAnchor.constraint(
                    equalTo: textView.leadingAnchor, constant: inset.width),
                label.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor)
            ])
            placeholderLabel = label
            updatePlaceholderVisibility(in: textView)
        }

        func updatePlaceholderVisibility(in textView: NSTextView) {
            // 组字中的 marked text 属于 storage 内容但 macOS 不发 didChange，
            // 显式把组字态视作「有内容」，占位提示与组字文字不再同屏重叠
            placeholderLabel?.isHidden = textView.editorStorage.length > 0 || textView.hasMarkedText()
        }

        /// 滚动会移动光标的可视位置：clipView bounds 变化时重报，候选浮层不漂移
        func observeScrollViewClipView(_ scrollView: NSScrollView) {
            let clipView = scrollView.contentView
            clipViewObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] notification in
                guard let clipView = notification.object as? NSClipView,
                      let documentView = clipView.documentView as? NSTextView else { return }
                MainActor.assumeIsolated {
                    self?.reportCaretRect(documentView)
                }
            }
            clipView.postsBoundsChangedNotifications = true
        }

        /// 光标 rect（编辑器容器坐标）：firstRect 返回屏幕坐标，转换后统一为
        /// SwiftUI overlay 可直接使用的左上原点坐标。
        func reportCaretRect(_ textView: NSTextView) {
            caretRect = Self.rectInViewContainer(
                NSRange(location: min(textView.selectedRange().location, textView.editorStorage.length), length: 0),
                of: textView)
        }

        private static func rectInViewContainer(_ range: NSRange, of textView: NSTextView) -> CGRect {
            var actual = NSRange(location: 0, length: 0)
            let screenRect = textView.firstRect(
                forCharacterRange: NSRange(location: range.location, length: max(0, range.length)),
                actualRange: &actual)
            guard let container = textView.enclosingScrollView else {
                return CGRect(origin: .zero, size: CGSize(width: 1, height: 16))
            }
            let windowRect = textView.window?.convertFromScreen(screenRect) ?? screenRect
            let local = container.convert(windowRect, from: nil)
            let flipped = container.isFlipped
            let originY = flipped ? local.minY : container.bounds.height - local.maxY
            return CGRect(
                x: local.minX,
                y: originY,
                width: max(1, local.width),
                height: local.height)
        }

        // MARK: - 同步节点与 Markdown

        private func syncMarkdown(from textView: NSTextView) {
            let serializedNodes = MarkdownTextView.serializeNodes(from: textView.editorStorage)
            nodes = serializedNodes
            let markdown = RichContentSerializer.plainText(from: serializedNodes)
            publishLocalMarkdown(markdown)
            onNodesChange?(serializedNodes)
        }

        // MARK: - 触发检测与 Token 操作

        private func updateTriggerState(_ textView: NSTextView) {
            guard !textView.hasMarkedText() else { return }
            let detected = TriggerDetector.detect(
                text: textView.editorStorage.string as NSString,
                cursor: textView.selectedRange().location)

            // 已有 Token 的可见文本也含 #/@：光标吸附到边缘不能误判为「正在输入新触发」
            if let detected,
               MarkdownTextView.triggerIntersectsToken(detected, in: textView.editorStorage) {
                activeTrigger = nil
                publishTrigger(nil)
                return
            }

            // 同一触发片段被手动关闭后保持关闭；片段消失后重置抑制
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

        private func publishSelectedToken(_ node: HoloContentNode?, range: NSRange? = nil) {
            if node == nil {
                selectedTokenRange = nil
                tokenMenuRect = nil
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
        private func insertTriggerCharacter(_ character: String, on textView: NSTextView) {
            let safeRange = MarkdownTextView.clampedRange(
                textView.selectedRange(), for: textView.editorStorage.length)
            let currentText = textView.editorStorage.string as NSString
            // 光标紧贴禁止触发字符时自动补一个空格，保证插入后能正常打开候选面板
            let needsLeadingSpace = safeRange.location > 0
                && !InlineTagDetector.isTriggerPosition(safeRange.location, in: currentText as String)
            let insertionText = (needsLeadingSpace ? " " : "") + character
            let mutable = NSMutableAttributedString(attributedString: textView.editorStorage)
            let insertion = makeTaskAwareReplacement(
                insertionText, range: safeRange, in: textView)
            mutable.replaceCharacters(in: safeRange, with: insertion)

            performProgrammaticEdit(on: textView, actionName: String(localized: "插入触发字符")) {
                textView.editorStorage.setAttributedString(mutable)
                textView.setSelectedRange(NSRange(location: safeRange.location + insertion.length, length: 0))
            }
            refreshTypingAttributes(for: textView)
            updateTriggerState(textView)
        }

        /// 候选选中：把触发区间整体替换为 Token，尾随一个空格，光标移到空格后
        private func insertToken(
            type: HoloTokenType,
            id: UUID,
            displayText: String,
            snapshot: String?,
            on textView: NSTextView
        ) {
            guard let trigger = activeTrigger else { return }
            let tokenText = MarkdownTextView.applyingEditorLineSpacing(
                to: MarkdownTextView.makeTokenAttributedText(
                    type: type, id: id, displayText: displayText, snapshot: snapshot))
            let mutable = NSMutableAttributedString(attributedString: textView.editorStorage)
            let safeRange = MarkdownTextView.clampedRange(trigger.range, for: mutable.length)
            let taskAwareToken = NSMutableAttributedString(attributedString: tokenText)
            let destinationTaskId = taskIdForTextChange(range: safeRange, in: textView.editorStorage)
            if let destinationTaskId {
                applyTaskScope(taskId: destinationTaskId, to: taskAwareToken)
            }
            mutable.replaceCharacters(in: safeRange, with: taskAwareToken)

            let spaceLocation = safeRange.location + taskAwareToken.length
            let space = makeTaskAwareReplacement(
                " ", range: NSRange(location: NSMaxRange(safeRange), length: 0), in: textView)
            mutable.insert(space, at: spaceLocation)

            // Token 改变底层 UTF-16 长度；落在任务作用范围内时必须同次重算 sourceLength
            refreshTaskSourceLengths(in: mutable)
            removeEmptyTaskMarkers(in: mutable)

            performProgrammaticEdit(
                on: textView,
                actionName: type == .reference ? String(localized: "插入引用") : String(localized: "插入标签")
            ) {
                textView.editorStorage.setAttributedString(mutable)
                textView.setSelectedRange(NSRange(location: spaceLocation + 1, length: 0))
            }
            lastSelectionLocation = spaceLocation + 1

            activeTrigger = nil
            publishTrigger(nil)
            refreshTypingAttributes(for: textView)
        }

        /// 把选中的 Token 转为普通文本（保留文字、去除 #/@ 前缀与 Token 关系）
        private func removeSelectedToken(on textView: NSTextView) {
            let tokenRanges = MarkdownTextView.tokenRanges(in: textView.editorStorage)
            let selection = textView.selectedRange()
            let lookupRange = selectedTokenRange ?? selection
            guard let tokenRange = tokenRanges.first(where: {
                lookupRange.length == 0
                    ? $0.location == lookupRange.location
                    : NSIntersectionRange($0, lookupRange).length > 0
            }),
                let node = MarkdownTextView.makeTokenNode(
                    from: textView.editorStorage.attributes(
                        at: tokenRange.location, effectiveRange: nil)) else { return }

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
                // 任务标记是纯关系附件：取消时删除标记并移除原文专属下划线
                taskIdToRemove = taskId
                taskSourceLength = sourceLength
                plainText = nil
                actionName = String(localized: "取消任务标记")
            case .text:
                return
            }

            let mutable = NSMutableAttributedString(attributedString: textView.editorStorage)
            if let taskIdToRemove {
                let sourceLength = max(0, taskSourceLength ?? 0)
                let sourceRange = NSRange(
                    location: max(0, tokenRange.location - sourceLength),
                    length: min(sourceLength, tokenRange.location))
                removeTaskSourceDecoration(taskId: taskIdToRemove, sourceRange: sourceRange, from: mutable)
            }
            if let plainText {
                let tokenAttributes = textView.editorStorage.attributes(
                    at: tokenRange.location, effectiveRange: nil)
                mutable.replaceCharacters(
                    in: tokenRange,
                    with: NSAttributedString(
                        string: plainText,
                        attributes: MarkdownTextView.plainTextAttributes(
                            afterRemovingToken: tokenAttributes)))
            } else {
                mutable.deleteCharacters(in: tokenRange)
            }

            refreshTaskSourceLengths(in: mutable)
            removeEmptyTaskMarkers(in: mutable)

            let replacementLength = plainText.map { ($0 as NSString).length } ?? 0
            performProgrammaticEdit(on: textView, actionName: actionName) {
                textView.editorStorage.setAttributedString(mutable)
                textView.setSelectedRange(NSRange(location: tokenRange.location + replacementLength, length: 0))
            }
            publishSelectedToken(nil)
            refreshTypingAttributes(for: textView)
        }

        // MARK: - Token 原子化

        /// 选区与 Token 相交时扩展为完整 Token；光标落在 Token 内部时禁止插入
        private func handleTokenEditInterception(
            _ textView: NSTextView, range: NSRange, replacementText text: String
        ) -> Bool {
            let tokenRanges = MarkdownTextView.tokenRanges(in: textView.editorStorage)
            guard !tokenRanges.isEmpty else { return false }

            // 纯插入且光标在 Token 内部 → 禁止（正常被光标吸附挡住，这里兜底）
            if range.length == 0 {
                return tokenRanges.contains {
                    range.location > $0.location && range.location < $0.location + $0.length
                }
            }

            let intersecting = tokenRanges.filter { NSIntersectionRange($0, range).length > 0 }
            guard !intersecting.isEmpty else { return false }

            var unionRange = range
            for tokenRange in intersecting {
                unionRange = NSUnionRange(unionRange, tokenRange)
            }

            let mutable = NSMutableAttributedString(attributedString: textView.editorStorage)
            // 键盘直接删除任务附件时同步移除原文专属下划线
            removeTaskDecorations(for: intersecting, from: textView.editorStorage, in: mutable)

            var replacementAttributes = MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
            let replacesTaskMarker = intersecting.contains { tokenRange in
                guard let node = MarkdownTextView.makeTokenNode(
                    from: textView.editorStorage.attributes(
                        at: tokenRange.location, effectiveRange: nil)) else { return false }
                if case .taskMark = node { return true }
                return false
            }
            if !replacesTaskMarker,
               let taskId = taskIdForTextChange(range: unionRange, in: textView.editorStorage) {
                replacementAttributes[.holoTaskId] = taskId
                replacementAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            let replacement = NSAttributedString(string: text, attributes: replacementAttributes)
            mutable.replaceCharacters(in: unionRange, with: replacement)
            refreshTaskSourceLengths(in: mutable)
            removeEmptyTaskMarkers(in: mutable)

            performProgrammaticEdit(on: textView, actionName: String(localized: "编辑引用")) {
                textView.editorStorage.setAttributedString(mutable)
                textView.setSelectedRange(NSRange(location: unionRange.location + replacement.length, length: 0))
            }
            syncMarkdown(from: textView)
            updateTriggerState(textView)
            return true
        }

        /// 光标进入 Token 内部时吸附到较近边缘；点按 Token 发布选中态弹操作菜单；
        /// 选区横跨 Token 一部分时扩展为完整 Token
        private func adjustSelectionForTokenAtomicity(_ textView: NSTextView) -> Bool {
            let tokenRanges = MarkdownTextView.tokenRanges(in: textView.editorStorage)
            guard !tokenRanges.isEmpty else { return false }

            let selection = textView.selectedRange()

            if selection.length == 0 {
                let isTap = abs(selection.location - lastSelectionLocation) > 1
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
                    snappedLocation = distanceToStart <= distanceToEnd
                        ? token.location
                        : token.location + token.length
                } else {
                    snappedLocation = selection.location > lastSelectionLocation
                        ? token.location + token.length
                        : token.location
                }

                if isTap,
                   let node = MarkdownTextView.makeTokenNode(
                    from: textView.editorStorage.attributes(at: token.location, effectiveRange: nil)) {
                    publishSelectedToken(node, range: token)
                    tokenMenuRect = Self.rectInViewContainer(token, of: textView)
                }

                lastSelectionLocation = snappedLocation
                textView.setSelectedRange(NSRange(location: snappedLocation, length: 0))
                return true
            }

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
            textView.setSelectedRange(unionRange)
            return true
        }

        /// 选区触碰 Token 时扩展为完整区间；光标落在 Token 内部时返回 nil（拒绝操作）
        private func expandedTokenRange(_ range: NSRange, in textView: NSTextView) -> NSRange? {
            let tokenRanges = MarkdownTextView.tokenRanges(in: textView.editorStorage)
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

        // MARK: - 任务作用范围维护（与 iOS 同一套纯逻辑移植）

        private struct TaskSourceSpan {
            let taskId: String
            let range: NSRange
            let markerRange: NSRange
        }

        private func taskSourceSpans(in attributedText: NSAttributedString) -> [TaskSourceSpan] {
            MarkdownTextView.tokenRanges(in: attributedText).compactMap { markerRange in
                guard markerRange.location < attributedText.length,
                      attributedText.attribute(
                        .holoTokenType, at: markerRange.location, effectiveRange: nil
                      ) as? String == HoloTokenType.taskMark.rawValue,
                      let taskId = attributedText.attribute(
                        .holoTaskId, at: markerRange.location, effectiveRange: nil) as? String else {
                    return nil
                }
                var sourceStart = markerRange.location
                var cursor = markerRange.location
                while cursor > 0 {
                    var effectiveRange = NSRange(location: 0, length: 0)
                    let value = attributedText.attribute(
                        .holoTaskId, at: cursor - 1, effectiveRange: &effectiveRange) as? String
                    guard value == taskId, effectiveRange.location < cursor else { break }
                    sourceStart = effectiveRange.location
                    cursor = effectiveRange.location
                }
                return TaskSourceSpan(
                    taskId: taskId,
                    range: NSRange(location: sourceStart, length: markerRange.location - sourceStart),
                    markerRange: markerRange)
            }
        }

        private func taskIdForTextChange(
            range: NSRange, in attributedText: NSAttributedString
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
            let taskIds = Set(candidates.map(\.taskId)).union(
                MarkdownTextView.taskScopeIDsTouchingRange(range, in: attributedText))
            guard taskIds.count == 1 else { return nil }
            return taskIds.first
        }

        private func prepareTaskTypingAttributes(taskId: String, on textView: NSTextView) {
            var attributes = MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
            attributes.removeValue(forKey: .holoTaskSourceLength)
            attributes[.holoTaskId] = taskId
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            textView.typingAttributes = attributes
        }

        private func refreshTaskSourceLengths(in attributedText: NSMutableAttributedString) {
            for span in taskSourceSpans(in: attributedText) {
                let sourceLength = max(0, span.range.length)
                let currentLength = (attributedText.attribute(
                    .holoTaskSourceLength,
                    at: span.markerRange.location,
                    effectiveRange: nil) as? NSNumber)?.intValue
                guard currentLength != sourceLength else { continue }
                attributedText.addAttribute(
                    .holoTaskSourceLength,
                    value: sourceLength,
                    range: span.markerRange)
            }
        }

        /// 中文组字提交后统一回写 sourceLength 并清理失去作用文字的标记（只改属性不重建文本）
        private func normalizeTaskMetadata(after textView: NSTextView) {
            let previousSelection = textView.selectedRange()
            isProgrammaticChange = true
            refreshTaskSourceLengths(in: textView.editorStorage)
            let removedMarkerRanges = removeEmptyTaskMarkers(in: textView.editorStorage)
            isProgrammaticChange = false

            let removedBeforeCaret = removedMarkerRanges
                .filter { $0.location < previousSelection.location }
                .reduce(0) { $0 + $1.length }
            let adjusted = NSRange(
                location: max(0, previousSelection.location - removedBeforeCaret),
                length: previousSelection.length)
            textView.setSelectedRange(MarkdownTextView.clampedRange(
                adjusted, for: textView.editorStorage.length))
            lastSelectionLocation = textView.selectedRange().location
            refreshTypingAttributes(for: textView)
        }

        private func applyTaskScope(taskId: String, to attributedText: NSMutableAttributedString) {
            guard attributedText.length > 0 else { return }
            let range = NSRange(location: 0, length: attributedText.length)
            attributedText.addAttribute(.holoTaskId, value: taskId, range: range)
            attributedText.addAttribute(
                .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }

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

        // MARK: - 转为任务（Phase E，与 iOS insertTaskMarks 同逻辑）

        /// 在富文本中批量写入任务关系标记（提取面板创建任务成功后回调）。
        /// 范围映射/重叠过滤复用共享的 MarkdownTextView.attributedTextByInsertingTaskMarks；
        /// 同一段文字再次转任务时新 taskId 覆盖旧范围，同次编辑清掉失去作用文字的孤立标记。
        private func insertTaskMarks(_ insertions: [TaskMarkInsertion], on textView: NSTextView) {
            guard let mutable = MarkdownTextView.attributedTextByInsertingTaskMarks(
                insertions,
                into: textView.editorStorage
            ) else { return }

            refreshTaskSourceLengths(in: mutable)
            removeEmptyTaskMarkers(in: mutable)

            performProgrammaticEdit(on: textView, actionName: String(localized: "转为任务")) {
                textView.editorStorage.setAttributedString(mutable)
                textView.setSelectedRange(NSRange(location: mutable.length, length: 0))
            }
            lastSelectionLocation = textView.selectedRange().location
            refreshTypingAttributes(for: textView)
        }

        /// 「转为任务」分流：有选中文字只转选中部分，无选中转整篇；
        /// 面板弹窗与落库由父视图承接（onConvertToTask），编辑器只负责报告选区。
        private func convertToTask(on textView: NSTextView) {
            let selection = textView.selectedRange()
            guard selection.length > 0 else {
                onConvertToTask?(nil, nil)
                return
            }
            let safeRange = MarkdownTextView.clampedRange(selection, for: textView.editorStorage.length)
            let selectedText = (textView.editorStorage.string as NSString).substring(with: safeRange)
            guard safeRange.length > 0,
                  !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                onConvertToTask?(nil, nil)
                return
            }
            onConvertToTask?(selectedText, safeRange)
        }

        private func removeTaskDecorations(
            for tokenRanges: [NSRange],
            from source: NSAttributedString,
            in mutable: NSMutableAttributedString
        ) {
            for tokenRange in tokenRanges {
                guard tokenRange.location < source.length,
                      let node = MarkdownTextView.makeTokenNode(
                        from: source.attributes(at: tokenRange.location, effectiveRange: nil)) else { continue }
                guard case .taskMark(_, let taskId, _, let sourceLength) = node else { continue }
                let sourceRange = NSRange(
                    location: max(0, tokenRange.location - max(0, sourceLength)),
                    length: min(max(0, sourceLength), tokenRange.location))
                removeTaskSourceDecoration(taskId: taskId, sourceRange: sourceRange, from: mutable)
            }
        }

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
                var userUnderlineRanges: [NSRange] = []
                attributedText.enumerateAttribute(.macHoloUnderline, in: range, options: []) { value, subrange, _ in
                    guard (value as? Bool) == true else { return }
                    userUnderlineRanges.append(subrange)
                }
                attributedText.removeAttribute(.holoTaskId, range: range)
                attributedText.removeAttribute(.underlineStyle, range: range)
                for userUnderlineRange in userUnderlineRanges {
                    attributedText.addAttribute(
                        .underlineStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: userUnderlineRange)
                }
            }
        }

        /// 统一构造普通文字进入编辑器时的属性：保留当前输入格式并继承目标任务范围
        private func makeTaskAwareReplacement(
            _ string: String, range: NSRange, in textView: NSTextView
        ) -> NSAttributedString {
            var attributes = MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
            attributes.removeValue(forKey: .holoTaskId)
            attributes.removeValue(forKey: .holoTaskSourceLength)
            if let taskId = taskIdForTextChange(range: range, in: textView.editorStorage) {
                attributes[.holoTaskId] = taskId
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            return NSAttributedString(string: string, attributes: attributes)
        }

        // MARK: - 编辑器撤销桥

        private func registerUndo(
            on textView: NSTextView,
            restoring attributedText: NSAttributedString,
            selectedRange: NSRange,
            actionName: String
        ) {
            let beforeText = NSAttributedString(attributedString: textView.editorStorage)
            let beforeSelection = textView.selectedRange()
            guard !beforeText.isEqual(to: attributedText) || beforeSelection != selectedRange else { return }

            textView.undoManager?.registerUndo(withTarget: self) { [weak textView] coordinator in
                guard let textView else { return }
                coordinator.restoreEditorState(
                    in: textView,
                    attributedText: attributedText,
                    selectedRange: selectedRange,
                    actionName: actionName)
            }
            textView.undoManager?.setActionName(actionName)
        }

        private func restoreEditorState(
            in textView: NSTextView,
            attributedText: NSAttributedString,
            selectedRange: NSRange,
            actionName: String
        ) {
            let currentText = NSAttributedString(attributedString: textView.editorStorage)
            let currentSelection = textView.selectedRange()
            textView.undoManager?.registerUndo(withTarget: self) { [weak textView] coordinator in
                guard let textView else { return }
                coordinator.restoreEditorState(
                    in: textView,
                    attributedText: currentText,
                    selectedRange: currentSelection,
                    actionName: actionName)
            }
            textView.undoManager?.setActionName(actionName)

            let undoManager = textView.undoManager
            undoManager?.disableUndoRegistration()
            isProgrammaticChange = true
            textView.editorStorage.setAttributedString(attributedText)
            textView.setSelectedRange(MarkdownTextView.clampedRange(
                selectedRange, for: attributedText.length))
            lastSelectionLocation = textView.selectedRange().location
            isProgrammaticChange = false
            undoManager?.enableUndoRegistration()

            refreshTypingAttributes(for: textView)
            syncMarkdown(from: textView)
            updateTriggerState(textView)
            reportCaretRect(textView)
        }

        @discardableResult
        private func performProgrammaticEdit(
            on textView: NSTextView,
            actionName: String,
            _ mutation: () -> Void
        ) -> NSAttributedString {
            let previousText = NSAttributedString(attributedString: textView.editorStorage)
            let previousSelection = textView.selectedRange()

            isProgrammaticChange = true
            mutation()
            isProgrammaticChange = false
            textView.scrollRangeToVisible(textView.selectedRange())

            registerUndo(
                on: textView,
                restoring: previousText,
                selectedRange: previousSelection,
                actionName: actionName)
            return NSAttributedString(attributedString: textView.editorStorage)
        }

        private func registerTypingUndo(
            on textView: NSTextView,
            restoring typingAttributes: [NSAttributedString.Key: Any],
            actionName: String
        ) {
            let previousExplicitBold = explicitBold
            let previousExplicitItalic = explicitItalic
            let previousExplicitUnderline = explicitUnderline
            let previousExplicitColorHex = explicitColorHex
            textView.undoManager?.registerUndo(withTarget: self) { [weak textView] coordinator in
                guard let textView else { return }
                coordinator.restoreTypingState(
                    in: textView,
                    typingAttributes: typingAttributes,
                    explicitBold: previousExplicitBold,
                    explicitItalic: previousExplicitItalic,
                    explicitUnderline: previousExplicitUnderline,
                    explicitColorHex: previousExplicitColorHex,
                    actionName: actionName)
            }
            textView.undoManager?.setActionName(actionName)
        }

        private func restoreTypingState(
            in textView: NSTextView,
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
                    actionName: actionName)
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

        /// 复制/剪切：选区触碰 Token 时展开到整段，序列化节点写入
        /// 纯文本 + Holo 节点 JSON（与 iOS copyNodesToPasteboard 同一函数）
        func performSemanticCopy(in textView: NSTextView, range: NSRange, deletes: Bool) -> Bool {
            guard let expanded = expandedTokenRange(range, in: textView),
                  expanded.length > 0,
                  MarkdownTextView.tokenRanges(in: textView.editorStorage).contains(where: {
                      NSIntersectionRange($0, expanded).length > 0
                  }) else {
                return false
            }
            let selectedText = textView.editorStorage.attributedSubstring(from: expanded)
            let nodes = MarkdownTextView.clipboardSafeNodes(
                from: MarkdownTextView.serializeNodes(from: selectedText))
            guard !nodes.isEmpty else { return false }
            MarkdownTextView.copyNodesToPasteboard(nodes)
            if deletes {
                textView.insertText("", replacementRange: expanded)
            }
            return true
        }

        /// 粘贴：优先恢复 Holo 节点身份；外部富文本只取纯文字（不带入外部字体/颜色）
        func performPaste(in textView: NSTextView) -> Bool {
            let pasteboard = NSPasteboard.general
            // 应用内结构化粘贴：恢复 @引用/#标签 身份，避免降级为普通文字
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(
                MarkdownTextView.semanticPasteboardType)),
               let json = String(data: data, encoding: .utf8),
               let nodes = try? RichContentSerializer.nodes(fromJSONString: json),
               pasteSemanticContent(nodes, in: textView) {
                return true
            }
            guard let string = pasteboard.string(forType: .string), !string.isEmpty else {
                return false
            }
            return pastePlainText(string, in: textView)
        }

        private func pasteSemanticContent(_ nodes: [HoloContentNode], in textView: NSTextView) -> Bool {
            let pasteNodes = MarkdownTextView.clipboardSafeNodes(from: nodes)
            guard !pasteNodes.isEmpty else { return false }

            let replacement = MarkdownTextView.applyingEditorLineSpacing(
                to: MarkdownTextView.makeAttributedText(from: pasteNodes))
            let requestedRange = MarkdownTextView.clampedRange(
                textView.selectedRange(), for: textView.editorStorage.length)
            guard let targetRange = expandedTokenRange(requestedRange, in: textView) else {
                return true
            }

            let intersectingTokens = MarkdownTextView.tokenRanges(in: textView.editorStorage).filter {
                NSIntersectionRange($0, targetRange).length > 0
            }
            let replacesTaskMarker = intersectingTokens.contains { tokenRange in
                guard let node = MarkdownTextView.makeTokenNode(
                    from: textView.editorStorage.attributes(
                        at: tokenRange.location, effectiveRange: nil)) else { return false }
                if case .taskMark = node { return true }
                return false
            }
            let destinationTaskId: String? = replacesTaskMarker
                ? nil
                : taskIdForTextChange(range: targetRange, in: textView.editorStorage)
            let taskAwareReplacement = NSMutableAttributedString(attributedString: replacement)
            if let destinationTaskId {
                applyTaskScope(taskId: destinationTaskId, to: taskAwareReplacement)
            }

            let mutable = NSMutableAttributedString(attributedString: textView.editorStorage)
            removeTaskDecorations(
                for: intersectingTokens, from: textView.editorStorage, in: mutable)
            mutable.replaceCharacters(in: targetRange, with: taskAwareReplacement)
            refreshTaskSourceLengths(in: mutable)
            removeEmptyTaskMarkers(in: mutable)
            performProgrammaticEdit(on: textView, actionName: String(localized: "粘贴 Holo 内容")) {
                textView.editorStorage.setAttributedString(mutable)
                textView.setSelectedRange(NSRange(
                    location: targetRange.location + taskAwareReplacement.length, length: 0))
            }
            lastSelectionLocation = textView.selectedRange().location
            refreshTypingAttributes(for: textView)
            syncMarkdown(from: textView)
            updateTriggerState(textView)
            return true
        }

        private func pastePlainText(_ string: String, in textView: NSTextView) -> Bool {
            let requestedRange = MarkdownTextView.clampedRange(
                textView.selectedRange(), for: textView.editorStorage.length)
            if handleTokenEditInterception(
                textView, range: requestedRange, replacementText: string) {
                return true
            }
            let replacement = makeTaskAwareReplacement(string, range: requestedRange, in: textView)
            let mutable = NSMutableAttributedString(attributedString: textView.editorStorage)
            mutable.replaceCharacters(in: requestedRange, with: replacement)
            refreshTaskSourceLengths(in: mutable)
            removeEmptyTaskMarkers(in: mutable)
            performProgrammaticEdit(on: textView, actionName: String(localized: "粘贴文字")) {
                textView.editorStorage.setAttributedString(mutable)
                textView.setSelectedRange(NSRange(
                    location: requestedRange.location + replacement.length, length: 0))
            }
            refreshTypingAttributes(for: textView)
            syncMarkdown(from: textView)
            updateTriggerState(textView)
            return true
        }

        // MARK: - 动作管线（工具栏 / 快捷键）

        func perform(action: MarkdownEditorAction, on textView: NSTextView) {
            if textView.hasMarkedText() { return }
            if textView.window?.firstResponder != textView {
                textView.window?.makeFirstResponder(textView)
            }

            switch action {
            case .toggleBold:
                toggleInlineStyle(on: textView, attribute: .holoBold, value: true)
            case .toggleItalic:
                toggleInlineStyle(on: textView, attribute: .macHoloItalic, value: true)
            case .toggleUnderline:
                toggleInlineStyle(on: textView, attribute: .macHoloUnderline, value: true)
            case .setColor(let hex):
                setInlineColor(hex: hex, on: textView)
            case .insertUnorderedList:
                insertAtLineStart("\u{2022} ", on: textView)
            case .insertOrderedList:
                insertAtLineStart("1. ", on: textView)
            case .insertText(let text):
                insertPlain(text, on: textView)
            case .insertTriggerCharacter(let character):
                insertTriggerCharacter(character, on: textView)
            case .insertTagToken(let id, let displayPath):
                insertToken(type: .tag, id: id, displayText: displayPath, snapshot: nil, on: textView)
            case .insertReferenceToken(let id, let displayText, let snapshot):
                insertToken(type: .reference, id: id, displayText: displayText, snapshot: snapshot, on: textView)
            case .insertTaskMark(let taskId, let displayText, let sourceRange):
                insertTaskMarks(
                    [TaskMarkInsertion(taskId: taskId, displayText: displayText, sourceRange: sourceRange)],
                    on: textView)
            case .insertTaskMarks(let insertions):
                insertTaskMarks(insertions, on: textView)
            case .convertToTask:
                convertToTask(on: textView)
            case .removeSelectedToken:
                removeSelectedToken(on: textView)
            case .dismissSuggestion:
                dismissSuggestion()
            }

            if !textView.hasMarkedText() {
                syncMarkdown(from: textView)
            }
            updatePlaceholderVisibility(in: textView)
        }

        // MARK: - 输入属性

        func refreshTypingAttributes(for textView: NSTextView) {
            var typingAttributes = MarkdownTextView.baseAttributes
            let location = max(0, min(textView.selectedRange().location, textView.editorStorage.length))

            if textView.selectedRange().length > 0, location < textView.editorStorage.length {
                typingAttributes.merge(
                    MarkdownTextView.inlineAttributes(at: location, in: textView.editorStorage)
                ) { _, new in new }
            } else if location > 0, location - 1 < textView.editorStorage.length {
                typingAttributes.merge(
                    MarkdownTextView.inlineAttributes(at: location - 1, in: textView.editorStorage)
                ) { _, new in new }
            }

            if let bold = explicitBold {
                if bold {
                    typingAttributes[.holoBold] = true
                } else {
                    typingAttributes.removeValue(forKey: .holoBold)
                }
            }
            if let italic = explicitItalic {
                if italic {
                    typingAttributes[.macHoloItalic] = true
                } else {
                    typingAttributes.removeValue(forKey: .macHoloItalic)
                }
            }
            if let underline = explicitUnderline {
                if underline {
                    typingAttributes[.macHoloUnderline] = true
                } else {
                    typingAttributes.removeValue(forKey: .macHoloUnderline)
                }
            }
            if let colorHex = explicitColorHex {
                typingAttributes[.holoColorHex] = colorHex
                typingAttributes[.foregroundColor] = MarkdownTextView.resolvedTextColor(for: colorHex)
            }

            // 打字属性携带编辑态行距；任务范围带进组字属性（中文提交后继续显示下划线）
            typingAttributes.removeValue(forKey: .holoTaskId)
            typingAttributes.removeValue(forKey: .holoTaskSourceLength)
            if let taskId = taskIdForTextChange(
                range: NSRange(location: location, length: 0), in: textView.editorStorage) {
                typingAttributes[.holoTaskId] = taskId
                typingAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            typingAttributes[.font] = MarkdownTextView.font(from: typingAttributes)
            if typingAttributes[.foregroundColor] == nil {
                typingAttributes[.foregroundColor] = MarkdownTextView.baseTextColor
            }
            if let paragraphStyle = typingAttributes[.paragraphStyle] as? NSParagraphStyle,
               let mutableStyle = paragraphStyle.mutableCopy() as? NSMutableParagraphStyle,
               let typingFont = typingAttributes[.font] as? NSFont {
                mutableStyle.lineSpacing = MarkdownTextView.editorLineSpacing(for: typingFont)
                typingAttributes[.paragraphStyle] = mutableStyle
            }
            textView.typingAttributes = typingAttributes
            notifyFormatState(typingAttributes)
        }

        private func notifyFormatState(_ typingAttributes: [NSAttributedString.Key: Any]) {
            formatState = TypingFormatState(
                isBold: (typingAttributes[.holoBold] as? Bool) == true,
                isItalic: (typingAttributes[.macHoloItalic] as? Bool) == true,
                isUnderline: (typingAttributes[.macHoloUnderline] as? Bool) == true,
                colorHex: typingAttributes[.holoColorHex] as? String)
        }

        // MARK: - 行内格式

        private func toggleInlineStyle(
            on textView: NSTextView, attribute: NSAttributedString.Key, value: Bool
        ) {
            let safeRange = MarkdownTextView.clampedRange(
                textView.selectedRange(), for: textView.editorStorage.length)

            if safeRange.length == 0 {
                let previousTypingAttributes = textView.typingAttributes
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

                if attribute == .holoBold { explicitBold = !isActive }
                if attribute == .macHoloItalic { explicitItalic = !isActive }
                if attribute == .macHoloUnderline { explicitUnderline = !isActive }
                notifyFormatState(typingAttributes)
                registerTypingUndo(
                    on: textView,
                    restoring: previousTypingAttributes,
                    actionName: String(localized: "修改输入样式"))
                return
            }

            let mutable = NSMutableAttributedString(attributedString: textView.editorStorage)
            // Token 是语义整体：跨 Token 选区只处理普通文字子区间
            let editableRanges = MarkdownTextView.nonTokenRanges(
                in: safeRange, attributedText: mutable)
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
                textView.editorStorage.setAttributedString(mutable)
                textView.setSelectedRange(safeRange)
            }
            refreshTypingAttributes(for: textView)
        }

        private func setInlineColor(hex: String, on textView: NSTextView) {
            let safeRange = MarkdownTextView.clampedRange(
                textView.selectedRange(), for: textView.editorStorage.length)

            if safeRange.length == 0 {
                let previousTypingAttributes = textView.typingAttributes
                explicitColorHex = hex
                refreshTypingAttributes(for: textView)
                registerTypingUndo(
                    on: textView,
                    restoring: previousTypingAttributes,
                    actionName: String(localized: "修改输入颜色"))
                return
            }

            let editableRanges = MarkdownTextView.nonTokenRanges(
                in: safeRange, attributedText: textView.editorStorage)
            guard !editableRanges.isEmpty else {
                refreshTypingAttributes(for: textView)
                return
            }
            explicitColorHex = nil

            let mutable = NSMutableAttributedString(attributedString: textView.editorStorage)
            mutable.beginEditing()
            for range in editableRanges {
                let attrs = mutable.attributes(at: range.location, effectiveRange: nil)
                var updated = attrs
                updated[.holoColorHex] = hex
                MarkdownTextView.applyResolvedAttributes(updated, to: mutable, range: range)
            }
            mutable.endEditing()

            performProgrammaticEdit(on: textView, actionName: String(localized: "修改文字颜色")) {
                textView.editorStorage.setAttributedString(mutable)
                textView.setSelectedRange(safeRange)
            }
            refreshTypingAttributes(for: textView)
        }

        private func insertPlain(_ string: String, on textView: NSTextView) {
            let safeRange = MarkdownTextView.clampedRange(
                textView.selectedRange(), for: textView.editorStorage.length)
            let insertion = makeTaskAwareReplacement(string, range: safeRange, in: textView)
            let mutable = NSMutableAttributedString(attributedString: textView.editorStorage)
            mutable.replaceCharacters(in: safeRange, with: insertion)
            performProgrammaticEdit(on: textView, actionName: String(localized: "插入文字")) {
                textView.editorStorage.setAttributedString(mutable)
                textView.setSelectedRange(NSRange(
                    location: safeRange.location + insertion.length, length: 0))
            }
            refreshTypingAttributes(for: textView)
        }

        // MARK: - 列表

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

        private func existingListPrefix(in text: NSString, at lineStart: Int) -> ExistingListPrefix? {
            guard lineStart <= text.length else { return nil }
            let remainingLength = text.length - lineStart
            let newlineRange = text.range(
                of: "\n", options: [], range: NSRange(location: lineStart, length: remainingLength))
            let lineEnd = newlineRange.location == NSNotFound ? text.length : newlineRange.location
            let line = text.substring(
                with: NSRange(location: lineStart, length: max(0, lineEnd - lineStart)))

            if let match = Self.listPrefixMatch(pattern: "^[\\-\\*\u{2022}] ", in: line) {
                return ExistingListPrefix(
                    range: NSRange(location: lineStart, length: match.length), kind: .unordered)
            }
            if let match = Self.listPrefixMatch(pattern: "^(\\d+)\\. ", in: line) {
                return ExistingListPrefix(
                    range: NSRange(location: lineStart, length: match.length), kind: .ordered)
            }
            return nil
        }

        /// 回车列表续行 / 空列表项退出列表。返回 true 表示已拦截（不再插入原生换行）。
        private func handleListContinuation(
            in textView: NSTextView, insertLocation: Int, taskId: String?
        ) -> Bool {
            let currentText = textView.editorStorage.string as NSString
            let lineStart = MarkdownTextView.lineStart(in: currentText, before: insertLocation)
            let lineLength = max(0, insertLocation - lineStart)
            let currentLine = currentText.substring(
                with: NSRange(location: lineStart, length: lineLength))

            // 无序列表（- * • 三种前缀）
            if let match = Self.listPrefixMatch(pattern: "^[\\-\\*\u{2022}] ", in: currentLine) {
                let contentAfterPrefix = String(
                    currentLine.dropFirst(match.length)).trimmingCharacters(in: .whitespaces)

                let mutable = NSMutableAttributedString(attributedString: textView.editorStorage)
                if contentAfterPrefix.isEmpty {
                    // 空列表项：退出列表
                    mutable.deleteCharacters(in: NSRange(location: lineStart, length: lineLength))
                    mutable.insert(
                        NSAttributedString(
                            string: "\n", attributes: textView.typingAttributes),
                        at: lineStart)
                    refreshTaskSourceLengths(in: mutable)
                    removeEmptyTaskMarkers(in: mutable)
                    performProgrammaticEdit(on: textView, actionName: String(localized: "退出无序列表")) {
                        textView.editorStorage.setAttributedString(mutable)
                        textView.setSelectedRange(NSRange(location: lineStart + 1, length: 0))
                    }
                } else {
                    // 续行：新行 + 圆点前缀
                    let prefixAttrs = MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
                    mutable.insert(
                        NSAttributedString(string: "\n\u{2022} ", attributes: prefixAttrs),
                        at: insertLocation)
                    refreshTaskSourceLengths(in: mutable)
                    removeEmptyTaskMarkers(in: mutable)
                    performProgrammaticEdit(on: textView, actionName: String(localized: "续写无序列表")) {
                        textView.editorStorage.setAttributedString(mutable)
                        textView.setSelectedRange(NSRange(location: insertLocation + 3, length: 0))
                    }
                }
                syncMarkdown(from: textView)
                return true
            }

            // 有序列表
            if let match = Self.listPrefixMatch(pattern: "^(\\d+)\\. ", in: currentLine),
               match.numberValue != nil {
                let prefixEnd = currentLine.index(
                    currentLine.startIndex, offsetBy: match.length,
                    limitedBy: currentLine.endIndex) ?? currentLine.endIndex
                let contentAfterPrefix = String(currentLine[prefixEnd...])
                    .trimmingCharacters(in: .whitespaces)

                let mutable = NSMutableAttributedString(attributedString: textView.editorStorage)
                if contentAfterPrefix.isEmpty {
                    mutable.deleteCharacters(in: NSRange(location: lineStart, length: lineLength))
                    mutable.insert(
                        NSAttributedString(
                            string: "\n", attributes: textView.typingAttributes),
                        at: lineStart)
                    refreshTaskSourceLengths(in: mutable)
                    removeEmptyTaskMarkers(in: mutable)
                    performProgrammaticEdit(on: textView, actionName: String(localized: "退出有序列表")) {
                        textView.editorStorage.setAttributedString(mutable)
                        textView.setSelectedRange(NSRange(location: lineStart + 1, length: 0))
                    }
                } else {
                    let nextNumber = (match.numberValue ?? 0) + 1
                    let prefixAttrs = MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
                    let newPrefix = "\n\(nextNumber). "
                    mutable.insert(
                        NSAttributedString(string: newPrefix, attributes: prefixAttrs),
                        at: insertLocation)
                    refreshTaskSourceLengths(in: mutable)
                    removeEmptyTaskMarkers(in: mutable)
                    performProgrammaticEdit(on: textView, actionName: String(localized: "续写有序列表")) {
                        textView.editorStorage.setAttributedString(mutable)
                        textView.setSelectedRange(NSRange(
                            location: insertLocation + (newPrefix as NSString).length, length: 0))
                    }
                }
                syncMarkdown(from: textView)
                return true
            }

            if let taskId {
                prepareTaskTypingAttributes(taskId: taskId, on: textView)
            }
            return false
        }

        /// 工具栏列表按钮：选中多行时每行都加前缀；已是同类列表则整段移除（开关语义）
        private func insertAtLineStart(_ prefix: String, on textView: NSTextView) {
            let currentText = textView.editorStorage.string as NSString
            let safeRange = MarkdownTextView.clampedRange(
                textView.selectedRange(), for: currentText.length)
            let mutable = NSMutableAttributedString(attributedString: textView.editorStorage)

            let lineStarts = MarkdownTextView.lineStartLocations(in: currentText, for: safeRange)
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
                    guard targetKind == .ordered || existing.kind != targetKind else { continue }
                    let replacement = makeTaskAwareReplacement(
                        linePrefix, range: existing.range, in: textView)
                    mutable.replaceCharacters(in: existing.range, with: replacement)
                    edits.append(ListEdit(range: existing.range, newLength: replacement.length))
                } else {
                    let insert = makeTaskAwareReplacement(
                        linePrefix, range: NSRange(location: lineStart, length: 0), in: textView)
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
                length: safeRange.length + selectionLengthShift)
            refreshTaskSourceLengths(in: mutable)
            removeEmptyTaskMarkers(in: mutable)
            // 列表动作是即时编辑：同步给选区段落写悬挂缩进，长文本第二行不顶格
            let finalText = mutable.string as NSString
            let paragraphStyle = Self.listParagraphStyle(isList: !shouldRemoveTargetList)
            for lineStart in MarkdownTextView.lineStartLocations(in: finalText, for: newSelection) {
                let remainingLength = finalText.length - lineStart
                let newlineRange = finalText.range(
                    of: "\n", options: [],
                    range: NSRange(location: lineStart, length: remainingLength))
                let lineEnd = newlineRange.location == NSNotFound
                    ? finalText.length
                    : newlineRange.location
                let lineLength = max(0, lineEnd - lineStart)
                guard lineLength > 0 else { continue }
                mutable.addAttribute(
                    .paragraphStyle,
                    value: paragraphStyle,
                    range: NSRange(location: lineStart, length: lineLength))
            }
            performProgrammaticEdit(on: textView, actionName: String(localized: "插入列表")) {
                textView.editorStorage.setAttributedString(mutable)
                textView.setSelectedRange(newSelection)
            }
            refreshTypingAttributes(for: textView)
        }

        /// 与共享渲染的 listContentIndent 同一基线（MarkdownTextView.paragraphStyle(forList:)
        /// 为 fileprivate，此处按同一公式复刻）
        static func listParagraphStyle(isList: Bool) -> NSParagraphStyle {
            let indent = max(24, MarkdownTextView.baseFont.pointSize * 1.4)
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 6
            style.firstLineHeadIndent = 0
            style.headIndent = isList ? indent : 0
            return style
        }

        // MARK: - 列表前缀辅助

        private struct ListPrefixResult {
            let length: Int
            let numberValue: Int?
        }

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

        /// 行首快打判定：即将插入空格的位置前一字符是「- / + / *」且位于行首
        static func inlineBulletPrefixRange(in ns: NSString, insertLocation: Int) -> NSRange? {
            guard insertLocation >= 1, insertLocation <= ns.length else { return nil }
            let prefixLocation = insertLocation - 1
            let prefix = ns.substring(with: NSRange(location: prefixLocation, length: 1))
            guard prefix == "-" || prefix == "+" || prefix == "*" else { return nil }
            guard prefixLocation == 0 || ns.character(at: prefixLocation - 1) == 0x0A else { return nil }
            return NSRange(location: prefixLocation, length: 1)
        }
    }
}
