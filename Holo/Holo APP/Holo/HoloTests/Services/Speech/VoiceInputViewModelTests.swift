//
//  VoiceInputViewModelTests.swift
//  HoloTests
//
//  HoloAI 语音输入状态机测试
//

import XCTest
@testable import Holo

@MainActor
final class VoiceInputViewModelTests: XCTestCase {

    func testStartRecordingWithPermissionMovesToRecording() async {
        let recorder = FakeVoiceRecordingService()
        recorder.permissionGranted = true
        let viewModel = VoiceInputViewModel(
            speechProvider: FakeSpeechRecognitionProvider(),
            recordingService: recorder
        )

        await viewModel.startRecording()

        XCTAssertEqual(viewModel.state, .recording)
        XCTAssertTrue(recorder.didStartRecording)
    }

    func testStartRecordingStartsStreamingRecognition() async {
        let recorder = FakeVoiceRecordingService()
        let provider = FakeSpeechRecognitionProvider()
        let viewModel = VoiceInputViewModel(
            speechProvider: provider,
            recordingService: recorder
        )

        await viewModel.startRecording()
        await provider.waitForStreamingSession()

        XCTAssertEqual(provider.streamingSessionCallCount, 1)
    }

    func testRecordingAudioDataIsAppendedToStreamingSession() async {
        let recorder = FakeVoiceRecordingService()
        let provider = FakeSpeechRecognitionProvider()
        let viewModel = VoiceInputViewModel(
            speechProvider: provider,
            recordingService: recorder
        )

        await viewModel.startRecording()
        await provider.waitForStreamingSession()
        recorder.onAudioPCMData?(Data([0x01, 0x02, 0x03]))
        await provider.streamingSession.waitForAppend()

        XCTAssertEqual(provider.streamingSession.appendedAudio, [Data([0x01, 0x02, 0x03])])
    }

    func testStartRecordingWithDeniedPermissionFails() async {
        let recorder = FakeVoiceRecordingService()
        recorder.permissionGranted = false
        let viewModel = VoiceInputViewModel(
            speechProvider: FakeSpeechRecognitionProvider(),
            recordingService: recorder
        )

        await viewModel.startRecording()

        XCTAssertEqual(viewModel.state, .failed(.microphonePermissionDenied))
        XCTAssertFalse(recorder.didStartRecording)
    }

    func testPauseAndResumeRecordingTransitionsState() async {
        let recorder = FakeVoiceRecordingService()
        let viewModel = VoiceInputViewModel(
            speechProvider: FakeSpeechRecognitionProvider(),
            recordingService: recorder
        )

        await viewModel.startRecording()
        viewModel.pauseRecording()
        XCTAssertEqual(viewModel.state, .paused)

        viewModel.resumeRecording()
        XCTAssertEqual(viewModel.state, .recording)
    }

    func testFinishRecordingTooShortFailsWithoutTranscribing() async {
        let recorder = FakeVoiceRecordingService()
        recorder.currentTime = 0.4
        let provider = FakeSpeechRecognitionProvider()
        let viewModel = VoiceInputViewModel(
            speechProvider: provider,
            recordingService: recorder
        )

        await viewModel.startRecording()
        await viewModel.finishRecording()

        XCTAssertEqual(viewModel.state, .failed(.recordingTooShort))
        XCTAssertEqual(provider.transcribeCallCount, 0)
        XCTAssertTrue(recorder.didDeleteCurrentFile)
    }

    func testFinishRecordingTranscribesNonEmptyText() async {
        let recorder = FakeVoiceRecordingService()
        recorder.currentTime = 2.0
        let provider = FakeSpeechRecognitionProvider()
        provider.result = SpeechRecognitionResult(text: "今天午饭花了 32 元", duration: 2, confidence: 0.9)
        let viewModel = VoiceInputViewModel(
            speechProvider: provider,
            recordingService: recorder
        )

        await viewModel.startRecording()
        await viewModel.finishRecording()
        await provider.streamingSession.waitForFinish()

        XCTAssertEqual(viewModel.state, .transcriptReady("今天午饭花了 32 元"))
        XCTAssertEqual(viewModel.editableTranscript, "今天午饭花了 32 元")
        XCTAssertEqual(provider.transcribeCallCount, 0)
    }

