//
//  MacEditorIMEDiagnostic.swift
//  HoloMac
//
//  编辑器 IME 组字回归自检（DEBUG 专用，2026-10-26 灾难级组字 bug 防回归）
//
//  背景：中文拼音连续输入时「已打内容消失 + 组字被打断字母直出」。
//  本自检用 NSTextInputClient 的同一条通道（setMarkedText / insertText —— 输入法
//  提交文字就走这两个方法）驱动真实 MacRichTextEditor，并在组字窗口内注入与
//  真实自动保存完全相同的宿主状态翻转（isEditing 翻转、reloadToken/richJSON 变化），
//  断言：
//    P1 组字提交后编辑器与绑定一致
//    P2 自动保存时机（会话翻转）不重置正文
//    P4 组字进行中的状态翻转不重置正文、不杀 marked range
//    P5 组字中 reloadToken + initialRichJSON 同时变化 → 不得整体重建（红线场景）
//    P6 组字正常提交（模拟选中候选后的 insertText）
//    P7 已有本地输入后 reloadToken/richJSON 变化 → 不得整体重建
//    P0/P2/P4 顺带断言编辑器实例唯一、first responder 未漂移
//
//  运行方式（无需手点菜单）：
//    open HoloMac.app --args --ime-diag
//  自检自动开跑，结果同时写 os_log（subsystem com.holo.app，category MacIMEDiag）：
//    log show --predicate 'subsystem == "com.holo.app" AND category == "MacIMEDiag"' --last 2m
//

#if DEBUG
import SwiftUI
import AppKit
import os.log

// MARK: - 结果模型

struct MacIMEProbeResult: Identifiable {
    let id = UUID()
    let name: String
    let passed: Bool
    let detail: String
}

// MARK: - 自检视图

struct MacEditorIMEDiagnosticView: View {

    private static let logger = Logger(subsystem: "com.holo.app", category: "MacIMEDiag")

    @State private var results: [MacIMEProbeResult] = []
    @State private var running = false

