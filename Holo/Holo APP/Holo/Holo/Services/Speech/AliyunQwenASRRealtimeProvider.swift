//
//  AliyunQwenASRRealtimeProvider.swift
//  Holo
//
//  阿里云百炼 Qwen-ASR-Realtime WebSocket Provider
//

import Foundation

final class AliyunQwenASRRealtimeProvider: SpeechRecognitionProvider {
    private let config: VoiceRecognitionConfig
    private let session: URLSession
    private let timeoutNanoseconds: UInt64

    init(
        config: VoiceRecognitionConfig,
        session: URLSession = .shared,
        timeoutSeconds: UInt64 = 30
    ) {
        self.config = config
        self.session = session
        self.timeoutNanoseconds = timeoutSeconds * 1_000_000_000
    }

    func transcribe(audioFileURL: URL, locale: String?) async throws -> SpeechRecognitionResult {
        guard config.isConfigured else {
            throw SpeechRecognitionError.serverMessage("请先配置语音识别 API Key")
        }

        guard let url = config.endpointURL else {
            throw SpeechRecognitionError.serverMessage("语音识别服务地址无效")
        }

        let audioData = try Self.extractPCMData(from: audioFileURL)
        guard !audioData.isEmpty else {
            throw SpeechRecognitionError.emptyTranscript
        }

        return try await withThrowingTaskGroup(of: SpeechRecognitionResult.self) { group in
            group.addTask {
                try await self.performTranscription(audioData: audioData, url: url, locale: locale)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: self.timeoutNanoseconds)
                throw SpeechRecognitionError.transcriptionTimedOut
            }

            guard let result = try await group.next() else {
                throw SpeechRecognitionError.networkFailure
            }
            group.cancelAll()
            return result
        }
    }

    func testConnection() async throws {
        guard config.isConfigured else {
            throw SpeechRecognitionError.serverMessage("请先填写 API Key")
        }
        guard let url = config.endpointURL else {
            throw SpeechRecognitionError.serverMessage("语音识别服务地址无效")
        }

        let task = makeWebSocketTask(url: url)
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
        }

        try await waitForEvent(["session.created"], task: task)
        try await sendJSON(sessionUpdatePayload(locale: nil), task: task)
        try await waitForEvent(["session.updated"], task: task)
        try await sendJSON(eventPayload(type: "session.finish"), task: task)
    }

    private func performTranscription(audioData: Data, url: URL, locale: String?) async throws -> SpeechRecognitionResult {
        let task = makeWebSocketTask(url: url)
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
        }

        try await waitForEvent(["session.created"], task: task)
        try await sendJSON(sessionUpdatePayload(locale: locale), task: task)
        try await waitForEvent(["session.updated"], task: task)

        try await sendAudioChunks(audioData, task: task)
        try await sendJSON(eventPayload(type: "input_audio_buffer.commit"), task: task)
        try await sendJSON(eventPayload(type: "session.finish"), task: task)

        while true {
            let event = try await receiveEvent(task)
            switch event.type {
            case "conversation.item.input_audio_transcription.completed":
                let transcript = event.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !transcript.isEmpty else {
                    throw SpeechRecognitionError.emptyTranscript
                }
                return SpeechRecognitionResult(text: transcript, duration: nil, confidence: nil)
            case "conversation.item.input_audio_transcription.failed":
                throw SpeechRecognitionError.serverMessage(event.errorMessage ?? "语音识别失败")
            case "session.finished":
                throw SpeechRecognitionError.emptyTranscript
            default:
                continue
            }
        }
    }

    private func makeWebSocketTask(url: URL) -> URLSessionWebSocketTask {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        return session.webSocketTask(with: request)
    }

    private func sendAudioChunks(_ data: Data, task: URLSessionWebSocketTask) async throws {
        let maxChunkSize = 256 * 1024
        var offset = 0

        while offset < data.count {
            let length = min(maxChunkSize, data.count - offset)
            let chunk = data.subdata(in: offset..<(offset + length))
            try await sendJSON([
                "event_id": Self.eventID(),
                "type": "input_audio_buffer.append",
                "audio": chunk.base64EncodedString()
            ], task: task)
            offset += length
        }
    }

    private func sessionUpdatePayload(locale: String?) -> [String: Any] {
        [
            "event_id": Self.eventID(),
            "type": "session.update",
            "session": [
                "input_audio_format": "pcm",
                "sample_rate": config.sampleRate,
                "input_audio_transcription": [
                    "language": normalizedLanguage(locale)
                ],
                "turn_detection": NSNull()
            ] as [String: Any]
        ]
    }

    private func eventPayload(type: String) -> [String: Any] {
        [
            "event_id": Self.eventID(),
            "type": type
        ]
    }

    private func normalizedLanguage(_ locale: String?) -> String {
        let rawValue = locale?.isEmpty == false ? (locale ?? config.language) : config.language
        let value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.hasPrefix("zh") { return "zh" }
        if value.hasPrefix("en") { return "en" }
        return value.isEmpty ? "zh" : value
    }

    private func sendJSON(_ payload: [String: Any], task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SpeechRecognitionError.serverMessage("语音识别请求编码失败")
        }
        try await task.send(.string(string))
    }

    private func waitForEvent(_ types: Set<String>, task: URLSessionWebSocketTask) async throws {
        while true {
            let event = try await receiveEvent(task)
            if types.contains(event.type) { return }
        }
    }

    private func receiveEvent(_ task: URLSessionWebSocketTask) async throws -> ASREvent {
        let message = try await task.receive()
        let data: Data

        switch message {
        case .data(let messageData):
            data = messageData
        case .string(let string):
            data = Data(string.utf8)
        @unknown default:
            throw SpeechRecognitionError.networkFailure
        }

        let event = try JSONDecoder().decode(ASREvent.self, from: data)
        if event.type == "error" {
            throw SpeechRecognitionError.serverMessage(event.errorMessage ?? "语音识别服务返回错误")
        }
        return event
    }

    private static func extractPCMData(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { return data }
        guard String(data: data.prefix(4), encoding: .ascii) == "RIFF" else {
            return data
        }

        var index = 12
        while index + 8 <= data.count {
            let chunkIDData = data.subdata(in: index..<(index + 4))
            let chunkSizeData = data.subdata(in: (index + 4)..<(index + 8))
            let chunkID = String(data: chunkIDData, encoding: .ascii)
            let chunkSize = UInt32(chunkSizeData[chunkSizeData.startIndex]) |
                (UInt32(chunkSizeData[chunkSizeData.startIndex + 1]) << 8) |
                (UInt32(chunkSizeData[chunkSizeData.startIndex + 2]) << 16) |
                (UInt32(chunkSizeData[chunkSizeData.startIndex + 3]) << 24)
            let dataStart = index + 8
            let dataEnd = dataStart + Int(chunkSize)

            if chunkID == "data", dataEnd <= data.count {
                return data.subdata(in: dataStart..<dataEnd)
            }

            index = dataEnd + (Int(chunkSize) % 2)
        }

        return data.dropFirst(44)
    }

    private static func eventID() -> String {
        "event_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}

private struct ASREvent: Decodable {
    let type: String
    let transcript: String?
    let error: ASRError?

    var errorMessage: String? {
        error?.message
    }
}

private struct ASRError: Decodable {
    let message: String?
}

enum SpeechRecognitionProviderFactory {
    @MainActor
    static func makeConfiguredProvider() -> SpeechRecognitionProvider {
        guard KeychainService.hasCachedVoiceRecognitionConfig,
              let config = try? KeychainService.loadVoiceRecognitionConfigOffMain(),
              config.isConfigured else {
            return UnconfiguredSpeechRecognitionProvider()
        }

        return AliyunQwenASRRealtimeProvider(config: config)
    }
}

private struct UnconfiguredSpeechRecognitionProvider: SpeechRecognitionProvider {
    func transcribe(audioFileURL: URL, locale: String?) async throws -> SpeechRecognitionResult {
        throw SpeechRecognitionError.serverMessage("请先在设置中配置语音识别 API Key")
    }
}
