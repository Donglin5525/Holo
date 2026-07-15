#if DEBUG
//
//  HoloMemorySimulatorValidationEnvironment.swift
//  Holo
//
//  仅供 iOS Simulator 通过环境变量启动隔离记忆验收场景。
//

import Foundation

nonisolated struct HoloMemorySimulatorValidationEnvironment: Equatable, Sendable {
    static let scenarioKey = "HOLO_MEMORY_SIMULATOR_SCENARIO"
    static let resetKey = "HOLO_MEMORY_SIMULATOR_RESET"
    static let supportedScenario = "full-chain-v1"

    let scenario: String
    let shouldReset: Bool
    let storeDirectoryURL: URL
    let reportURL: URL

    static func resolve(
        environment: [String: String],
        applicationSupportURL: URL,
        documentsURL: URL
    ) -> HoloMemorySimulatorValidationEnvironment? {
        guard environment[scenarioKey] == supportedScenario else { return nil }
        let resetValue = environment[resetKey]?.lowercased() ?? ""
        let shouldReset = ["1", "true", "yes"].contains(resetValue)
        return HoloMemorySimulatorValidationEnvironment(
            scenario: supportedScenario,
            shouldReset: shouldReset,
            storeDirectoryURL: applicationSupportURL
                .appendingPathComponent("Holo/SimulatorValidation", isDirectory: true)
                .appendingPathComponent(supportedScenario, isDirectory: true),
            reportURL: documentsURL
                .appendingPathComponent("HoloMemoryValidation", isDirectory: true)
                .appendingPathComponent("\(supportedScenario).json")
        )
    }

    /// 只能重置本场景的 Store 和报告，不允许向父目录扩大删除范围。
    func prepareDirectories(fileManager: FileManager = .default) throws {
        let validationRoot = storeDirectoryURL.deletingLastPathComponent()
        guard scenario == Self.supportedScenario,
              storeDirectoryURL.lastPathComponent == scenario,
              validationRoot.lastPathComponent == "SimulatorValidation",
              reportURL.lastPathComponent == "\(scenario).json" else {
            throw HoloMemorySimulatorValidationEnvironmentError.unsafeResetPath
        }
        if shouldReset {
            if fileManager.fileExists(atPath: storeDirectoryURL.path) {
                try fileManager.removeItem(at: storeDirectoryURL)
            }
            if fileManager.fileExists(atPath: reportURL.path) {
                try fileManager.removeItem(at: reportURL)
            }
        }
        try fileManager.createDirectory(
            at: storeDirectoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    #if targetEnvironment(simulator)
    static var current: HoloMemorySimulatorValidationEnvironment? {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        let documents = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return resolve(
            environment: ProcessInfo.processInfo.environment,
            applicationSupportURL: applicationSupport,
            documentsURL: documents
        )
    }
    #else
    static var current: HoloMemorySimulatorValidationEnvironment? { nil }
    #endif
}

nonisolated enum HoloMemorySimulatorValidationEnvironmentError: Error, Equatable {
    case unsafeResetPath
}
#endif
