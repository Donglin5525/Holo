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
    case insertUnorderedList
    case insertOrderedList
    case insertText(String)
    /// 工具栏 #/@ 按钮：原文插入触发字符并进入搜索态
    case insertTriggerCharacter(String)
    /// 候选面板选中标签：触发区间整体替换为标签 Token
    case insertTagToken(id: UUID, displayPath: String)
    /// 候选面板选中想法：触发区间整体替换为引用 Token
    case insertReferenceToken(id: UUID, displayText: String, snapshot: String)
    /// 把当前选中的 Token 转为普通文本（移除标签 / 取消引用）
    case removeSelectedToken
    /// 主动关闭候选面板（保留已输入文字，本次触发不再自动弹出）
    case dismissSuggestion
}

// MARK: - TypingFormatState

/// 当前光标处的格式状态，用于工具栏按钮高亮反馈
struct TypingFormatState: Equatable {
    var isBold: Bool = false
}

// MARK: - MarkdownTextView

/// 支持 Markdown 编辑的文本视图
/// 编辑时展示富文本效果，底层仍使用 markdown 字符串存储
struct MarkdownTextView: UIViewRepresentable {

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

    /// 是否启用富文本渲染
    var showHighlight: Bool = true
    /// UIKit 文本容器内边距，便于外层悬浮按钮预留空间
    var textContainerInset: UIEdgeInsets = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
    /// 编辑已有想法时的结构化内容（恢复 Token；nil=纯文本）
    var initialRichJSON: String? = nil
    /// 节点模型变化回调（保存时取 richContentJSON 用）
    var onNodesChange: (([HoloContentNode]) -> Void)? = nil

