//
//  HealthKitDiagnosticsService.swift
//  Holo
//
//  HealthKit 数据来源诊断
//

import Foundation
import HealthKit

struct HealthKitDiagnosticSourceSummary: Equatable {
    let sourceName: String
    let bundleIdentifier: String
    let deviceName: String?
    let manufacturer: String?
    let model: String?
    let sampleCount: Int
    let totalValue: Double?
}

struct HealthKitDiagnosticMetric: Equatable {
    let title: String
    let identifier: String
    let windowDescription: String
    let unit: String?
    let sampleCount: Int
    let totalValue: Double?
    let sourceSummaries: [HealthKitDiagnosticSourceSummary]
    let errorMessage: String?
}

struct HealthKitDiagnosticReport: Equatable {
    let generatedAt: Date
    let isHealthDataAvailable: Bool
    let metrics: [HealthKitDiagnosticMetric]

    func copyText() -> String {
        HealthKitDiagnosticReportFormatter().format(self)
    }
}

struct HealthKitDiagnosticReportFormatter {
    func format(_ report: HealthKitDiagnosticReport) -> String {
        var lines: [String] = []
        lines.append("Holo HealthKit 诊断报告")
        lines.append("生成时间：\(formatDateTime(report.generatedAt))")
        lines.append("HealthKit 可用：\(report.isHealthDataAvailable ? "是" : "否")")
        lines.append("")

        for metric in report.metrics {
            lines.append("【\(metric.title)】")
            lines.append("类型：\(metric.identifier)")
            lines.append("窗口：\(metric.windowDescription)")

            if let errorMessage = metric.errorMessage {
                lines.append("错误：\(errorMessage)")
            } else {
                lines.append("样本数：\(metric.sampleCount)")
                if let totalValue = metric.totalValue, let unit = metric.unit {
                    lines.append("总值：\(formatNumber(totalValue)) \(unit)")
                }

                if metric.sourceSummaries.isEmpty {
                    lines.append("来源：无")
                } else {
                    lines.append("来源：")
                    for source in metric.sourceSummaries {
                        lines.append("- \(source.sourceName) (\(source.bundleIdentifier))")
                        if let deviceText = deviceText(for: source) {
                            lines.append("  设备：\(deviceText)")
                        }
                        lines.append("  样本数：\(source.sampleCount)")
                        if let totalValue = source.totalValue, let unit = metric.unit {
                            lines.append("  总值：\(formatNumber(totalValue)) \(unit)")
                        }
                    }
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value))"
        }
        return String(format: "%.2f", value)
    }

    private func deviceText(for source: HealthKitDiagnosticSourceSummary) -> String? {
        let parts = [
            source.manufacturer,
            source.model,
            source.deviceName
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " / ")
    }
}

final class HealthKitDiagnosticsService {
    private let healthStore = HKHealthStore()

    func generateReport() async -> HealthKitDiagnosticReport {
        guard HKHealthStore.isHealthDataAvailable() else {
            return HealthKitDiagnosticReport(
                generatedAt: Date(),
                isHealthDataAvailable: false,
                metrics: []
            )
        }

        await requestDiagnosticAuthorization()

        let now = Date()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let sleepStart = calendar.date(byAdding: .hour, value: -36, to: now) ?? startOfToday

        var metrics: [HealthKitDiagnosticMetric] = []
        metrics.append(await quantityMetric(
            title: "步数",
            identifier: HKQuantityTypeIdentifier.stepCount.rawValue,
            quantityIdentifier: .stepCount,
            unit: .count(),
            unitText: "步",
            start: startOfToday,
            end: endOfToday,
            windowDescription: "今天"
        ))
        metrics.append(await sleepMetric(
            start: sleepStart,
            end: now,
            windowDescription: "过去 36 小时"
        ))
        metrics.append(await categoryMetric(
            title: "Apple Watch 站立小时",
            identifier: HKCategoryTypeIdentifier.appleStandHour.rawValue,
            categoryIdentifier: .appleStandHour,
            includedValues: [HKCategoryValueAppleStandHour.stood.rawValue],
            unitText: "小时",
            start: startOfToday,
            end: endOfToday,
            windowDescription: "今天"
        ))
        metrics.append(await quantityMetric(
            title: "Apple 运动分钟",
            identifier: HKQuantityTypeIdentifier.appleExerciseTime.rawValue,
            quantityIdentifier: .appleExerciseTime,
            unit: .minute(),
            unitText: "分钟",
            start: startOfToday,
            end: endOfToday,
            windowDescription: "今天"
        ))
        metrics.append(await quantityMetric(
            title: "活动能量",
            identifier: HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
            quantityIdentifier: .activeEnergyBurned,
            unit: .kilocalorie(),
            unitText: "千卡",
            start: startOfToday,
            end: endOfToday,
            windowDescription: "今天"
        ))
        metrics.append(await quantityMetric(
            title: "步行跑步距离",
            identifier: HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
            quantityIdentifier: .distanceWalkingRunning,
            unit: .meter(),
            unitText: "米",
            start: startOfToday,
            end: endOfToday,
            windowDescription: "今天"
        ))
        metrics.append(await workoutMetric(
            start: startOfToday,
            end: endOfToday,
            windowDescription: "今天"
        ))

        return HealthKitDiagnosticReport(
            generatedAt: now,
            isHealthDataAvailable: true,
            metrics: metrics
        )
    }

