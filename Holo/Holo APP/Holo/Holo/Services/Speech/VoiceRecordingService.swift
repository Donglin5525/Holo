//
//  VoiceRecordingService.swift
//  Holo
//
//  语音输入录音服务
//

import AVFoundation
import Foundation

struct VoiceRecordingConfiguration {
    let fileExtension: String
    let formatID: AudioFormatID
    let sampleRate: Double
    let channels: UInt32
    let quality: AVAudioQuality

    nonisolated static let `default` = VoiceRecordingConfiguration(
        fileExtension: "wav",
        formatID: kAudioFormatLinearPCM,
        sampleRate: 16_000,
        channels: 1,
        quality: .high
    )
}

struct VoiceRecordingResult: Equatable {
    let fileURL: URL
    let duration: TimeInterval
}

@MainActor
protocol VoiceRecordingServiceProviding: AnyObject {
    var currentFileURL: URL? { get }
    var currentTime: TimeInterval { get }
    var onInterruptionBegan: (() -> Void)? { get set }
    var onInterruptionEnded: (() -> Void)? { get set }
    var onAudioPCMData: ((Data) -> Void)? { get set }

    func requestPermission() async -> Bool
    func startRecording() throws
    func pauseRecording()
    func resumeRecording()
    func stopRecording() -> VoiceRecordingResult?
    func cancelRecording()
    func deleteCurrentRecording()
    func cleanupStaleTempFiles()
    func currentPowerLevel() -> Float
}

@MainActor
final class VoiceRecordingService: NSObject, VoiceRecordingServiceProviding, AVAudioRecorderDelegate {
    private let configuration: VoiceRecordingConfiguration
    private let fileManager: FileManager
    private var audioEngine: AVAudioEngine?
    private var outputFileHandle: FileHandle?
    private var recordedPCMByteCount = 0
    private var lastAveragePower: Float = -160
    private var savedCategory: AVAudioSession.Category?
    private var savedOptions: AVAudioSession.CategoryOptions?
    private var savedMode: AVAudioSession.Mode?
    private var interruptionObserver: NSObjectProtocol?
    private var didCleanupStaleFiles = false

    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: (() -> Void)?
    var onAudioPCMData: ((Data) -> Void)?
    private(set) var currentFileURL: URL?

    var currentTime: TimeInterval {
        Double(recordedPCMByteCount) / (configuration.sampleRate * Double(configuration.channels) * 2)
    }

    init(
        configuration: VoiceRecordingConfiguration? = nil,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration ?? .default
        self.fileManager = fileManager
        super.init()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func startRecording() throws {
        if !didCleanupStaleFiles {
            cleanupStaleTempFiles()
            didCleanupStaleFiles = true
        }

        try configureAudioSession()
        observeInterruptions()

        let url = createTempFileURL()
        fileManager.createFile(atPath: url.path, contents: nil)
        outputFileHandle = try FileHandle(forWritingTo: url)
        recordedPCMByteCount = 0
        lastAveragePower = -160

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: configuration.sampleRate,
            channels: configuration.channels,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw VoiceRecordingError.failedToCreateAudioConverter
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()

        audioEngine = engine
        currentFileURL = url
    }

    func pauseRecording() {
        audioEngine?.pause()
    }

    func resumeRecording() {
        try? AVAudioSession.sharedInstance().setActive(true)
        try? audioEngine?.start()
    }

    func stopRecording() -> VoiceRecordingResult? {
        let duration = currentTime
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        try? outputFileHandle?.close()
        outputFileHandle = nil
        restoreAudioSession()

        guard let currentFileURL else { return nil }
        return VoiceRecordingResult(fileURL: currentFileURL, duration: duration)
    }

    func cancelRecording() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        try? outputFileHandle?.close()
        outputFileHandle = nil
        deleteCurrentRecording()
        restoreAudioSession()
    }

    func deleteCurrentRecording() {
        if let currentFileURL {
            try? fileManager.removeItem(at: currentFileURL)
        }
        currentFileURL = nil
    }

    func cleanupStaleTempFiles() {
        let directory = tempDirectoryURL()
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }

    func currentPowerLevel() -> Float {
        lastAveragePower
    }

    private func handleInputBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: targetCapacity
        ) else { return }

        let inputState = AudioConverterInputState()
        var conversionError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputState.didProvideBuffer {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputState.didProvideBuffer = true
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: convertedBuffer, error: &conversionError, withInputFrom: inputBlock)
        guard conversionError == nil,
              let data = Self.pcmData(from: convertedBuffer),
              !data.isEmpty else { return }

        let averagePower = Self.averagePowerLevel(fromPCMData: data)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recordedPCMByteCount += data.count
            self.lastAveragePower = averagePower
            try? self.outputFileHandle?.write(contentsOf: data)
            self.onAudioPCMData?(data)
        }
    }

    private static func pcmData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.int16ChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        let byteCount = frameLength * MemoryLayout<Int16>.size
        return Data(bytes: channelData[0], count: byteCount)
    }

    private static func averagePowerLevel(fromPCMData data: Data) -> Float {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return -160 }

        let sumSquares = data.withUnsafeBytes { rawBuffer in
            guard let samples = rawBuffer.bindMemory(to: Int16.self).baseAddress else {
                return 0.0
            }

            var total = 0.0
            for index in 0..<sampleCount {
                let normalizedSample = Double(samples[index]) / Double(Int16.max)
                total += normalizedSample * normalizedSample
            }
            return total
        }

        guard sumSquares > 0 else { return -160 }
        let rms = sqrt(sumSquares / Double(sampleCount))
        return max(-160, Float(20 * log10(rms)))
    }

    private func createTempFileURL() -> URL {
        let directory = tempDirectoryURL()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString).\(configuration.fileExtension)")
    }

    private func tempDirectoryURL() -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("holo-voice-input", isDirectory: true)
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        savedCategory = session.category
        savedOptions = session.categoryOptions
        savedMode = session.mode

        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true)
    }

    private func restoreAudioSession() {
        let session = AVAudioSession.sharedInstance()
        if let savedCategory {
            try? session.setCategory(
                savedCategory,
                mode: savedMode ?? .default,
                options: savedOptions ?? []
            )
        }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        savedCategory = nil
        savedOptions = nil
        savedMode = nil
    }

    private func observeInterruptions() {
        if interruptionObserver != nil { return }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            Task { @MainActor in
                switch type {
                case .began:
                    self.pauseRecording()
                    self.onInterruptionBegan?()
                case .ended:
                    self.onInterruptionEnded?()
                @unknown default:
                    break
                }
            }
        }
    }
}

private final class AudioConverterInputState: @unchecked Sendable {
    nonisolated(unsafe) var didProvideBuffer = false
}

private enum VoiceRecordingError: LocalizedError {
    case failedToCreateAudioConverter

    var errorDescription: String? {
        switch self {
        case .failedToCreateAudioConverter:
            return "无法初始化录音转换器"
        }
    }
}