    func makeUIView(context: Context) -> UITextView {
        let textView = SelfSizingTextView()
        textView.delegate = context.coordinator
        textView.font = Self.baseFont
        textView.textColor = Self.baseTextColor
        textView.backgroundColor = .clear
        textView.textContainerInset = textContainerInset
        // 初始启用滚动，SelfSizingTextView.layoutSubviews() 会根据内容与 frame 的关系动态切换
        // 内容不超出 frame 时自动禁用，让外层 SwiftUI ScrollView 接管滚动手势
        textView.isScrollEnabled = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsEditingTextAttributes = true
        textView.autocorrectionType = .default
        textView.spellCheckingType = .default
        textView.keyboardType = .default
        textView.typingAttributes = Self.baseAttributes
        let initialNodes = RichContentSerializer.nodes(richJSON: initialRichJSON, fallbackPlainText: text)
        textView.attributedText = showHighlight ? Self.makeAttributedText(from: initialNodes) : NSAttributedString(string: text, attributes: Self.baseAttributes)

        // 以节点派生文本为准，保证 JSON 场景下绑定与编辑器内容一致
        context.coordinator.lastKnownMarkdown = RichContentSerializer.plainText(from: initialNodes)
        context.coordinator.nodes = initialNodes
        context.coordinator.onNodesChange = onNodesChange
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
        context.coordinator.refreshTypingAttributes(for: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if let action = pendingAction {
            pendingAction = nil
            context.coordinator.perform(action: action, on: textView, markdown: $text)
            return
        }

        if !context.coordinator.isProgrammaticChange,
           textView.markedTextRange == nil,
           text != context.coordinator.lastKnownMarkdown {
            let preservedSelection = Self.clampedRange(textView.selectedRange, for: textView.attributedText.length)
            let newNodes = RichContentSerializer.nodes(fromPlainText: text)
            let attributedText = showHighlight
                ? Self.makeAttributedText(from: newNodes)
                : NSAttributedString(string: text, attributes: Self.baseAttributes)
            context.coordinator.isProgrammaticChange = true
            textView.attributedText = attributedText
            textView.selectedRange = Self.clampedRange(preservedSelection, for: attributedText.length)
            context.coordinator.isProgrammaticChange = false
            context.coordinator.lastKnownMarkdown = text
            context.coordinator.nodes = newNodes
            context.coordinator.refreshTypingAttributes(for: textView)
        }

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
        /// 编辑期结构化内容模型（事实源）：文本变化时由富文本属性重建，Token 节点不被重渲染销毁
        var nodes: [HoloContentNode] = []
        var onHeightChange: ((CGFloat) -> Void)?
        var onFormatStateChange: ((TypingFormatState) -> Void)?
        var onNodesChange: (([HoloContentNode]) -> Void)?

        /// 当前活跃的 #/@ 触发（候选面板打开期间非空）
        private var activeTrigger: EditorTriggerContext?
        /// 上次选区位置（区分点按 vs 键盘移动光标）
        private var lastSelectionLocation: Int = 0
        /// 已发布的触发状态（避免重复写绑定触发 SwiftUI 刷新）
        private var lastPublishedTrigger: EditorTriggerContext?
        /// 被用户手动关闭的触发起点（同一触发片段内不再自动弹出面板）
        private var suppressedTriggerLocation: Int?

        // 用户显式切换的加粗状态（Word-like sticky toggle）
        // nil = 无显式状态，走 contextual 推断
        // true = 强制开启，false = 强制关闭（覆盖 contextual）
        var explicitBold: Bool? = nil

        init(text: Binding<String>, triggerContext: Binding<EditorTriggerContext?>, selectedToken: Binding<HoloContentNode?>) {
            self._text = text
            self._triggerContext = triggerContext
            self._selectedToken = selectedToken
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isProgrammaticChange else { return }
            guard textView.markedTextRange == nil else { return }
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

            // 只处理回车键的列表续行逻辑
            guard text == "\n" else { return true }

            let currentText = textView.attributedText.string as NSString
            let cursorLocation = range.location

            // 找到当前行的起始位置
            var lineStart = 0
            if cursorLocation > 0 {
                let substring = currentText.substring(with: NSRange(location: 0, length: cursorLocation))
                if let lastNewline = substring.lastIndex(of: "\n") {
                    lineStart = substring.distance(from: substring.startIndex, to: lastNewline) + 1
                }
            }

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

                    isProgrammaticChange = true
                    textView.attributedText = mutable
                    textView.selectedRange = NSRange(location: lineStart + 1, length: 0)
                    isProgrammaticChange = false
                    syncMarkdown(from: textView)
                    return false
                }

                // 续行：插入新行 + 圆角点前缀
                let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
                let prefixAttrs = MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
                mutable.insert(NSAttributedString(string: "\n\u{2022} ", attributes: prefixAttrs), at: cursorLocation)

                isProgrammaticChange = true
                textView.attributedText = mutable
                textView.selectedRange = NSRange(location: cursorLocation + 3, length: 0)
                isProgrammaticChange = false
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

                    isProgrammaticChange = true
                    textView.attributedText = mutable
                    textView.selectedRange = NSRange(location: lineStart + 1, length: 0)
                    isProgrammaticChange = false
                    syncMarkdown(from: textView)
                    return false
                }

                let nextNumber = (match.numberValue ?? 0) + 1
                let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
                let prefixAttrs = MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
                let newPrefix = "\n\(nextNumber). "
                mutable.insert(NSAttributedString(string: newPrefix, attributes: prefixAttrs), at: cursorLocation)

                isProgrammaticChange = true
                textView.attributedText = mutable
                textView.selectedRange = NSRange(location: cursorLocation + (newPrefix as NSString).length, length: 0)
                isProgrammaticChange = false
                syncMarkdown(from: textView)
                return false
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
            updateSelectedTokenState(textView)
            lastSelectionLocation = textView.selectedRange.location
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            activeTrigger = nil
            publishTrigger(nil)
            publishSelectedToken(nil)
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
            case .removeSelectedToken:
                removeSelectedToken(on: textView)
            case .dismissSuggestion:
                dismissSuggestion()
            }

            if textView.markedTextRange == nil {
                syncMarkdown(from: textView)
            }
            markdown.wrappedValue = lastKnownMarkdown
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

            // 叠加用户显式切换的加粗状态（sticky toggle，Word-like 行为）
            if let bold = explicitBold {
                if bold {
                    typingAttributes[.holoBold] = true
                } else {
                    typingAttributes.removeValue(forKey: .holoBold)
                }
            }