    func testPostProcessedTranscriptShowsOriginalImmediatelyWhileSummaryRuns() async {
        let recorder = FakeVoiceRecordingService()
        recorder.currentTime = 2.0
        let provider = FakeSpeechRecognitionProvider()
        provider.result = SpeechRecognitionResult(text: "第一段原文。第二段原文。", duration: 2, confidence: nil)
        let processor = DelayedVoiceTranscriptPostProcessor(result: "整理后的总结")
        let viewModel = VoiceInputViewModel(
            speechProvider: provider,
            recordingService: recorder,
            postProcessor: processor
        )

        await viewModel.startRecording()
        await viewModel.finishRecording()
        await provider.streamingSession.waitForFinish()

        XCTAssertEqual(viewModel.state, .transcriptReady("第一段原文。第二段原文。"))
        XCTAssertEqual(viewModel.editableTranscript, "第一段原文。第二段原文。")
        XCTAssertEqual(viewModel.originalTranscript, "第一段原文。第二段原文。")
        XCTAssertNil(viewModel.summaryTranscript)
        XCTAssertEqual(viewModel.transcriptDisplayMode, .original)
        XCTAssertEqual(viewModel.summaryNotice, "正在智能总结，可先确认原文")

        processor.finish()
        await processor.waitForProcessCompletion()

        XCTAssertEqual(viewModel.state, .transcriptReady("整理后的总结"))
        XCTAssertEqual(viewModel.editableTranscript, "整理后的总结")
        XCTAssertEqual(viewModel.summaryTranscript, "整理后的总结")
        XCTAssertEqual(viewModel.transcriptDisplayMode, .summary)
    }

