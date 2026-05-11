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
    private var recorder: AVAudioRecorder?
    private var savedCategory: AVAudioSession.Category?
    private var savedOptions: AVAudioSession.CategoryOptions?
    private var savedMode: AVAudioSession.Mode?
    private var interruptionObserver: NSObjectProtocol?
    private var didCleanupStaleFiles = false

    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: (() -> Void)?
    private(set) var currentFileURL: URL?

    var currentTime: TimeInterval {
        recorder?.currentTime ?? 0
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
        let settings: [String: Any] = [
            AVFormatIDKey: configuration.formatID,
            AVSampleRateKey: configuration.sampleRate,
            AVNumberOfChannelsKey: configuration.channels,
            AVEncoderAudioQualityKey: configuration.quality.rawValue,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        recorder.record()

        self.recorder = recorder
        currentFileURL = url
    }

    func pauseRecording() {
        recorder?.pause()
    }

    func resumeRecording() {
        try? AVAudioSession.sharedInstance().setActive(true)
        recorder?.record()
    }

    func stopRecording() -> VoiceRecordingResult? {
        let duration = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        restoreAudioSession()

        guard let currentFileURL else { return nil }
        return VoiceRecordingResult(fileURL: currentFileURL, duration: duration)
    }

    func cancelRecording() {
        recorder?.stop()
        recorder = nil
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
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }

    func currentPowerLevel() -> Float {
        recorder?.updateMeters()
        return recorder?.averagePower(forChannel: 0) ?? -160
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