            typingAttributes[.font] = MarkdownTextView.font(from: typingAttributes)
            if typingAttributes[.foregroundColor] == nil {
                typingAttributes[.foregroundColor] = MarkdownTextView.baseTextColor
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
            mutable.replaceCharacters(in: unionRange, with: text)

            isProgrammaticChange = true
            textView.attributedText = mutable
            textView.selectedRange = NSRange(location: unionRange.location + (text as NSString).length, length: 0)
            isProgrammaticChange = false

            syncMarkdown(from: textView)
            updateTriggerState(textView)
            return true
        }

        /// Token 原子化选区调整：光标进入 Token 内部时吸附到边缘（键盘）或选中整个 Token（点按）；
        /// 选区横跨 Token 一部分时扩展为完整 Token
        /// - Returns: true 表示选区已被调整（等待重入回调）
        private func adjustSelectionForTokenAtomicity(_ textView: UITextView) -> Bool {
            let tokenRanges = MarkdownTextView.tokenRanges(in: textView.attributedText)
            guard !tokenRanges.isEmpty else { return false }

            let selection = textView.selectedRange

            if selection.length == 0 {
                guard let token = tokenRanges.first(where: {
                    selection.location > $0.location && selection.location < $0.location + $0.length
                }) else { return false }

                // 移动距离 >1 视为点按：选中整个 Token；否则吸附到较近边缘
                let isTap = abs(selection.location - lastSelectionLocation) > 1
                let newSelection: NSRange
                if isTap {
                    newSelection = token
                } else {
                    let distanceToStart = selection.location - token.location
                    let distanceToEnd = token.location + token.length - selection.location
                    newSelection = NSRange(
                        location: distanceToStart <= distanceToEnd ? token.location : token.location + token.length,
                        length: 0
                    )
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

        /// 选区恰好覆盖一个完整 Token 时，向 SwiftUI 发布「Token 被选中」（弹操作菜单）
        private func updateSelectedTokenState(_ textView: UITextView) {
            let selection = textView.selectedRange
            guard selection.length > 0 else {
                publishSelectedToken(nil)
                return
            }

            let tokenRanges = MarkdownTextView.tokenRanges(in: textView.attributedText)
            guard let token = tokenRanges.first(where: {
                $0.location == selection.location && $0.length == selection.length
            }),
                  let node = MarkdownTextView.makeTokenNode(from: textView.attributedText.attributes(at: token.location, effectiveRange: nil)) else {
                publishSelectedToken(nil)
                return
            }

            publishSelectedToken(node)
        }

        private func publishSelectedToken(_ node: HoloContentNode?) {
            guard node != selectedToken else { return }
            DispatchQueue.main.async { [weak self] in
                self?.selectedToken = node
            }
        }

        /// 工具栏触发按钮：在光标处插入 # 或 @，并立即进入搜索态
        private func insertTriggerCharacter(_ character: String, on textView: UITextView) {
            let safeRange = MarkdownTextView.clampedRange(textView.selectedRange, for: textView.attributedText.length)
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let insertion = NSAttributedString(
                string: character,
                attributes: MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
            )
            mutable.replaceCharacters(in: safeRange, with: insertion)

            isProgrammaticChange = true
            textView.attributedText = mutable
            textView.selectedRange = NSRange(location: safeRange.location + (character as NSString).length, length: 0)
            isProgrammaticChange = false

            refreshTypingAttributes(for: textView)
            syncMarkdown(from: textView)
            updateTriggerState(textView)
        }

        /// 候选选中：把触发区间整体替换为 Token，尾随一个空格，光标移到空格后（一次完整 undo 单元）
        private func insertToken(type: HoloTokenType, id: UUID, displayText: String, snapshot: String?, on textView: UITextView) {
            guard let trigger = activeTrigger else { return }

            let tokenText = MarkdownTextView.makeTokenAttributedText(type: type, id: id, displayText: displayText, snapshot: snapshot)
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let safeRange = MarkdownTextView.clampedRange(trigger.range, for: mutable.length)
            mutable.replaceCharacters(in: safeRange, with: tokenText)

            let spaceLocation = safeRange.location + tokenText.length
            mutable.insert(NSAttributedString(string: " ", attributes: MarkdownTextView.baseAttributes), at: spaceLocation)

            isProgrammaticChange = true
            textView.attributedText = mutable
            textView.selectedRange = NSRange(location: spaceLocation + 1, length: 0)
            lastSelectionLocation = spaceLocation + 1
            isProgrammaticChange = false

            activeTrigger = nil
            publishTrigger(nil)
            refreshTypingAttributes(for: textView)
            syncMarkdown(from: textView)
        }

        /// 把选中的 Token 转为普通文本（保留文字、去除 #/@ 前缀与 Token 关系）
        private func removeSelectedToken(on textView: UITextView) {
            let tokenRanges = MarkdownTextView.tokenRanges(in: textView.attributedText)
            let selection = textView.selectedRange
            guard let tokenRange = tokenRanges.first(where: { NSIntersectionRange($0, selection).length > 0 }),
                  let node = MarkdownTextView.makeTokenNode(from: textView.attributedText.attributes(at: tokenRange.location, effectiveRange: nil)) else { return }

            let plainText: String
            switch node {
            case .tag(_, let displayPath):
                plainText = displayPath
            case .reference(_, let displayText, _):
                plainText = displayText
            case .text:
                return
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            mutable.replaceCharacters(
                in: tokenRange,
                with: NSAttributedString(string: plainText, attributes: MarkdownTextView.baseAttributes)
            )

            isProgrammaticChange = true
            textView.attributedText = mutable
            textView.selectedRange = NSRange(location: tokenRange.location + (plainText as NSString).length, length: 0)
            isProgrammaticChange = false

            publishSelectedToken(nil)
            refreshTypingAttributes(for: textView)
            syncMarkdown(from: textView)
        }

        private func toggleInlineStyle(on textView: UITextView, attribute: NSAttributedString.Key, value: Bool) {
            let safeRange = MarkdownTextView.clampedRange(textView.selectedRange, for: textView.attributedText.length)

            if safeRange.length == 0 {
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
                notifyFormatState(typingAttributes)
                return
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let shouldEnable = !MarkdownTextView.rangeHasAttribute(attribute, in: mutable, range: safeRange)

            mutable.beginEditing()
            mutable.enumerateAttributes(in: safeRange, options: []) { attrs, range, _ in
                var updated = attrs
                if shouldEnable {
                    updated[attribute] = value
                } else {
                    updated.removeValue(forKey: attribute)
                }
                MarkdownTextView.applyResolvedAttributes(updated, to: mutable, range: range)
            }
            mutable.endEditing()

            isProgrammaticChange = true
            textView.attributedText = mutable
            textView.selectedRange = safeRange
            isProgrammaticChange = false
            refreshTypingAttributes(for: textView)
        }

        private func insertAtLineStart(_ prefix: String, on textView: UITextView) {
            let currentText = textView.attributedText.string as NSString
            let safeRange = MarkdownTextView.clampedRange(textView.selectedRange, for: currentText.length)
            let cursorLocation = safeRange.location

            var lineStart = 0
            if cursorLocation > 0 {
                let substring = currentText.substring(with: NSRange(location: 0, length: cursorLocation))
                if let lastNewline = substring.lastIndex(of: "\n") {
                    lineStart = substring.distance(from: substring.startIndex, to: lastNewline) + 1
                }
            }

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let prefixAttributes = textView.typingAttributes.merging(MarkdownTextView.baseAttributes) { current, _ in current }
            let insert = NSAttributedString(string: prefix, attributes: MarkdownTextView.resolvedAttributes(from: prefixAttributes))
            mutable.insert(insert, at: lineStart)

            let newCursorLocation = cursorLocation + (prefix as NSString).length
            isProgrammaticChange = true
            textView.attributedText = mutable
            textView.selectedRange = NSRange(location: newCursorLocation, length: safeRange.length)
            isProgrammaticChange = false
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
            let insert = NSAttributedString(
                string: insertionText,
                attributes: MarkdownTextView.resolvedAttributes(from: textView.typingAttributes)
            )
            mutable.replaceCharacters(in: safeRange, with: insert)

            isProgrammaticChange = true
            textView.attributedText = mutable
            textView.selectedRange = NSRange(location: safeRange.location + (insertionText as NSString).length, length: 0)
            isProgrammaticChange = false
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
                isBold: (typingAttributes[.holoBold] as? Bool) == true
            ))
        }
    }
}

// MARK: - 富文本转换

private extension MarkdownTextView {
    struct RenderStyle {
        var isBold = false
        var isItalic = false
        var isUnderline = false
        var colorHex: String?
    }

    static let baseFont = UIFont.systemFont(ofSize: 16, weight: .medium)
    static let baseTextColor = UIColor(Color.holoTextPrimary)
    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: baseFont,
        .foregroundColor: baseTextColor,
        .paragraphStyle: baseParagraphStyle()
    ]

    private static func baseParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 8
        return style
    }