    func testTranscriptFormatterFormatsOriginalAndSummaryForConfirmation() async {
        let recorder = FakeVoiceRecordingService()
        recorder.currentTime = 2.0
        let provider = FakeSpeechRecognitionProvider()
        provider.result = SpeechRecognitionResult(text: "原文第一句。原文第二句。", duration: 2, confidence: nil)
        let processor = DelayedVoiceTranscriptPostProcessor(result: "总结第一句。总结第二句。")
        let viewModel = VoiceInputViewModel(
            speechProvider: provider,
            recordingService: recorder,
            postProcessor: processor,
            transcriptFormatter: { text in
                text.replacingOccurrences(of: "。", with: "。\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )

        await viewModel.startRecording()
        await viewModel.finishRecording()
        await provider.streamingSession.waitForFinish()

        XCTAssertEqual(viewModel.editableTranscript, "原文第一句。\n\n原文第二句。")
        XCTAssertEqual(viewModel.originalTranscript, "原文第一句。\n\n原文第二句。")

        processor.finish()
        await processor.waitForProcessCompletion()

        XCTAssertEqual(viewModel.editableTranscript, "总结第一句。\n\n总结第二句。")
        XCTAssertEqual(viewModel.summaryTranscript, "总结第一句。\n\n总结第二句。")
    }

    func testEmptyTranscriptFails() async {
        let recorder = FakeVoiceRecordingService()
        recorder.currentTime = 2.0
        let provider = FakeSpeechRecognitionProvider()
        provider.result = SpeechRecognitionResult(text: "   ", duration: 2, confidence: nil)
        let viewModel = VoiceInputViewModel(
            speechProvider: provider,
            recordingService: recorder
        )

        await viewModel.startRecording()
        await viewModel.finishRecording()
        await provider.streamingSession.waitForFinish()

        XCTAssertEqual(viewModel.state, .failed(.emptyTranscript))
    }

    func testRetryTranscriptionKeepsExistingAudioFile() async {
        let recorder = FakeVoiceRecordingService()
        recorder.currentTime = 2.0
        let provider = FakeSpeechRecognitionProvider()
        provider.error = SpeechRecognitionError.networkFailure
        let viewModel = VoiceInputViewModel(
            speechProvider: provider,
            recordingService: recorder
        )

        await viewModel.startRecording()
        await viewModel.finishRecording()
        await provider.streamingSession.waitForFinish()
        XCTAssertEqual(viewModel.state, .failed(.networkFailure))

        provider.error = nil
        provider.result = SpeechRecognitionResult(text: "明天提醒我交房租", duration: 2, confidence: nil)
        viewModel.retryTranscription()
        await provider.waitForTranscription()

        XCTAssertEqual(viewModel.state, .transcriptReady("明天提醒我交房租"))
        XCTAssertFalse(recorder.didDeleteCurrentFile)
    }

    func testAudioInterruptionPausesAndCanResumeAfterEnded() async {
        let recorder = FakeVoiceRecordingService()
        let viewModel = VoiceInputViewModel(
            speechProvider: FakeSpeechRecognitionProvider(),
            recordingService: recorder
        )

        await viewModel.startRecording()
        recorder.onInterruptionBegan?()

        XCTAssertEqual(viewModel.state, .interrupted)
        XCTAssertFalse(viewModel.didReceiveRecoverableInterruption)

        recorder.onInterruptionEnded?()
        XCTAssertTrue(viewModel.didReceiveRecoverableInterruption)

        viewModel.resumeRecording()
        XCTAssertEqual(viewModel.state, .recording)
        XCTAssertTrue(recorder.didResumeRecording)
    }

    func testRecordingLimitAutoFinishesAndMarksTranscribingReason() async {
        let recorder = FakeVoiceRecordingService()
        recorder.currentTime = 1.0
        let provider = FakeSpeechRecognitionProvider()
        provider.result = SpeechRecognitionResult(text: "自动完成测试", duration: 1, confidence: nil)
        let viewModel = VoiceInputViewModel(
            speechProvider: provider,
            recordingService: recorder,
            maximumDuration: 0.5
        )

        await viewModel.startRecording()
        await provider.waitForTranscription()

        XCTAssertTrue(viewModel.didAutoFinishBecauseOfLimit)
        XCTAssertEqual(viewModel.state, .transcriptReady("自动完成测试"))
    }
}

@MainActor
private final class FakeVoiceRecordingService: VoiceRecordingServiceProviding {
    var permissionGranted = true
    var currentFileURL: URL?
    var currentTime: TimeInterval = 1.2
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: (() -> Void)?
    var onAudioPCMData: ((Data) -> Void)?
    var didStartRecording = false
    var didDeleteCurrentFile = false
    var didResumeRecording = false

    func requestPermission() async -> Bool {
        permissionGranted
    }

    func startRecording() throws {
        currentFileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voice-test.m4a")
        didStartRecording = true
        didDeleteCurrentFile = false
    }

    func pauseRecording() {}
    func resumeRecording() {
        didResumeRecording = true
    }

    func stopRecording() -> VoiceRecordingResult? {
        guard let currentFileURL else { return nil }
        return VoiceRecordingResult(fileURL: currentFileURL, duration: currentTime)
    }

    func cancelRecording() {
        didDeleteCurrentFile = true
        currentFileURL = nil
    }

    func deleteCurrentRecording() {
        didDeleteCurrentFile = true
    }

    func cleanupStaleTempFiles() {}

    func currentPowerLevel() -> Float {
        -20
    }
}

@MainActor
private final class FakeSpeechRecognitionProvider: StreamingSpeechRecognitionProvider {
    var result = SpeechRecognitionResult(text: "测试语音", duration: nil, confidence: nil)
    var error: Error?
    var transcribeCallCount = 0
    var streamingSessionCallCount = 0
    let streamingSession = FakeSpeechRecognitionStreamingSession()
    private var continuation: CheckedContinuation<Void, Never>?
    private var streamingContinuation: CheckedContinuation<Void, Never>?

    func makeStreamingSession(locale: String?) async throws -> SpeechRecognitionStreamingSession {
        streamingSessionCallCount += 1
        streamingSession.resultProvider = { [weak self] in
            guard let self else {
                return SpeechRecognitionResult(text: "", duration: nil, confidence: nil)
            }
            if let error = self.error {
                throw error
            }
            return self.result
        }
        streamingContinuation?.resume()
        streamingContinuation = nil
        return streamingSession
    }

    func transcribe(audioFileURL: URL, locale: String?) async throws -> SpeechRecognitionResult {
        transcribeCallCount += 1
        defer {
            continuation?.resume()
            continuation = nil
        }
        if let error {
            throw error
        }
        return result
    }

    func waitForTranscription() async {
        guard transcribeCallCount == 0 || continuation != nil else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitForStreamingSession() async {
        guard streamingSessionCallCount == 0 || streamingContinuation != nil else { return }
        await withCheckedContinuation { continuation in
            self.streamingContinuation = continuation
        }
    }
}

private final class FakeSpeechRecognitionStreamingSession: SpeechRecognitionStreamingSession {
    var appendedAudio: [Data] = []
    var resultProvider: (() throws -> SpeechRecognitionResult)?
    var didFinish = false
    private var appendContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func appendAudio(_ data: Data) async throws {
        appendedAudio.append(data)
        appendContinuation?.resume()
        appendContinuation = nil
    }

    func finish() async throws -> SpeechRecognitionResult {
        didFinish = true
        defer {
            finishContinuation?.resume()
            finishContinuation = nil
        }
        return try resultProvider?() ?? SpeechRecognitionResult(text: "", duration: nil, confidence: nil)
    }

    func cancel() {}

    func waitForAppend() async {
        guard appendedAudio.isEmpty || appendContinuation != nil else { return }
        await withCheckedContinuation { continuation in
            self.appendContinuation = continuation
        }
    }

    func waitForFinish() async {
        guard !didFinish || finishContinuation != nil else { return }
        await withCheckedContinuation { continuation in
            self.finishContinuation = continuation
        }
    }
}

@MainActor
private final class DelayedVoiceTranscriptPostProcessor: VoiceTranscriptPostProcessing {
    let result: String
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var completionContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var shouldFinish = false
    private var didComplete = false

    init(result: String) {
        self.result = result
    }

    func process(_ text: String) async throws -> String {
        didStart = true
        startContinuation?.resume()
        startContinuation = nil

        if !shouldFinish {
            await withCheckedContinuation { continuation in
                finishContinuation = continuation
            }
        }

        didComplete = true
        completionContinuation?.resume()
        completionContinuation = nil
        return result
    }

    func finish() {
        shouldFinish = true
        finishContinuation?.resume()
        finishContinuation = nil
    }

    func waitForProcessStart() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func waitForProcessCompletion() async {
        guard !didComplete else { return }
        await withCheckedContinuation { continuation in
            completionContinuation = continuation
        }
    }
}
