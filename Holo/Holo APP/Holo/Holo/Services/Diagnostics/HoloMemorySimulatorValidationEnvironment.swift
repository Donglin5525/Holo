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
#endif
