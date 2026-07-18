//
//  ReadOnlyRichTextView.swift
//  Holo
//
//  观点模块 - 阅读态结构化内容渲染
//  复用编辑器节点管线（只读），支持 # 标签 / @ 引用 Token 点击
//

import SwiftUI
import UIKit

// MARK: - ReadOnlyRichTextView

/// 阅读态富文本：渲染 ContentNode（含 Token），点击 Token 回调
struct ReadOnlyRichTextView: UIViewRepresentable {

    let nodes: [HoloContentNode]
    /// 目标已删除的引用 ID 集合（灰色「原记录已删除」样式）
    var deletedReferenceIds: Set<UUID> = []
    /// Token 点击回调（标签 → 筛选列表；引用 → 打开目标/快照）
    var onTokenTap: (HoloContentNode) -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = MarkdownTextView.makeAttributedText(from: nodes, deletedReferenceIds: deletedReferenceIds)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        textView.addGestureRecognizer(tap)

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let rendered = MarkdownTextView.makeAttributedText(from: nodes, deletedReferenceIds: deletedReferenceIds)
        if textView.attributedText.string != rendered.string {
            textView.attributedText = rendered
        }
        context.coordinator.onTokenTap = onTokenTap
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTokenTap: onTokenTap)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTokenTap: (HoloContentNode) -> Void

        init(onTokenTap: @escaping (HoloContentNode) -> Void) {
            self.onTokenTap = onTokenTap
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? UITextView,
                  let position = textView.closestPosition(to: gesture.location(in: textView)) else { return }

            let offset = textView.offset(from: textView.beginningOfDocument, to: position)
            guard offset < textView.attributedText.length else { return }

            let attributes = textView.attributedText.attributes(at: offset, effectiveRange: nil)
            guard let node = MarkdownTextView.makeTokenNode(from: attributes) else { return }
            onTokenTap(node)
        }

        /// 命中 Token 时才接管点击（其余位置保留系统文字选择能力）
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let textView = gestureRecognizer.view as? UITextView,
                  let position = textView.closestPosition(to: touch.location(in: textView)) else { return false }

            let offset = textView.offset(from: textView.beginningOfDocument, to: position)
            guard offset < textView.attributedText.length else { return false }

            let attributes = textView.attributedText.attributes(at: offset, effectiveRange: nil)
            return attributes[.holoTokenType] != nil
        }
    }
}