    static func makeAttributedText(from markdown: String) -> NSAttributedString {
        let document = MarkdownParser.parse(markdown)
        let result = NSMutableAttributedString()

        for (index, node) in document.children.enumerated() {
            append(node: node, to: result, style: RenderStyle())
            if index < document.children.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: baseAttributes))
            }
        }

        if result.length == 0 {
            return NSAttributedString(string: "", attributes: baseAttributes)
        }

        return result
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
            var bulletAttrs = baseAttributes
            bulletAttrs[.foregroundColor] = UIColor(Color.holoTextSecondary)
            result.append(NSAttributedString(string: "\u{2022} ", attributes: bulletAttrs))
            appendInlineNodes(item.children, to: result, style: style)

        case let item as OrderedListItemNode:
            var numberAttrs = baseAttributes
            numberAttrs[.foregroundColor] = UIColor(Color.holoTextSecondary)
            result.append(NSAttributedString(string: "\(item.index). ", attributes: numberAttrs))
            appendInlineNodes(item.children, to: result, style: style)

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
            }
        }

        if result.length == 0 {
            return NSAttributedString(string: "", attributes: baseAttributes)
        }

        return result
    }

    /// 富文本 → 节点模型：Token 属性区间还原为 Token 节点，普通区间按 Markdown 序列化合并为 text 节点
    /// Token 属性残缺（如被部分删除）时降级为普通文本，保证文字不丢
    static func serializeNodes(from attributedText: NSAttributedString) -> [HoloContentNode] {
        guard attributedText.length > 0 else { return [] }

        var nodes: [HoloContentNode] = []
        var textBuffer = ""

        func flushTextBuffer() {
            guard !textBuffer.isEmpty else { return }
            nodes.append(.text(value: textBuffer))
            textBuffer = ""
        }

        attributedText.enumerateAttributes(in: NSRange(location: 0, length: attributedText.length), options: []) { attrs, range, _ in
            let text = attributedText.attributedSubstring(from: range).string

            if let tokenNode = makeTokenNode(from: attrs) {
                flushTextBuffer()
                nodes.append(tokenNode)
            } else {
                textBuffer += markdownFragment(for: attrs, text: text)
            }
        }
        flushTextBuffer()

        return nodes
    }
}

