//
//  VoiceInputViewModel.swift
//  Holo
//
//  语音输入状态机
//

import Combine
import Foundation
import SwiftUI

enum VoiceInputState: Equatable {
    case idle
    case requestingPermission
    case recording
    case paused
    case interrupted
    case transcribing
    case summarizing(String)
    case transcriptReady(String)
    case failed(VoiceInputError)
}

enum TranscriptDisplayMode: Equatable {
    case summary
    case original
}

enum VoiceInputError: Equatable {
    case microphonePermissionDenied
    case recordingTooShort
    case recordingFailed(String)
    case transcriptionTimedOut
    case emptyTranscript
    case networkFailure
    case interrupted
    case serverMessage(String)

    var message: String {
        switch self {
        case .microphonePermissionDenied:
            return "麦克风权限未开启"
        case .recordingTooShort:
            return "说得有点短，可以再试一次"
        case .recordingFailed:
            return "暂时无法录音"
        case .transcriptionTimedOut:
            return "识别超时，请稍后重试"
        case .emptyTranscript:
            return "没听清楚，可以再说一次"
        case .networkFailure:
            return "识别失败，请检查网络后重试"
        case .interrupted:
            return "录音被中断，可以继续或完成"
        case .serverMessage(let message):
            return message
        }
    }

    var allowsRetryTranscription: Bool {
        switch self {
        case .networkFailure, .transcriptionTimedOut, .serverMessage:
            return true
        case .microphonePermissionDenied, .recordingTooShort, .recordingFailed, .emptyTranscript, .interrupted:
            return false
        }
    }
}

@MainActor
final class VoiceInputViewModel: ObservableObject {
    @Published private(set) var state: VoiceInputState = .idle
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var didAutoFinishBecauseOfLimit = false
    @Published private(set) var didReceiveRecoverableInterruption = false
    @Published var editableTranscript: String = ""

    // 智能总结相关属性（可选，nil 时不启用）
    @Published private(set) var originalTranscript: String?
    @Published private(set) var summaryTranscript: String?
    @Published private(set) var transcriptDisplayMode: TranscriptDisplayMode = .summary
    @Published private(set) var summaryNotice: String?

    let postProcessor: (any VoiceTranscriptPostProcessing)?
    private var summaryTask: Task<Void, Never>?

    let recordingService: VoiceRecordingServiceProviding

    private let speechProvider: SpeechRecognitionProvider
    private let transcriptFormatter: (String) -> String
    private var transcriptionTask: Task<Void, Never>?
    private var streamingSession: SpeechRecognitionStreamingSession?
    private var audioAppendTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var currentAudioFileURL: URL?
    private let minimumDuration: TimeInterval
    let maximumDuration: TimeInterval
    private var pendingAudioBuffers: [Data] = []
    private var streamingConnectionTask: Task<Void, Never>?
    private var isSessionReady = false

