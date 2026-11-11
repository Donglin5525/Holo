import SwiftUI

struct ThoughtVoiceInsertionNotice: View {
    let status: ThoughtVoiceInsertionStatus
    let onSwap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: ThoughtLayout.itemGap) {
            Image(systemName: "checkmark")
                .foregroundStyle(Color.holoThoughtVoiceAction)
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onSwap) {
                Text(actionTitle)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.holoThoughtVoiceAction)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起插入提示")
        }
        .font(ThoughtLayout.metadata)
        .padding(.leading, ThoughtLayout.itemGap)
        .background(Color.holoThoughtVoiceAction.opacity(0.10), in: RoundedRectangle(cornerRadius: HoloRadius.md))
        .padding(.horizontal, ThoughtLayout.itemGap)
        .padding(.bottom, ThoughtLayout.itemGap)
    }

    private var message: LocalizedStringKey {
        status == .restored ? "已换回转写原文" : "已插入整理稿"
    }

    private var actionTitle: LocalizedStringKey {
        status == .restored ? "撤销换回" : "换回原文"
    }
}
