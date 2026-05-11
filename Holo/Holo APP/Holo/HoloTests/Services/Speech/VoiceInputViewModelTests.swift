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
        await provider.waitForTranscription()

        XCTAssertEqual(viewModel.state, .transcriptReady("今天午饭花了 32 元"))
        XCTAssertEqual(viewModel.editableTranscript, "今天午饭花了 32 元")
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
        await provider.waitForTranscription()

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
        await provider.waitForTranscription()
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
private final class FakeSpeechRecognitionProvider: SpeechRecognitionProvider {
    var result = SpeechRecognitionResult(text: "测试语音", duration: nil, confidence: nil)
    var error: Error?
    var transcribeCallCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

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
}
