//
//  VoiceInputSheet.swift
//  Holo
//
//  HoloAI 语音输入底部卡片
//

import SwiftUI
import UIKit

struct VoiceResultConfig: Equatable {
    var title: String = "识别结果"
    var subtitle: String? = nil
    var warningSubtitle: String? = nil
    var showsOriginalToggle: Bool = false
}

struct VoiceInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: VoiceInputViewModel

    let readySubtitle: String
    let submitButtonTitle: String
    let resultConfig: VoiceResultConfig?
    let onSendTranscript: (String) -> Void

    init(
        speechProvider: SpeechRecognitionProvider = MockSpeechRecognitionProvider(),
        recordingService: VoiceRecordingServiceProviding? = nil,
        maximumDuration: TimeInterval = 60,
        readySubtitle: String = "确认后再发送给 HoloAI",
        submitButtonTitle: String = "发送",
        resultConfig: VoiceResultConfig? = nil,
        postProcessor: (any VoiceTranscriptPostProcessing)? = nil,
        transcriptFormatter: @escaping (String) -> String = { $0 },
        onSendTranscript: @escaping (String) -> Void
    ) {
        _viewModel = StateObject(
            wrappedValue: VoiceInputViewModel(
                speechProvider: speechProvider,
                recordingService: recordingService,
                maximumDuration: maximumDuration,
                postProcessor: postProcessor,
                transcriptFormatter: transcriptFormatter
            )
        )
        self.readySubtitle = readySubtitle
        self.submitButtonTitle = submitButtonTitle
        self.resultConfig = resultConfig
        self.onSendTranscript = onSendTranscript
    }

    var body: some View {
        VStack(spacing: 22) {
            Capsule()
                .fill(Color.holoTextSecondary.opacity(0.24))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            header

            if !isTranscriptReady {
                RecordingWaveformView(
                    recordingService: viewModel.recordingService,
                    isRecording: viewModel.state == .recording,
                    isFrozen: viewModel.state == .paused || viewModel.state == .interrupted,
                    isLoading: viewModel.state == .transcribing
                )
                .padding(.horizontal, 8)
            }

            content

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(Color.holoBackground.ignoresSafeArea())
        .presentationDetents([.height(preferredSheetHeight), .medium])
        .presentationDragIndicator(.hidden)
        .task {
            UIApplication.shared.isIdleTimerDisabled = true
            await viewModel.startRecording()
        }
        .onDisappear {
            viewModel.cleanupAfterDismiss()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.handleScenePhaseChange(newPhase)
        }
        .onChange(of: viewModel.state) { _, newState in
            handleStateFeedback(newState)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: headerIconName)
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(headerColor)

            Text(titleText)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.holoTextPrimary)

            Text(subtitleText)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 20)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .requestingPermission:
            ProgressView()
                .tint(.holoPrimary)
        case .recording, .paused, .interrupted:
            recordingControls
        case .transcribing:
            Button("取消") {
                VoiceInputHaptics.light()
                viewModel.cancel()
                dismiss()
            }
            .buttonStyle(VoiceSecondaryButtonStyle())
        case .summarizing:
            summarizingControls
        case .transcriptReady:
            transcriptEditor
        case .failed(let error):
            failedControls(error)
        }
    }

    private var recordingControls: some View {
        HStack(spacing: 14) {
            Button("取消") {
                VoiceInputHaptics.light()
                viewModel.cancel()
                dismiss()
            }
            .buttonStyle(VoiceSecondaryButtonStyle())

            Button(viewModel.state == .recording ? "暂停" : "继续") {
                VoiceInputHaptics.selection()
                if viewModel.state == .recording {
                    viewModel.pauseRecording()
                } else {
                    viewModel.resumeRecording()
                }
            }
            .buttonStyle(VoiceSecondaryButtonStyle())

            Button("完成") {
                VoiceInputHaptics.medium()
                Task { await viewModel.finishRecording() }
            }
            .buttonStyle(VoicePrimaryButtonStyle())
        }
    }

    private var transcriptEditor: some View {
        VStack(spacing: 16) {
            TextField("识别结果", text: $viewModel.editableTranscript, axis: .vertical)
                .lineLimit(8...16)
                .font(.holoBody)
                .padding(14)
                .frame(minHeight: 240, alignment: .topLeading)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.holoBorder, lineWidth: 1)
                )

            HStack(spacing: 14) {
                Button("重录") {
                    VoiceInputHaptics.selection()
                    viewModel.reRecord()
                }
                .buttonStyle(VoiceSecondaryButtonStyle())

                if resultConfig?.showsOriginalToggle == true && viewModel.originalTranscript != nil {
                    if viewModel.transcriptDisplayMode == .summary {
                        Button("查看原文") {
                            VoiceInputHaptics.selection()
                            viewModel.showOriginalTranscript()
                        }
                        .buttonStyle(VoiceSecondaryButtonStyle())
                    } else {
                        if viewModel.summaryTranscript != nil {
                            Button("还原总结") {
                                VoiceInputHaptics.selection()
                                viewModel.restoreSummaryTranscript()
                            }
                            .buttonStyle(VoiceSecondaryButtonStyle())
                        }
                    }
                }

                Button(submitButtonTitle) {
                    VoiceInputHaptics.success()
                    onSendTranscript(viewModel.editableTranscript)
                }
                .buttonStyle(VoicePrimaryButtonStyle())
                .disabled(viewModel.editableTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var summarizingControls: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.holoPrimary)
                .scaleEffect(1.2)

            Button("重录") {
                VoiceInputHaptics.selection()
                viewModel.cancelSummary()
                viewModel.reRecord()
            }
            .buttonStyle(VoiceSecondaryButtonStyle())
        }
    }

    private func failedControls(_ error: VoiceInputError) -> some View {
        VStack(spacing: 16) {
            Text(error.message)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            ViewThatFits(in: .horizontal) {
                failedButtonRow(error)
                failedButtonStack(error)
            }
        }
    }

    private func failedButtonRow(_ error: VoiceInputError) -> some View {
        HStack(spacing: 12) {
            Button("取消") {
                VoiceInputHaptics.light()
                viewModel.cancel()
                dismiss()
            }
            .buttonStyle(VoiceSecondaryButtonStyle())

            Button("重录") {
                VoiceInputHaptics.selection()
                viewModel.reRecord()
            }
            .buttonStyle(VoiceSecondaryButtonStyle())

            if error.allowsRetryTranscription {
                Button("重试识别") {
                    VoiceInputHaptics.medium()
                    viewModel.retryTranscription()
                }
                .buttonStyle(VoicePrimaryButtonStyle())
            }
        }
    }

    private func failedButtonStack(_ error: VoiceInputError) -> some View {
        VStack(spacing: 10) {
            Button("取消") {
                VoiceInputHaptics.light()
                viewModel.cancel()
                dismiss()
            }
            .buttonStyle(VoiceSecondaryButtonStyle())

            Button("重录") {
                VoiceInputHaptics.selection()
                viewModel.reRecord()
            }
            .buttonStyle(VoiceSecondaryButtonStyle())

            if error.allowsRetryTranscription {
                Button("重试识别") {
                    VoiceInputHaptics.medium()
                    viewModel.retryTranscription()
                }
                .buttonStyle(VoicePrimaryButtonStyle())
            }
        }
    }

    private var titleText: String {
        switch viewModel.state {
        case .idle, .requestingPermission:
            return "准备录音"
        case .recording:
            return "正在聆听"
        case .paused:
            return "已暂停"
        case .interrupted:
            return "录音被中断"
        case .transcribing:
            return "正在识别"
        case .summarizing:
            return "正在智能总结"
        case .transcriptReady:
            if viewModel.summaryNotice == "正在智能总结，可先确认原文" {
                return "识别结果"
            }
            return resultConfig?.title ?? "识别结果"
        case .failed:
            return "识别失败"
        }
    }

    private var preferredSheetHeight: CGFloat {
        switch viewModel.state {
        case .transcriptReady:
            return 560
        case .summarizing:
            return 390
        case .failed:
            return 430
        default:
            return 390
        }
    }

    private var isTranscriptReady: Bool {
        if case .transcriptReady = viewModel.state {
            return true
        }
        return false
    }

    private var subtitleText: String {
        switch viewModel.state {
        case .recording, .paused, .interrupted:
            if viewModel.state == .interrupted {
                return viewModel.didReceiveRecoverableInterruption ? "中断已结束，可以继续或完成" : "录音被中断，可以继续或完成"
            }
            let maxText = formatDuration(viewModel.maximumDuration)
            return "\(formatDuration(viewModel.recordingDuration)) / \(maxText)"
        case .transcribing:
            let maxDesc = viewModel.maximumDuration >= 60 ? "\(Int(viewModel.maximumDuration / 60)) 分钟" : "\(Int(viewModel.maximumDuration)) 秒"
            return viewModel.didAutoFinishBecauseOfLimit ? "已到 \(maxDesc)，正在整理你的语音" : "正在整理你的语音"
        case .summarizing:
            return "正在将语音整理成更适合观点记录的表达"
        case .transcriptReady:
            if let notice = viewModel.summaryNotice {
                return notice
            }
            return resultConfig?.subtitle ?? readySubtitle
        case .failed(.microphonePermissionDenied):
            return "需要使用麦克风来记录你的语音"
        case .failed:
            return ""
        case .idle, .requestingPermission:
            return "需要使用麦克风来记录你的语音"
        }
    }

    private var headerIconName: String {
        switch viewModel.state {
        case .failed:
            return "exclamationmark.circle.fill"
        case .transcriptReady:
            return "sparkles"
        case .transcribing:
            return "waveform"
        case .summarizing:
            return "waveform.badge.magnifyingglass"
        default:
            return "mic.circle.fill"
        }
    }

    private var headerColor: Color {
        if case .failed = viewModel.state {
            return .holoError
        }
        return .holoPrimary
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func handleStateFeedback(_ state: VoiceInputState) {
        switch state {
        case .recording:
            VoiceInputHaptics.light()
        case .interrupted:
            VoiceInputHaptics.warning()
        case .transcribing:
            if viewModel.didAutoFinishBecauseOfLimit {
                VoiceInputHaptics.medium()
            }
        case .summarizing:
            VoiceInputHaptics.medium()
        case .transcriptReady:
            VoiceInputHaptics.success()
        case .failed:
            VoiceInputHaptics.error()
        default:
            break
        }
    }
}

private struct VoicePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.horizontal, 8)
            .background(Color.holoPrimary.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct VoiceSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundColor(.holoTextPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.horizontal, 8)
            .background(Color.holoCardBackground.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private enum VoiceInputHaptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