extension MarkdownTextView {

    /// Token 行内样式：品牌色文字 + 浅色背景 + 身份属性（类型/实体 ID/展示快照）
    /// isDeleted=true 时渲染为灰色「原记录已删除」（仅引用 Token 使用，保留身份属性供点击取快照）
    static func makeTokenAttributedText(type: HoloTokenType, id: UUID, displayText: String, snapshot: String?, isDeleted: Bool = false) -> NSAttributedString {
        var attributes = baseAttributes
        if isDeleted {
            attributes[.foregroundColor] = UIColor(Color.holoTextSecondary)
            attributes[.backgroundColor] = UIColor(Color.holoTextSecondary.opacity(0.12))
        } else {
            attributes[.foregroundColor] = UIColor(Color.holoPrimary)
            attributes[.backgroundColor] = UIColor(Color.holoPrimary.opacity(0.12))
        }
        attributes[.holoTokenType] = type.rawValue
        attributes[.holoEntityId] = id.uuidString
        attributes[.holoDisplayText] = displayText
        if let snapshot {
            attributes[.holoSnapshot] = snapshot
        }

        let prefix = type == .tag ? "#" : "@"
        let visibleText = isDeleted ? "原记录已删除" : displayText
        return NSAttributedString(string: "\(prefix)\(visibleText)", attributes: attributes)
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
            return .reference(noteId: id, displayText: displayText, snapshot: attrs[.holoSnapshot] as? String ?? "")
        }
    }

    /// 全部 Token 区间（按完整属性段枚举，相邻同类型 Token 因 ID 不同不会合并）
    static func tokenRanges(in attributedText: NSAttributedString) -> [NSRange] {
        guard attributedText.length > 0 else { return [] }
        var ranges: [NSRange] = []
        attributedText.enumerateAttributes(in: NSRange(location: 0, length: attributedText.length), options: []) { attrs, range, _ in
            if attrs[.holoTokenType] != nil {
                ranges.append(range)
            }
        }
        return ranges
    }

    /// 单个属性区间的 Markdown 片段（含 ** / * / ++ / {color:} 标记还原）
    static func markdownFragment(for attrs: [NSAttributedString.Key: Any], text: String) -> String {
        let colorHex = attrs[.holoColorHex] as? String
        let isBold = (attrs[.holoBold] as? Bool) == true
        let isItalic = (attrs[.holoItalic] as? Bool) == true
        let isUnderline = (attrs[.holoUnderline] as? Bool) == true

        let prefix = markdownPrefix(isBold: isBold, isItalic: isItalic, isUnderline: isUnderline, colorHex: colorHex)
        let suffix = markdownSuffix(isBold: isBold, isItalic: isItalic, isUnderline: isUnderline, colorHex: colorHex)

        return prefix + text + suffix
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
            attributes[.foregroundColor] = UIColor(Color(hex: colorHex))
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
        } else {
            attributes[.underlineStyle] = 0
        }
        if let colorHex = attributes[.holoColorHex] as? String {
            attributes[.foregroundColor] = UIColor(Color(hex: colorHex))
        } else {
            attributes[.foregroundColor] = baseTextColor
        }
        return attributes
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
        let weight: UIFont.Weight = isBold ? .bold : .medium
        let base = UIFont.systemFont(ofSize: baseFont.pointSize, weight: weight)

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
            inline[.foregroundColor] = UIColor(Color(hex: colorHex))
        }
        return inline
    }
}

