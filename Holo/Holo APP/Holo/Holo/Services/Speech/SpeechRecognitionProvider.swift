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

/// 语音输入的入口标识，随转写请求上报后端。
/// 后端据此决定是否做中文数字归一化（「一个」→「1个」）——只有 HoloAI 对话需要，
/// 想法/任务是记录原文的场景，转写结果必须保持用户口述原样。
enum SpeechRecognitionSource: String {
    case chat      // HoloAI 对话框
    case thought   // 想法编辑器
    case task      // 任务详情
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
    /// 识别额度（asr 池）耗尽：档位终态，不提供「重试识别」（重置前必再失败）。
    case quotaExhausted(String)

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
        case .quotaExhausted(let message):
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
