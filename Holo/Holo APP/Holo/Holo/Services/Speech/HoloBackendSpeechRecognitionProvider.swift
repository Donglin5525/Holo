//
//  HoloBackendSpeechRecognitionProvider.swift
//  Holo
//
//  调用 Holo 后端网关的语音识别 Provider
//

import Foundation

final class HoloBackendSpeechRecognitionProvider: SpeechRecognitionProvider {
    private let baseURL: String
    private let session: URLSession
    private let deviceIdProvider: () -> String

    init(
        baseURL: String = HoloBackendEnvironment.baseURL,
        session: URLSession = .shared,
        deviceIdProvider: @escaping () -> String = { HoloBackendDeviceIdentity.shared.deviceId }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.deviceIdProvider = deviceIdProvider
    }

    func transcribe(audioFileURL: URL, locale: String?) async throws -> SpeechRecognitionResult {
        guard let url = URL(string: "\(baseURL)/v1/asr/transcriptions") else {
            throw SpeechRecognitionError.serverMessage("语音识别服务地址无效")
        }

        let audioData = try Data(contentsOf: audioFileURL)
        guard !audioData.isEmpty else {
            throw SpeechRecognitionError.emptyTranscript
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceIdProvider(), forHTTPHeaderField: "X-Holo-Device-Id")

        let body = Self.multipartBody(
            audioData: audioData,
            fileName: audioFileURL.lastPathComponent.isEmpty ? "recording.wav" : audioFileURL.lastPathComponent,
            locale: locale,
            boundary: boundary
        )

        do {
            let (data, response) = try await session.upload(for: request, from: body)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SpeechRecognitionError.networkFailure
            }

            switch httpResponse.statusCode {
            case 200...299:
                let payload = try JSONDecoder().decode(HoloBackendTranscriptionResponse.self, from: data)
                let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw SpeechRecognitionError.emptyTranscript
                }
                return SpeechRecognitionResult(text: text, duration: payload.duration, confidence: payload.confidence)
            case 429:
                throw SpeechRecognitionError.serverMessage("今天的语音识别次数已达上限，稍后再试")
            case 413:
                throw SpeechRecognitionError.serverMessage("语音文件过大，请缩短录音后重试")
            default:
                let message = Self.decodeErrorMessage(from: data) ?? "语音识别失败，请稍后重试"
                throw SpeechRecognitionError.serverMessage(message)
            }
        } catch let error as SpeechRecognitionError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw SpeechRecognitionError.transcriptionTimedOut
        } catch {
            throw SpeechRecognitionError.networkFailure
        }
    }

    private static func multipartBody(
        audioData: Data,
        fileName: String,
        locale: String?,
        boundary: String
    ) -> Data {
        var body = Data()

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"audio\"; filename=\"\(fileName)\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.appendString("\r\n")

        if let locale, !locale.isEmpty {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"locale\"\r\n\r\n")
            body.appendString(locale)
            body.appendString("\r\n")
        }

        body.appendString("--\(boundary)--\r\n")
        return body
    }

    private static func decodeErrorMessage(from data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(HoloBackendErrorResponse.self, from: data) else {
            return nil
        }
        return payload.error.message
    }
}

private struct HoloBackendTranscriptionResponse: Decodable {
    let text: String
    let duration: TimeInterval?
    let confidence: Double?
}

private struct HoloBackendErrorResponse: Decodable {
    let error: ErrorPayload

    struct ErrorPayload: Decodable {
        let message: String
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