    private func requestDiagnosticAuthorization() async {
        let readTypes = Set(diagnosticReadTypes)
        await withCheckedContinuation { continuation in
            healthStore.requestAuthorization(toShare: nil, read: readTypes) { _, _ in
                continuation.resume()
            }
        }
    }

    private var diagnosticReadTypes: [HKObjectType] {
        [
            HKObjectType.quantityType(forIdentifier: .stepCount),
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
            HKObjectType.categoryType(forIdentifier: .appleStandHour),
            HKObjectType.quantityType(forIdentifier: .appleExerciseTime),
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
            HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning),
            HKObjectType.workoutType()
        ].compactMap { $0 }
    }

    private func quantityMetric(
        title: String,
        identifier: String,
        quantityIdentifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        unitText: String,
        start: Date,
        end: Date,
        windowDescription: String
    ) async -> HealthKitDiagnosticMetric {
        guard let type = HKObjectType.quantityType(forIdentifier: quantityIdentifier) else {
            return unavailableMetric(title: title, identifier: identifier, windowDescription: windowDescription, unitText: unitText)
        }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(returning: self.errorMetric(
                        title: title,
                        identifier: identifier,
                        windowDescription: windowDescription,
                        unitText: unitText,
                        error: error
                    ))
                    return
                }

                let quantitySamples = (samples as? [HKQuantitySample]) ?? []
                let total = quantitySamples.reduce(0) { partial, sample in
                    partial + sample.quantity.doubleValue(for: unit)
                }
                let sources = self.summarizeQuantitySources(quantitySamples, unit: unit)
                continuation.resume(returning: HealthKitDiagnosticMetric(
                    title: title,
                    identifier: identifier,
                    windowDescription: windowDescription,
                    unit: unitText,
                    sampleCount: quantitySamples.count,
                    totalValue: total,
                    sourceSummaries: sources,
                    errorMessage: nil
                ))
            }
            self.healthStore.execute(query)
        }
    }

    private func sleepMetric(
        start: Date,
        end: Date,
        windowDescription: String
    ) async -> HealthKitDiagnosticMetric {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return unavailableMetric(
                title: "睡眠分析",
                identifier: HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
                windowDescription: windowDescription,
                unitText: "小时"
            )
        }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue
        ]

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(returning: self.errorMetric(
                        title: "睡眠分析",
                        identifier: HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
                        windowDescription: windowDescription,
                        unitText: "小时",
                        error: error
                    ))
                    return
                }

                let sleepSamples = ((samples as? [HKCategorySample]) ?? []).filter {
                    sleepValues.contains($0.value)
                }
                let total = sleepSamples.reduce(0) { partial, sample in
                    partial + sample.endDate.timeIntervalSince(sample.startDate) / 3600
                }
                let sources = self.summarizeCategorySources(sleepSamples, unitScale: 3600)
                continuation.resume(returning: HealthKitDiagnosticMetric(
                    title: "睡眠分析",
                    identifier: HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
                    windowDescription: windowDescription,
                    unit: "小时",
                    sampleCount: sleepSamples.count,
                    totalValue: total,
                    sourceSummaries: sources,
                    errorMessage: nil
                ))
            }
            self.healthStore.execute(query)
        }
    }

    private func categoryMetric(
        title: String,
        identifier: String,
        categoryIdentifier: HKCategoryTypeIdentifier,
        includedValues: Set<Int>,
        unitText: String,
        start: Date,
        end: Date,
        windowDescription: String
    ) async -> HealthKitDiagnosticMetric {
        guard let type = HKObjectType.categoryType(forIdentifier: categoryIdentifier) else {
            return unavailableMetric(title: title, identifier: identifier, windowDescription: windowDescription, unitText: unitText)
        }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(returning: self.errorMetric(
                        title: title,
                        identifier: identifier,
                        windowDescription: windowDescription,
                        unitText: unitText,
                        error: error
                    ))
                    return
                }

                let categorySamples = ((samples as? [HKCategorySample]) ?? []).filter {
                    includedValues.contains($0.value)
                }
                let sources = self.summarizeCategorySources(categorySamples, unitScale: nil)
                continuation.resume(returning: HealthKitDiagnosticMetric(
                    title: title,
                    identifier: identifier,
                    windowDescription: windowDescription,
                    unit: unitText,
                    sampleCount: categorySamples.count,
                    totalValue: Double(categorySamples.count),
                    sourceSummaries: sources,
                    errorMessage: nil
                ))
            }
            self.healthStore.execute(query)
        }
    }

    private func workoutMetric(
        start: Date,
        end: Date,
        windowDescription: String
    ) async -> HealthKitDiagnosticMetric {
        let type = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(returning: self.errorMetric(
                        title: "体能训练",
                        identifier: "HKWorkoutType",
                        windowDescription: windowDescription,
                        unitText: "分钟",
                        error: error
                    ))
                    return
                }

                let workouts = (samples as? [HKWorkout]) ?? []
                let total = workouts.reduce(0) { partial, workout in
                    partial + workout.duration / 60
                }
                let sources = self.summarizeWorkoutSources(workouts)
                continuation.resume(returning: HealthKitDiagnosticMetric(
                    title: "体能训练",
                    identifier: "HKWorkoutType",
                    windowDescription: windowDescription,
                    unit: "分钟",
                    sampleCount: workouts.count,
                    totalValue: total,
                    sourceSummaries: sources,
                    errorMessage: nil
                ))
            }
            self.healthStore.execute(query)
        }
    }

    private func summarizeQuantitySources(
        _ samples: [HKQuantitySample],
        unit: HKUnit
    ) -> [HealthKitDiagnosticSourceSummary] {
        let groups = Dictionary(grouping: samples, by: sourceKey)
        return groups.values.map { group in
            let first = group[0]
            let total = group.reduce(0) { partial, sample in
                partial + sample.quantity.doubleValue(for: unit)
            }
            return sourceSummary(from: first, sampleCount: group.count, totalValue: total)
        }
        .sorted { $0.sourceName < $1.sourceName }
    }

    private func summarizeCategorySources(
        _ samples: [HKCategorySample],
        unitScale: Double?
    ) -> [HealthKitDiagnosticSourceSummary] {
        let groups = Dictionary(grouping: samples, by: sourceKey)
        return groups.values.map { group in
            let first = group[0]
            let totalValue: Double
            if let unitScale = unitScale {
                totalValue = group.reduce(0) { partial, sample in
                    partial + sample.endDate.timeIntervalSince(sample.startDate) / unitScale
                }
            } else {
                totalValue = Double(group.count)
            }
            return sourceSummary(from: first, sampleCount: group.count, totalValue: totalValue)
        }
        .sorted { $0.sourceName < $1.sourceName }
    }

    private func summarizeWorkoutSources(_ workouts: [HKWorkout]) -> [HealthKitDiagnosticSourceSummary] {
        let groups = Dictionary(grouping: workouts, by: sourceKey)
        return groups.values.map { group in
            let first = group[0]
            let total = group.reduce(0) { partial, workout in
                partial + workout.duration / 60
            }
            return sourceSummary(from: first, sampleCount: group.count, totalValue: total)
        }
        .sorted { $0.sourceName < $1.sourceName }
    }

    private func sourceKey(for sample: HKSample) -> String {
        let source = sample.sourceRevision.source
        let device = sample.device
        return [
            source.name,
            source.bundleIdentifier,
            device?.name ?? "",
            device?.manufacturer ?? "",
            device?.model ?? ""
        ].joined(separator: "|")
    }

    private func sourceSummary(
        from sample: HKSample,
        sampleCount: Int,
        totalValue: Double?
    ) -> HealthKitDiagnosticSourceSummary {
        let source = sample.sourceRevision.source
        let device = sample.device
        return HealthKitDiagnosticSourceSummary(
            sourceName: source.name,
            bundleIdentifier: source.bundleIdentifier,
            deviceName: device?.name,
            manufacturer: device?.manufacturer,
            model: device?.model,
            sampleCount: sampleCount,
            totalValue: totalValue
        )
    }

    private func unavailableMetric(
        title: String,
        identifier: String,
        windowDescription: String,
        unitText: String
    ) -> HealthKitDiagnosticMetric {
        HealthKitDiagnosticMetric(
            title: title,
            identifier: identifier,
            windowDescription: windowDescription,
            unit: unitText,
            sampleCount: 0,
            totalValue: nil,
            sourceSummaries: [],
            errorMessage: "此设备不支持该 HealthKit 类型"
        )
    }

    private func errorMetric(
        title: String,
        identifier: String,
        windowDescription: String,
        unitText: String,
        error: Error
    ) -> HealthKitDiagnosticMetric {
        HealthKitDiagnosticMetric(
            title: title,
            identifier: identifier,
            windowDescription: windowDescription,
            unit: unitText,
            sampleCount: 0,
            totalValue: nil,
            sourceSummaries: [],
            errorMessage: error.localizedDescription
        )
    }
}