private extension NSAttributedString.Key {
    static let holoBold = NSAttributedString.Key("holoMarkdownBold")
    static let holoItalic = NSAttributedString.Key("holoMarkdownItalic")
    static let holoUnderline = NSAttributedString.Key("holoMarkdownUnderline")
    static let holoColorHex = NSAttributedString.Key("holoMarkdownColorHex")
}

// MARK: - SelfSizingTextView

/// 自动计算内容高度的 UITextView
/// 通过 sizeThatFits 在布局完成后计算正确高度，避免 intrinsicContentSize 反馈循环
private final class SelfSizingTextView: UITextView {

    /// 重写 intrinsicContentSize 返回无固定值，避免 SwiftUI ScrollView 内布局反馈循环
    /// 实际高度由 dynamicHeight binding + .frame(height:) 控制
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 利用 sizeThatFits 根据当前宽度计算内容所需高度
        let targetSize = CGSize(width: frame.width, height: .greatestFiniteMagnitude)
        let fittedSize = sizeThatFits(targetSize)
        if fittedSize.height > 0 {
            (delegate as? MarkdownTextView.Coordinator)?.onHeightChange?(fittedSize.height)
            // 内容不超出 frame 时禁用自身滚动，让外层 SwiftUI ScrollView 接管滚动手势
            let needsSelfScroll = fittedSize.height > frame.height + 1
            if isScrollEnabled != needsSelfScroll {
                isScrollEnabled = needsSelfScroll
            }
        }
    }
}
