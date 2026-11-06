//
//  MacQuadrantCaptureBar.swift
//  HoloMac
//
//  看板快速收集条：输入标题回车落待确认（importance unknown），可连发；
//  Tab 建档并选中新卡滑出详情；Esc 清空失焦。样式与中栏搜索框同构
//  （holoToolInset 填充 + HoloRadius.md 圆角），键盘优先、全程不弹窗。
//

import SwiftUI

struct MacQuadrantCaptureBar: View {

    /// 聚焦脉冲（⌘N / ⌘F 触发，变化即聚焦）
    var focusTrigger: Int
    /// 提交回调：(标题, 是否选中新卡并滑出详情)
    let onSubmit: (String, _ openDetail: Bool) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle")
                .font(.system(size: 12))
                .foregroundColor(.holoToolTextSecondary)

            TextField(String(localized: "记一件事，回车收进待确认"), text: $text)
                .textFieldStyle(.plain)
                .holoText(.supporting)
                .foregroundColor(.holoToolText)
                .focused($focused)
                .onSubmit { submit(openDetail: false) }
                .onKeyPress(.tab) {
                    submit(openDetail: true)
                    return .handled
                }
                .onKeyPress(.escape) {
                    text = ""
                    focused = false
                    return .handled
                }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "清空输入"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 260, idealWidth: 340, maxWidth: 420)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(Color.holoToolInset))
        .onChange(of: focusTrigger) { _, _ in
            focused = true
        }
        .accessibilityIdentifier("mac.task.board.captureField")
    }

    /// 空标题不建档；提交后清空续输、焦点保留
    private func submit(openDetail: Bool) {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        text = ""
        onSubmit(title, openDetail)
    }
}
