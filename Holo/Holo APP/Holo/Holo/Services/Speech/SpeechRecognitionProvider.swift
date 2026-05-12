//
//  SpeechRecognitionProvider.swift
//  Holo
//
//  语音识别 Provider 协议
//

import Foundation

protocol SpeechRecognitionProvider {
    func transcribe(
        audioFileURL: URL,
        locale: String?
    ) async throws -> SpeechRecognitionResult
}

protocol StreamingSpeechRecognitionProvider: SpeechRecognitionProvider {
    func makeStreamingSession(locale: String?) async throws -> SpeechRecognitionStreamingSession
}

protocol SpeechRecognitionStreamingSession: AnyObject {
    func appendAudio(_ data: Data) async throws
    func finish() async throws -> SpeechRecognitionResult
    func cancel()
}

struct SpeechRecognitionResult: Equatable {
    let text: String
    let duration: TimeInterval?
    let confidence: Double?
}

enum SpeechRecognitionError: LocalizedError, Equatable {
    case transcriptionTimedOut
    case emptyTranscript
    case networkFailure
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .transcriptionTimedOut:
            return "识别超时，请稍后重试"
        case .emptyTranscript:
            return "没听清楚，可以再说一次"
        case .networkFailure:
            return "识别失败，请检查网络后重试"
        case .serverMessage(let message):
            return message
        }
    }
}

struct MockSpeechRecognitionProvider: SpeechRecognitionProvider {
    var transcript: String = "今天午饭花了 32 元"
    var delayNanoseconds: UInt64 = 800_000_000

    func transcribe(audioFileURL: URL, locale: String?) async throws -> SpeechRecognitionResult {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return SpeechRecognitionResult(text: transcript, duration: nil, confidence: nil)
    }
}
