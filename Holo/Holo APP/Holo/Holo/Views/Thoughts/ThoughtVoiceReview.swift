import SwiftUI

extension Color {
    static let holoThoughtVoiceAction = Color("ThoughtVoiceAction")
}

/// 想法专用的口述对照页，录音和转写继续由共享语音面板负责。
struct ThoughtVoiceReview: View {
    @ObservedObject var model: VoiceInputViewModel
    let onClose: () -> Void
    let onInsert: () -> Void

    @FocusState private var isEditing: Bool
    @ScaledMetric(relativeTo: .callout) private var editorHeight: CGFloat = 144
    @ScaledMetric(relativeTo: .callout) private var lineSpacing = ThoughtLayout.bodyLineSpacing

    var body: some View {
        VStack(alignment: .leading, spacing: ThoughtLayout.cardGap) {
            header
            HStack(spacing: ThoughtLayout.detailGap) {
                versionButton("转写原文", mode: .original, action: model.showOriginalTranscript)
                versionButton("整理稿", mode: .summary, action: model.restoreSummaryTranscript)
                    .disabled(model.summaryPhase != .ready)
            }
            .padding(ThoughtLayout.detailGap)
            .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: HoloRadius.md))

            VStack(alignment: .leading, spacing: ThoughtLayout.detailGap) {
                Text(editLabel)
                    .font(ThoughtLayout.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .accessibilityHidden(true)
                TextEditor(text: $model.editableTranscript)
                    .font(ThoughtLayout.body)
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(Color.holoToolText)
                    .scrollContentBackground(.hidden)
                    .frame(height: editorHeight)
                    .focused($isEditing)
                    .accessibilityLabel(model.transcriptDisplayMode == .summary ? Text("整理稿") : Text("转写原文"))
            }
            .padding(ThoughtLayout.cardGap)
            .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .strokeBorder(Color.holoToolBorder)
                    .allowsHitTesting(false)
            }

            if model.summaryPhase == .failed {
                HStack {
                    Text("整理失败，当前文字已保留")
                        .font(ThoughtLayout.metadata)
                        .foregroundStyle(Color.holoToolTextSecondary)
                    Spacer(minLength: ThoughtLayout.itemGap)
                    Button("重试", action: model.retrySummary)
                        .buttonStyle(.plain)
                        .font(ThoughtLayout.secondary.weight(.semibold))
                        .foregroundStyle(Color.holoThoughtVoiceAction)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: ThoughtLayout.itemGap) { actions }
                VStack(spacing: ThoughtLayout.itemGap) { actions }
            }
        }
        .onChange(of: isEditing) { _, editing in
            if editing && model.transcriptDisplayMode == .original {
                model.showOriginalTranscript()
            }
        }
    }

    private var header: some View {
        HStack(spacing: ThoughtLayout.itemGap) {
            Image(systemName: "waveform")
                .foregroundStyle(Color.holoThoughtVoiceAction)
                .frame(width: 44, height: 44)
                .background(Color.holoThoughtVoiceAction.opacity(0.12), in: RoundedRectangle(cornerRadius: HoloRadius.md))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ThoughtLayout.detailGap) {
                Text("整理口述")
                    .font(ThoughtLayout.title)
                    .foregroundStyle(Color.holoToolText)
                    .accessibilityAddTraits(.isHeader)
                Text(status)
                    .font(ThoughtLayout.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(ThoughtLayout.secondary.weight(.medium))
                    .frame(width: 44, height: 44)
                    .background(Color.holoToolInset, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.holoToolTextSecondary)
            .accessibilityLabel("关闭语音输入")
        }
    }

    private var status: String {
        switch model.summaryPhase {
        case .processing: return String(localized: "正在整理，可以先编辑或插入原文")
        case .ready:
            return model.summaryQualityNotice ?? String(localized: "已整理，可以继续编辑")
        case .idle, .failed: return String(localized: "已完成转写")
        }
    }

    private func versionButton(_ title: LocalizedStringKey, mode: TranscriptDisplayMode, action: @escaping () -> Void) -> some View {
        let selected = model.transcriptDisplayMode == mode
        return Button(action: action) {
            Text(title)
                .font(ThoughtLayout.secondary.weight(selected ? .semibold : .regular))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? Color.holoToolSurface : .clear, in: RoundedRectangle(cornerRadius: HoloRadius.sm))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.holoToolText : Color.holoToolTextSecondary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var actions: some View {
        Button("重录", action: model.reRecord)
            .buttonStyle(.plain)
            .font(ThoughtLayout.secondary.weight(.semibold))
            .padding(.horizontal, ThoughtLayout.contentInset)
            .frame(minHeight: 46)
            .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: HoloRadius.md))
        Button(action: onInsert) {
            Text(insertTitle)
                .font(ThoughtLayout.body.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 46)
                .padding(.horizontal, ThoughtLayout.itemGap)
                .foregroundStyle(Color.holoToolOnAction)
                .background(Color.holoThoughtVoiceAction, in: RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(.plain)
        .disabled(model.editableTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var insertTitle: LocalizedStringKey {
        if model.isTranscriptEdited { return "插入已编辑文本" }
        return model.transcriptDisplayMode == .summary ? "插入整理稿" : "插入原文"
    }

    private var editLabel: LocalizedStringKey {
        model.isTranscriptEdited ? "已编辑" : "可编辑"
    }
}
