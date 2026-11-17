//
//  SubjectExtractionService.swift
//  Holo
//
//  贴纸主体提取 P0：iOS17 基线的 VNGenerateForegroundInstanceMaskRequest（端侧、不联网）。
//  产出与工作图同尺寸的 8bit 占用遮罩——修边、纸边、导出都只作用在这份 mask 上。
//  调度纪律（02 §3.6）：串行工作队列保证同一时刻只有一个重分割请求（正在执行的退出前
//  不启动下一个）；进入队列前与返回前各检查一次取消——取消立即返回，底层计算未必然
//  停止、迟到结果不落地。P1 接入 (scopeGeneration, editorSessionID, requestGeneration,
//  operationID) 四元组校验后，迟到丢弃由调用方统一裁决。
//

import Foundation
import Vision
import CoreVideo

enum SubjectExtractionError: Error, Equatable {
    /// 没有找到清晰主体（用户可裁近重试、换图或改用照片——保持可继续）
    case noSubjectFound
    /// Vision 请求失败（能力/资源类），携带错误描述供诊断分类
    case requestFailed(String)
}

/// 一次提取结果：选中的实例索引 + 该组合的占用遮罩（工作画布坐标）
struct SubjectExtractionResult {
    let instanceIndices: [Int]
    let occupancyMask: CVPixelBuffer
}

/// 单 worker 主体提取：串行队列执行 Vision 重请求，不占用 Swift 并发线程池
final class SubjectExtractionService {

    static let shared = SubjectExtractionService()

    private let workerQueue = DispatchQueue(label: "holo.visual.subject-extraction", qos: .userInitiated)

    /// 提取主体占用遮罩。
    /// - Parameters:
    ///   - image: 已过 ``VisualAssetImageProcessor/prepareWorkingImage(from:)`` 的工作图
    ///   - instances: 指定实例子集（用户点选/组合）；nil = 全部前景实例（仅用于用户明确选「全部主体」）
    /// - Returns: 遮罩为 OneComponent8、尺寸与输入一致
    func extract(from image: CGImage, instances: [Int]? = nil) async throws -> SubjectExtractionResult {
        try Task.checkCancellation()
        let result: SubjectExtractionResult = try await withCheckedThrowingContinuation { cont in
            workerQueue.async {
                cont.resume(with: Result { try Self.performRequest(on: image, instances: instances) })
            }
        }
        try Task.checkCancellation()
        return result
    }

    /// 当前可选实例列表（供确认页点选；实例索引仅本次分析有效，重新裁剪后不得沿用）
    func availableInstances(of image: CGImage) async throws -> [Int] {
        try Task.checkCancellation()
        let instances: [Int] = try await withCheckedThrowingContinuation { cont in
            workerQueue.async {
                cont.resume(with: Result { try Self.performProbe(on: image) })
            }
        }
        try Task.checkCancellation()
        return instances
    }

    // MARK: - 私有（重活，只在串行队列上跑）

    private static func performProbe(on image: CGImage) throws -> [Int] {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) }
        catch { throw SubjectExtractionError.requestFailed("\(error)") }
        guard let observation = request.results?.first as? VNInstanceMaskObservation,
              !observation.allInstances.isEmpty else {
            throw SubjectExtractionError.noSubjectFound
        }
        return Array(observation.allInstances)
    }

    private static func performRequest(on image: CGImage, instances: [Int]?) throws -> SubjectExtractionResult {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) }
        catch { throw SubjectExtractionError.requestFailed("\(error)") }
        guard let observation = request.results?.first as? VNInstanceMaskObservation,
              !observation.allInstances.isEmpty else {
            throw SubjectExtractionError.noSubjectFound
        }
        // 背景（索引 0）不可选：调用方传入的子集也过滤掉
        let chosen: [Int]
        if let instances {
            chosen = instances.filter { $0 > 0 && observation.allInstances.contains($0) }
        } else {
            chosen = Array(observation.allInstances)
        }
        guard !chosen.isEmpty else { throw SubjectExtractionError.noSubjectFound }
        do {
            // 系统缩放蒙版（高质量 alpha）；实例标签图不是 alpha，不得直接用（02 §3.2）
            let mask = try observation.generateScaledMaskForImage(forInstances: IndexSet(chosen), from: handler)
            return SubjectExtractionResult(instanceIndices: chosen, occupancyMask: mask)
        } catch {
            throw SubjectExtractionError.requestFailed("\(error)")
        }
    }
}