    init(
        speechProvider: SpeechRecognitionProvider,
        recordingService: VoiceRecordingServiceProviding? = nil,
        minimumDuration: TimeInterval = 0.8,
        maximumDuration: TimeInterval = 60,
        postProcessor: (any VoiceTranscriptPostProcessing)? = nil,
        transcriptFormatter: @escaping (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    ) {
        self.speechProvider = speechProvider
        self.recordingService = recordingService ?? VoiceRecordingService()
        self.minimumDuration = minimumDuration
        self.maximumDuration = maximumDuration
        self.postProcessor = postProcessor
        self.transcriptFormatter = transcriptFormatter

        self.recordingService.onInterruptionBegan = { [weak self] in
            self?.handleInterruptionBegan()
        }
        self.recordingService.onInterruptionEnded = { [weak self] in
            self?.handleInterruptionEnded()
        }
        self.recordingService.onAudioPCMData = { [weak self] data in
            self?.enqueueStreamingAudio(data)
        }
    }

    deinit {
        transcriptionTask?.cancel()
        audioAppendTask?.cancel()
        durationTask?.cancel()
    }

    func startRecording() async {
        transcriptionTask?.cancel()
        audioAppendTask?.cancel()
        streamingSession?.cancel()
        streamingSession = nil
        streamingConnectionTask?.cancel()
        cancelSummary()
        pendingAudioBuffers = []
        isSessionReady = false
        state = .requestingPermission
        editableTranscript = ""
        recordingDuration = 0
        didAutoFinishBecauseOfLimit = false
        didReceiveRecoverableInterruption = false
        originalTranscript = nil
        summaryTranscript = nil
        transcriptDisplayMode = .summary
        summaryNotice = nil

        let granted = await recordingService.requestPermission()
        guard granted else {
            state = .failed(.microphonePermissionDenied)
            return
        }

        do {
            try recordingService.startRecording()
            currentAudioFileURL = recordingService.currentFileURL
            state = .recording
            didReceiveRecoverableInterruption = false
            startDurationUpdates()
            connectStreamingSession()
        } catch {
            state = .failed(.recordingFailed(error.localizedDescription))
        }
    }

    private func connectStreamingSession() {
        guard let streamingProvider = speechProvider as? StreamingSpeechRecognitionProvider else {
            return
        }

        streamingConnectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await streamingProvider.makeStreamingSession(locale: Self.currentLocale)
                guard !Task.isCancelled else {
                    session.cancel()
                    return
                }

                self.streamingSession = session

                for buffer in self.pendingAudioBuffers {
                    guard !Task.isCancelled else { return }
                    try? await session.appendAudio(buffer)
                }
                self.pendingAudioBuffers.removeAll(keepingCapacity: true)
                self.isSessionReady = true
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    func pauseRecording() {
        guard state == .recording else { return }
        recordingService.pauseRecording()
        state = .paused
    }

    func resumeRecording() {
        guard state == .paused || state == .interrupted else { return }
        recordingService.resumeRecording()
        state = .recording
        startDurationUpdates()
    }

    func finishRecording() async {
        await finishRecording(autoCompleted: false)
    }

    private func finishRecording(autoCompleted: Bool) async {
        guard state == .recording || state == .paused || state == .interrupted else { return }
        durationTask?.cancel()
        didAutoFinishBecauseOfLimit = autoCompleted
        recordingDuration = recordingService.currentTime

        if let connectionTask = streamingConnectionTask {
            await connectionTask.value
        }

        guard let result = recordingService.stopRecording() else {
            streamingSession?.cancel()
            streamingSession = nil
            state = .failed(.recordingFailed("录音文件不可用"))
            return
        }

        currentAudioFileURL = result.fileURL
        recordingDuration = result.duration

        guard result.duration >= minimumDuration else {
            streamingSession?.cancel()
            streamingSession = nil
            recordingService.deleteCurrentRecording()
            currentAudioFileURL = nil
            state = .failed(.recordingTooShort)
            return
        }

        if streamingSession != nil {
            finishStreamingTranscription()
        } else if let currentAudioFileURL {
            transcribeAudio(at: currentAudioFileURL)
        } else {
            state = .failed(.networkFailure)
        }
    }

    func cancel() {
        transcriptionTask?.cancel()
        audioAppendTask?.cancel()
        streamingSession?.cancel()
        streamingSession = nil
        streamingConnectionTask?.cancel()
        durationTask?.cancel()
        cancelSummary()
        pendingAudioBuffers = []
        isSessionReady = false
        recordingService.cancelRecording()
        currentAudioFileURL = nil
        editableTranscript = ""
        recordingDuration = 0
        didAutoFinishBecauseOfLimit = false
        didReceiveRecoverableInterruption = false
        originalTranscript = nil
        summaryTranscript = nil
        transcriptDisplayMode = .summary
        summaryNotice = nil
        state = .idle
    }

    func reRecord() {
        transcriptionTask?.cancel()
        audioAppendTask?.cancel()
        streamingSession?.cancel()
        streamingSession = nil
        streamingConnectionTask?.cancel()
        durationTask?.cancel()
        cancelSummary()
        pendingAudioBuffers = []
        isSessionReady = false
        recordingService.cancelRecording()
        currentAudioFileURL = nil
        editableTranscript = ""
        recordingDuration = 0
        didAutoFinishBecauseOfLimit = false
        didReceiveRecoverableInterruption = false
        originalTranscript = nil
        summaryTranscript = nil
        transcriptDisplayMode = .summary
        summaryNotice = nil

        Task {
            await startRecording()
        }
    }

    func retryTranscription() {
        guard let currentAudioFileURL else { return }
        transcribeAudio(at: currentAudioFileURL)
    }

    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        if newPhase == .background, state == .recording {
            pauseRecording()
        }
    }

    func cleanupAfterDismiss() {
        transcriptionTask?.cancel()
        audioAppendTask?.cancel()
        streamingSession?.cancel()
        streamingSession = nil
        streamingConnectionTask?.cancel()
        durationTask?.cancel()
        cancelSummary()
        pendingAudioBuffers = []
        isSessionReady = false
        recordingService.cancelRecording()
        currentAudioFileURL = nil
    }

    private func handleInterruptionBegan() {
        guard state == .recording else { return }
        durationTask?.cancel()
        audioAppendTask?.cancel()
        streamingSession?.cancel()
        streamingSession = nil
        streamingConnectionTask?.cancel()
        cancelSummary()
        pendingAudioBuffers = []
        isSessionReady = false
        didReceiveRecoverableInterruption = false
        state = .interrupted
    }

    private func enqueueStreamingAudio(_ data: Data) {
        guard !data.isEmpty, state == .recording else { return }

        if isSessionReady, let streamingSession {
            let previousTask = audioAppendTask
            audioAppendTask = Task {
                await previousTask?.value
                guard !Task.isCancelled else { return }
                try? await streamingSession.appendAudio(data)
            }
        } else {
            pendingAudioBuffers.append(data)
        }
    }

    private func finishStreamingTranscription() {
        guard let streamingSession else {
            state = .failed(.networkFailure)
            return
        }

        transcriptionTask?.cancel()
        state = .transcribing

        let pendingAudioTask = audioAppendTask
        transcriptionTask = Task { [weak self] in
            guard let self else { return }

            do {
                await pendingAudioTask?.value
                let result = try await streamingSession.finish()
                guard !Task.isCancelled else { return }

                self.streamingSession = nil
                self.audioAppendTask = nil

                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    self.state = .failed(.emptyTranscript)
                    return
                }

                self.handleTranscriptionResult(text)
            } catch {
                guard !Task.isCancelled else { return }
                self.streamingSession = nil
                self.audioAppendTask = nil
                self.state = .failed(Self.mapSpeechError(error))
            }
        }
    }

