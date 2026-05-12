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
    case transcriptReady(String)
    case failed(VoiceInputError)
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

    let recordingService: VoiceRecordingServiceProviding

    private let speechProvider: SpeechRecognitionProvider
    private var transcriptionTask: Task<Void, Never>?
    private var streamingSession: SpeechRecognitionStreamingSession?
    private var audioAppendTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var currentAudioFileURL: URL?
    private let minimumDuration: TimeInterval
    private let maximumDuration: TimeInterval

    init(
        speechProvider: SpeechRecognitionProvider,
        recordingService: VoiceRecordingServiceProviding? = nil,
        minimumDuration: TimeInterval = 0.8,
        maximumDuration: TimeInterval = 60
    ) {
        self.speechProvider = speechProvider
        self.recordingService = recordingService ?? VoiceRecordingService()
        self.minimumDuration = minimumDuration
        self.maximumDuration = maximumDuration

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
        state = .requestingPermission
        editableTranscript = ""
        recordingDuration = 0
        didAutoFinishBecauseOfLimit = false
        didReceiveRecoverableInterruption = false

        let granted = await recordingService.requestPermission()
        guard granted else {
            state = .failed(.microphonePermissionDenied)
            return
        }

        do {
            guard let streamingProvider = speechProvider as? StreamingSpeechRecognitionProvider else {
                state = .failed(.serverMessage("当前语音识别服务不支持实时识别"))
                return
            }

            streamingSession = try await streamingProvider.makeStreamingSession(locale: Self.currentLocale)
            try recordingService.startRecording()
            currentAudioFileURL = recordingService.currentFileURL
            state = .recording
            didReceiveRecoverableInterruption = false
            startDurationUpdates()
        } catch {
            streamingSession?.cancel()
            streamingSession = nil
            state = .failed(.recordingFailed(error.localizedDescription))
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

        finishStreamingTranscription()
    }

    func cancel() {
        transcriptionTask?.cancel()
        audioAppendTask?.cancel()
        streamingSession?.cancel()
        streamingSession = nil
        durationTask?.cancel()
        recordingService.cancelRecording()
        currentAudioFileURL = nil
        editableTranscript = ""
        recordingDuration = 0
        didAutoFinishBecauseOfLimit = false
        didReceiveRecoverableInterruption = false
        state = .idle
    }

    func reRecord() {
        transcriptionTask?.cancel()
        audioAppendTask?.cancel()
        streamingSession?.cancel()
        streamingSession = nil
        durationTask?.cancel()
        recordingService.cancelRecording()
        currentAudioFileURL = nil
        editableTranscript = ""
        recordingDuration = 0
        didAutoFinishBecauseOfLimit = false
        didReceiveRecoverableInterruption = false

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
        durationTask?.cancel()
        recordingService.cancelRecording()
        currentAudioFileURL = nil
    }

    private func handleInterruptionBegan() {
        guard state == .recording else { return }
        durationTask?.cancel()
        audioAppendTask?.cancel()
        streamingSession?.cancel()
        streamingSession = nil
        didReceiveRecoverableInterruption = false
        state = .interrupted
    }

    private func enqueueStreamingAudio(_ data: Data) {
        guard let streamingSession, state == .recording, !data.isEmpty else { return }

        let previousTask = audioAppendTask
        audioAppendTask = Task {
            await previousTask?.value
            guard !Task.isCancelled else { return }
            try? await streamingSession.appendAudio(data)
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

                self.editableTranscript = text
                self.state = .transcriptReady(text)
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

                self.editableTranscript = text
                self.state = .transcriptReady(text)
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .failed(Self.mapSpeechError(error))
            }
        }
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
