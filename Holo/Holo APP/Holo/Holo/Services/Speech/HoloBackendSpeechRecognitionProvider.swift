//
//  HoloBackendSpeechRecognitionProvider.swift
//  Holo
//
//  调用 Holo 后端网关的语音识别 Provider
//

import AVFoundation
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
        guard HoloAIFeatureFlags.aiDataProcessingConsentGranted else {
            throw SpeechRecognitionError.serverMessage(HoloAIDataProcessingConsent.requiredMessage)
        }

        guard let url = URL(string: "\(baseURL)/v1/asr/transcriptions") else {
            throw SpeechRecognitionError.serverMessage("语音识别服务地址无效")
        }

        let audioData = try Data(contentsOf: audioFileURL)
        guard !audioData.isEmpty else {
            throw SpeechRecognitionError.emptyTranscript
        }

        let duration = try await Self.audioDuration(for: audioFileURL)
        let maxSeconds = await MainActor.run {
            HoloEntitlementState.shared.quotas["asr"]?.maxSeconds
                ?? (HoloEntitlementState.shared.isPlusActive ? 300 : 60)
        }
        if duration > maxSeconds {
            let isPlusActive = await MainActor.run { HoloEntitlementState.shared.isPlusActive }
            if !isPlusActive {
                await MainActor.run {
                    HoloPlusActionCoordinator.shared.requirePlus(context: .asrDuration)
                }
            }
            throw SpeechRecognitionError.serverMessage(
                isPlusActive
                    ? "单次语音最长可识别 \(Int(maxSeconds)) 秒，请缩短录音后重试"
                    : "免费版单次最多识别 \(Int(maxSeconds)) 秒，升级 Holo Plus 可识别更长语音"
            )
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
            durationSeconds: duration,
            usageActionId: UUID().uuidString,
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
                await HoloSubscriptionService.shared.refreshStatus()
                return SpeechRecognitionResult(text: text, duration: payload.duration, confidence: payload.confidence)
            case 429:
                if let quotaError = HoloQuotaError.decode(from: data) {
                    if quotaError.upgradeAvailable {
                        await MainActor.run {
                            HoloPlusActionCoordinator.shared.requirePlus(
                                context: quotaError.isDurationError ? .asrDuration : .asrQuota
                            )
                        }
                    }
                    throw SpeechRecognitionError.serverMessage(quotaError.userMessage)
                }
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
        durationSeconds: TimeInterval,
        usageActionId: String,
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

        appendField("durationSeconds", value: String(durationSeconds), to: &body, boundary: boundary)
        appendField("usageActionId", value: usageActionId, to: &body, boundary: boundary)

        body.appendString("--\(boundary)--\r\n")
        return body
    }

    private static func appendField(
        _ name: String,
        value: String,
        to body: inout Data,
        boundary: String
    ) {
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.appendString(value)
        body.appendString("\r\n")
    }

    private static func audioDuration(for url: URL) async throws -> TimeInterval {
        // 优先用 AVURLAsset 读取标准 WAV 文件的时长。
        if let seconds = try? await AVURLAsset(url: url).load(.duration).seconds,
           seconds.isFinite, seconds > 0 {
            return seconds
        }
        // 兜底：当文件没有标准 WAV 头（裸 PCM）或解析失败时，
        // 按已知格式（16kHz / 单声道 / Int16 = 32000 bytes/s）反推时长。
        // 减去 44 字节 WAV 头（若有），其余按 PCM 字节计算。
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int, fileSize > 0 else {
            return 0
        }
        let pcmBytes = max(0, fileSize - 44)
        return TimeInterval(pcmBytes) / 32_000
    }

    private static func decodeErrorMessage(from data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(HoloBackendErrorResponse.self, from: data) else {
            return nil
        }
        return payload.error.message
    }
}

private extension HoloQuotaError {
    var isDurationError: Bool {
        if case .asrDurationExceeded = self { return true }
        return false
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