    private func handleInterruptionEnded() {
        guard state == .interrupted else { return }
        didReceiveRecoverableInterruption = true
    }

    private func transcribeAudio(at url: URL) {
        transcriptionTask?.cancel()
        state = .transcribing

        transcriptionTask = Task { [weak self] in
            guard let self else { return }

            do {
                let result = try await self.speechProvider.transcribe(
                    audioFileURL: url,
                    locale: Self.currentLocale
                )
                guard !Task.isCancelled else { return }

                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    self.state = .failed(.emptyTranscript)
                    return
                }

                self.handleTranscriptionResult(text)
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .failed(Self.mapSpeechError(error))
            }
        }
    }

    // MARK: - 智能总结

    /// ASR 成功后，根据是否有 postProcessor 决定走总结路径还是直出路径
    private func handleTranscriptionResult(_ text: String) {
        let formattedText = formatTranscript(text)
        if let postProcessor {
            originalTranscript = formattedText
            summaryTranscript = nil
            editableTranscript = formattedText
            transcriptDisplayMode = .original
            summaryNotice = "正在智能总结，可先确认原文"
            state = .transcriptReady(formattedText)
            startSummary(text, processor: postProcessor)
        } else {
            editableTranscript = formattedText
            state = .transcriptReady(formattedText)
        }
    }

    private func startSummary(_ asrText: String, processor: any VoiceTranscriptPostProcessing) {
        summaryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await processor.process(asrText)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 15_000_000_000)
                        throw SummaryError.timeout
                    }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }
                guard !Task.isCancelled else { return }

                let formattedResult = self.formatTranscript(result)
                let shouldApplySummary = self.transcriptDisplayMode == .original
                    && self.editableTranscript == self.originalTranscript
                self.summaryTranscript = formattedResult
                self.summaryNotice = Self.qualityNotice(summary: formattedResult, original: self.originalTranscript ?? asrText)
                if shouldApplySummary {
                    self.editableTranscript = formattedResult
                    self.transcriptDisplayMode = .summary
                    self.state = .transcriptReady(formattedResult)
                } else {
                    self.summaryNotice = self.summaryNotice ?? "智能总结已完成，可还原总结"
                    self.state = .transcriptReady(self.editableTranscript)
                }
            } catch is CancellationError {
                // Task 被 cancel，不更新状态
            } catch {
                guard !Task.isCancelled else { return }
                // 总结失败，回退 ASR 原文
                self.summaryTranscript = nil
                let fallbackText = self.originalTranscript ?? self.formatTranscript(asrText)
                self.editableTranscript = fallbackText
                self.transcriptDisplayMode = .original
                self.summaryNotice = "智能总结失败，已保留原文"
                self.state = .transcriptReady(fallbackText)
            }
        }
    }

    func cancelSummary() {
        summaryTask?.cancel()
        summaryTask = nil
    }

    func showOriginalTranscript() {
        guard let originalTranscript else { return }
        editableTranscript = originalTranscript
        transcriptDisplayMode = .original
    }

    func restoreSummaryTranscript() {
        guard let summaryTranscript else { return }
        editableTranscript = summaryTranscript
        transcriptDisplayMode = .summary
    }

    private func formatTranscript(_ text: String) -> String {
        transcriptFormatter(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 质量兜底：长度异常时生成提示文案
    private static func qualityNotice(summary: String, original: String) -> String? {
        let ratio = Double(summary.count) / Double(max(original.count, 1))
        if ratio < 0.1 {
            return "总结较原文大幅缩短，可查看原文确认"
        }
        if ratio > 1.5 {
            return "总结内容较原文更长，建议查看原文对比"
        }
        return nil
    }

    private func startDurationUpdates() {
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.recordingDuration = self.recordingService.currentTime
                if self.recordingDuration >= self.maximumDuration {
                    await self.finishRecording(autoCompleted: true)
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private static var currentLocale: String {
        Locale.current.language.languageCode?.identifier ?? "zh"
    }

    private static func mapSpeechError(_ error: Error) -> VoiceInputError {
        if let speechError = error as? SpeechRecognitionError {
            switch speechError {
            case .transcriptionTimedOut:
                return .transcriptionTimedOut
            case .emptyTranscript:
                return .emptyTranscript
            case .networkFailure:
                return .networkFailure
            case .serverMessage(let message):
                return .serverMessage(message)
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            if nsError.code == NSURLErrorTimedOut {
                return .transcriptionTimedOut
            }
            return .networkFailure
        }

        return .serverMessage(error.localizedDescription)
    }
}