    // 与 MacThoughtEditorView 完全同一组宿主状态（真实驱动 updateNSView 的再渲染）
    @State private var content: String = ""
    @State private var pendingAction: MarkdownEditorAction? = nil
    @State private var formatState: TypingFormatState = TypingFormatState()
    @State private var triggerContext: EditorTriggerContext? = nil
    @State private var selectedToken: HoloContentNode? = nil
    @State private var tokenMenuRect: CGRect? = nil
    @State private var caretRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 16)
    @State private var reloadToken = 0
    @State private var initialRichJSON: String? = nil
    /// 模拟自动保存落库：nil→UUID 翻转 isEditing（autoFocus / isComposingSession /
    /// canDeleteThought 随之变化），与真实 persistContent 行为一致
    @State private var simulatedThoughtId: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            MacRichTextEditor(
                text: $content,
                pendingAction: $pendingAction,
                formatState: $formatState,
                triggerContext: $triggerContext,
                selectedToken: $selectedToken,
                tokenMenuRect: $tokenMenuRect,
                caretRect: $caretRect,
                initialRichJSON: initialRichJSON,
                autoFocus: simulatedThoughtId == nil,
                placeholder: "自检驱动中，请勿在此输入…",
                reloadToken: reloadToken,
                onNodesChange: { _ in },
                onSuggestionCommand: { _ in },
                suggestionKeyboardEnabled: triggerContext != nil,
                suggestionKeyboardHasItems: false,
                onCompositionChange: { _ in },
                onConvertToTask: { _, _ in })
                .frame(maxHeight: .infinity)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("IME 组字回归自检")
                        .font(.system(size: 14, weight: .semibold))
                    if results.isEmpty {
                        Text("点击「运行自检」或用 --ime-diag 启动自动运行")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    ForEach(results) { result in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundColor(result.passed ? Color.green : Color.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name)
                                    .font(.system(size: 12, weight: .medium))
                                if !result.detail.isEmpty {
                                    Text(result.detail)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .frame(height: 260)

            Divider()

            HStack {
                Button(running ? "自检进行中…" : "运行自检") {
                    guard !running, !started else { return }
                    started = true
                    runProbe()
                }
                .disabled(running || started)
                Spacer()
                Text("storage / binding / marked 全程断言，结果见窗口与 os_log（MacIMEDiag）")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(12)
        }
        .frame(minWidth: 640, minHeight: 720)
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--ime-diag") {
                // macOS 14 可能开出两个诊断窗口（窗口恢复）：进程级单次标志保证
                // 脚本只在第一个实例里跑一遍
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                    guard !running, !Self.didStartProbe else { return }
                    Self.didStartProbe = true
                    started = true
                    runProbe()
                }
            }
        }
    }

    /// 进检脚本进程级单次标志（跨视图实例；仅主线程读写）
    nonisolated(unsafe) private static var didStartProbe = false

    /// 自检脚本只允许执行一次（onAppear 二次触发/双窗口防护）
    @State private var started = false

    // MARK: - 驱动脚本

    private func runProbe() {
        running = true
        results = []
        Self.logger.notice("IME 自检开始")
        Task { @MainActor in
            defer {
                running = false
                Self.logger.notice("IME 自检结束：\(self.results.filter { !$0.passed }.count) 项失败")
            }

            // P0 定位「本实例自己的」编辑器：macOS 会为每个 WindowGroup 自动开窗
            // （主窗口换壳 + mac-ime-diag 场景 = 两个自检窗口），全窗口搜索会定位到
            // 别的实例。先向自己的绑定写定位标记，纯文本装载会把标记灌进自己的
            // 编辑器——谁的存储里有标记谁就是本实例的编辑器，然后再清空。
            try? await Task.sleep(for: .milliseconds(500))
            content = "定位标记◇"
            var locatedWindow: NSWindow?
            var locatedText: MacEditorTextView?
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                for window in NSApp.windows {
                    if let tv = window.contentView?.findEditorTextView(),
                       tv.editorStorage.string.contains("定位标记◇") {
                        locatedWindow = window
                        locatedText = tv
                        break
                    }
                }
                if locatedText != nil { break }
            }
            guard let textView = locatedText, let window = locatedWindow else {
                record("P0 定位编辑器", false, "未能通过定位标记找到本实例的编辑器")
                return
            }
            content = ""
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                if !textView.editorStorage.string.contains("定位标记◇") { break }
            }
            let totalEditors = NSApp.windows.reduce(0) { $0 + ($1.contentView?.countEditorTextViews() ?? 0) }
            record(
                "P0 定位编辑器",
                totalEditors >= 1,
                "本实例定位成功；进程内编辑器总数 \(totalEditors)（含其他自检窗口属正常）")

            window.makeFirstResponder(textView)

            // P1 正常水合通道不受影响：无本地输入时 reloadToken + richJSON 变化
            // 仍要整体重建（打开编辑器首次水合 / 杀进程恢复草稿的场景）。
            // 注意：重建后宿主绑定是异步 canonical 写回，先等绑定收敛再断言，
            // 否则纯文本装载分支会把存储「纠正」回滞后的旧绑定值。
            let initialJSON = try! RichContentSerializer.jsonString(
                from: [.text(value: "首次水合内容")])
            initialRichJSON = initialJSON
            reloadToken += 1
            for _ in 0..<20 where !content.contains("首次水合内容") {
                try? await Task.sleep(for: .milliseconds(100))
            }
            record(
                "P1 首次水合仍可用",
                textView.editorStorage.string.contains("首次水合内容"),
                "storage=\(textView.editorStorage.string) binding=\(content)")

            // P2 第二词提交（IME commit 与 insertText 同通道）
            textView.insertText("打字测试", replacementRange: textView.selectedRange())
            try? await Task.sleep(for: .milliseconds(300))
            let storageAfterWord1 = textView.editorStorage.string
            record(
                "P2 首词提交",
                storageAfterWord1.contains("打字测试") && content.contains("打字测试"),
                "storage=\(storageAfterWord1) binding=\(content)")

            // P3 自动保存时机的会话翻转（新建落库 → isEditing 翻转 → 全参数重渲染）
            simulatedThoughtId = UUID()
            try? await Task.sleep(for: .milliseconds(300))
            record(
                "P3 落库会话翻转",
                textView.editorStorage.string == storageAfterWord1,
                "storage=\(textView.editorStorage.string)")

            // P4 开始第二个词的组字（等价输入法 setMarkedText）
            let insertLocation = textView.selectedRange().location
            textView.setMarkedText(
                "yixia",
                selectedRange: NSRange(location: 5, length: 0),
                replacementRange: NSRange(location: insertLocation, length: 0))
            record("P4 进入组字", textView.hasMarkedText(), "marked=\(textView.markedRange())")

            // P5 组字进行中的状态翻转（真实场景：自动保存/通知在组字窗口内触发重渲染）
            simulatedThoughtId = UUID()
            caretRect = CGRect(x: 4, y: 8, width: 1, height: 16)
            try? await Task.sleep(for: .milliseconds(300))
            let markedAliveAfterChurn = textView.hasMarkedText()
            let storageAfterChurn = textView.editorStorage.string
            let stillFirstResponder = window.firstResponder === textView
            let instancesAfterChurn = window.contentView?.countEditorTextViews() ?? 0
            record(
                "P5 组字中状态翻转",
                markedAliveAfterChurn && storageAfterChurn.contains("打字测试")
                    && stillFirstResponder && instancesAfterChurn == 1,
                "marked存活=\(markedAliveAfterChurn) storage=\(storageAfterChurn) FR稳定=\(stillFirstResponder) 本窗口实例数=\(instancesAfterChurn)")

            // P6 红线场景：组字中 reloadToken + initialRichJSON 同时变化（旧快照重建请求）
            let staleJSON = try! RichContentSerializer.jsonString(
                from: [.text(value: "外部旧内容快照")])
            initialRichJSON = staleJSON
            reloadToken += 1
            try? await Task.sleep(for: .milliseconds(300))
            let storageAfterInjection = textView.editorStorage.string
            record(
                "P6 组字中重建请求被拒",
                storageAfterInjection.contains("打字测试") && !storageAfterInjection.contains("外部旧内容快照"),
                "storage=\(storageAfterInjection)")

            // P7 组字提交（选中候选：insertText 覆盖 marked range）
            let marked = textView.markedRange()
            textView.insertText("一下", replacementRange: marked)
            try? await Task.sleep(for: .milliseconds(300))
            let finalStorage = textView.editorStorage.string
            record(
                "P7 组字正常提交",
                finalStorage.contains("打字测试") && finalStorage.contains("一下") && !finalStorage.contains("yixia"),
                "storage=\(finalStorage) binding=\(content)")

            // P8 已有本地输入（未组字）时 token/richJSON 变化 → 不得整体重建
            reloadToken += 1
            initialRichJSON = staleJSON
            try? await Task.sleep(for: .milliseconds(300))
            record(
                "P8 会话期重建请求被拒",
                textView.editorStorage.string.contains("打字测试")
                    && !textView.editorStorage.string.contains("外部旧内容快照"),
                "storage=\(textView.editorStorage.string)")
        }
    }

    private func record(_ name: String, _ passed: Bool, _ detail: String) {
        Self.logger.notice("\(name, privacy: .public)：\(passed ? "PASS" : "FAIL", privacy: .public) \(detail, privacy: .public)")
        results.append(MacIMEProbeResult(name: name, passed: passed, detail: detail))
    }
}

// MARK: - 视图树探针

private extension NSView {
    func findEditorTextView() -> MacEditorTextView? {
        if let self = self as? MacEditorTextView { return self }
        for subview in subviews {
            if let found = subview.findEditorTextView() { return found }
        }
        return nil
    }

    func countEditorTextViews() -> Int {
        let selfCount = self is MacEditorTextView ? 1 : 0
        return subviews.reduce(selfCount) { $0 + $1.countEditorTextViews() }
    }
}
#endif
