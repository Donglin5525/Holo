//
//  VisualPlacementPayload.swift
//  Holo
//
//  位置负载 v1（2026-11-16 方案 02 §4.4）：一次逻辑应用/移除/日代表选择的完整不可变负载。
//  JSON 形状是跨端契约（schemaVersion/action/selection/presentation），字段类型以此为准；
//  规范编码 sortedKeys + withoutEscapingSlashes，payloadHash = SHA256(canonical bytes)。
//  约束：focusX/Y∈[0,1]；scale∈[0.6,1.2]；rotationDegrees∈[−6,6]；sticker 只允许 contain；
//  未知枚举与高版本不得以默认值覆盖原值（解析侧返回 unsupported，编辑侧禁写）。
//

import Foundation
import CommonCrypto

// MARK: - 负载主体

struct VisualPlacementPayload: Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var action: Action
    var selection: Selection?
    var presentation: Presentation?

    enum Action: String, Equatable { case set, clear }

    /// asset 选择与 record（galleryDay 日代表）选择共用一个扁平结构，
    /// 与 02 §4.4 的 JSON 键一一对应。
    struct Selection: Equatable {
        var type: SelectionType
        var assetID: UUID?
        var sourceAttachmentID: UUID?
        var module: String?
        var recordID: UUID?

        enum SelectionType: String, Equatable { case asset, record }

        static func asset(_ id: UUID, sourceAttachmentID: UUID? = nil) -> Selection {
            Selection(type: .asset, assetID: id, sourceAttachmentID: sourceAttachmentID, module: nil, recordID: nil)
        }
        static func record(module: String, recordID: UUID) -> Selection {
            Selection(type: .record, assetID: nil, sourceAttachmentID: nil, module: module, recordID: recordID)
        }
    }

    struct Presentation: Equatable {
        var fit: Fit = .contain
        var focusX: Double = 0.5
        var focusY: Double = 0.5
        var scale: Double = 1.0
        var rotationDegrees: Double = 0
        var borderStyle: BorderStyle = .adaptivePaper
        var borderWeight: BorderWeight = .standard
        var softenPhotoInDark: Bool = false

        enum Fit: String, Equatable { case contain, cover }
        enum BorderStyle: String, Equatable { case adaptivePaper, white, none }
        enum BorderWeight: String, Equatable { case thin, standard }
    }

    static func setAsset(_ selection: Selection, presentation: Presentation?) -> VisualPlacementPayload {
        VisualPlacementPayload(schemaVersion: currentSchemaVersion, action: .set,
                               selection: selection, presentation: presentation)
    }
    static func setRecord(module: String, recordID: UUID) -> VisualPlacementPayload {
        VisualPlacementPayload(schemaVersion: currentSchemaVersion, action: .set,
                               selection: .record(module: module, recordID: recordID), presentation: nil)
    }
    static var clear: VisualPlacementPayload {
        VisualPlacementPayload(schemaVersion: currentSchemaVersion, action: .clear,
                               selection: nil, presentation: nil)
    }
}

// MARK: - 值域校验（payloadValid）

enum VisualPlacementPayloadError: Error, Equatable {
    case unknownSchemaVersion(Int)
    case invalidFocus
    case invalidScale
    case invalidRotation
    case stickerMustContain
    case missingSelection
    case selectionTypeMismatch
}

extension VisualPlacementPayload {

    /// 完整性校验：clear 不带 selection；set 必带；数值界与 sticker 约束按 02 §4.4。
    /// 未知 schemaVersion 单独由 ``isSupportedByCurrentVersion`` 判定（unsupported ≠ corrupt）。
    func validate(kind: VisualAssetKind?) throws {
        switch action {
        case .clear:
            if selection != nil || presentation != nil { throw VisualPlacementPayloadError.missingSelection }
        case .set:
            guard let selection else { throw VisualPlacementPayloadError.missingSelection }
            switch selection.type {
            case .asset:
                guard selection.assetID != nil else { throw VisualPlacementPayloadError.selectionTypeMismatch }
                if let module = selection.module, !module.isEmpty { throw VisualPlacementPayloadError.selectionTypeMismatch }
                if selection.recordID != nil { throw VisualPlacementPayloadError.selectionTypeMismatch }
            case .record:
                guard selection.recordID != nil, let module = selection.module, !module.isEmpty else {
                    throw VisualPlacementPayloadError.selectionTypeMismatch }
                if selection.assetID != nil || selection.sourceAttachmentID != nil {
                    throw VisualPlacementPayloadError.selectionTypeMismatch }
            }
            if let p = presentation {
                guard (0...1).contains(p.focusX), (0...1).contains(p.focusY) else {
                    throw VisualPlacementPayloadError.invalidFocus }
                guard (0.6...1.2).contains(p.scale) else {
                    throw VisualPlacementPayloadError.invalidScale }
                guard (-6...6).contains(p.rotationDegrees) else {
                    throw VisualPlacementPayloadError.invalidRotation }
                if kind == .sticker, p.fit != .contain {
                    throw VisualPlacementPayloadError.stickerMustContain }
            }
        }
    }

    var isSupportedByCurrentVersion: Bool { schemaVersion <= Self.currentSchemaVersion }
}

// MARK: - 规范编码

enum VisualPlacementCoding {

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// 负载规范 JSON 字节
    static func canonicalData(_ payload: VisualPlacementPayload) throws -> Data {
        try encoder.encode(PayloadDTO(payload))
    }

    /// 规范字节的 SHA256 十六进制（CommonCrypto：工程无 swift-crypto 依赖）
    static func hash(of payload: VisualPlacementPayload) throws -> String {
        let data = try canonicalData(payload)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            _ = CC_SHA256(raw.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// placementKey = [ownerKind, ownerKey, slot] 的规范 JSON 数组稳定编码
    static func placementKey(ownerKind: String, ownerKey: String, slot: String) -> String {
        let parts = [ownerKind, ownerKey, slot]
            .map { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        return "[\"" + parts.joined(separator: "\",\"") + "\"]"
    }

    /// ownerKey 规范化：UUID 小写标准串（方案 02 §4.3）
    static func normalizedOwnerKey(_ raw: String) -> String { raw.lowercased() }
}

// MARK: - Codable DTO（精确匹配 02 §4.4 的 JSON 形状）

private struct PayloadDTO: Codable {
    var schemaVersion: Int
    var action: String
    var selection: SelectionDTO?
    var presentation: PresentationDTO?

    struct SelectionDTO: Codable {
        var type: String
        var assetID: String?
        var sourceAttachmentID: String?
        var module: String?
        var recordID: String?
    }
    struct PresentationDTO: Codable {
        var fit: String
        var focusX: Double
        var focusY: Double
        var scale: Double
        var rotationDegrees: Double
        var borderStyle: String
        var borderWeight: String
        var softenPhotoInDark: Bool
    }

    init(_ payload: VisualPlacementPayload) {
        schemaVersion = payload.schemaVersion
        action = payload.action.rawValue
        selection = payload.selection.map {
            SelectionDTO(type: $0.type.rawValue,
                         assetID: $0.assetID?.uuidString,
                         sourceAttachmentID: $0.sourceAttachmentID?.uuidString,
                         module: $0.module,
                         recordID: $0.recordID?.uuidString)
        }
        presentation = payload.presentation.map {
            PresentationDTO(fit: $0.fit.rawValue, focusX: $0.focusX, focusY: $0.focusY,
                            scale: $0.scale, rotationDegrees: $0.rotationDegrees,
                            borderStyle: $0.borderStyle.rawValue, borderWeight: $0.borderWeight.rawValue,
                            softenPhotoInDark: $0.softenPhotoInDark)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, action, selection, presentation
    }

    /// 解码（未知枚举抛错，不以默认值覆盖——corrupt 而非静默降级）
    func toPayload() throws -> VisualPlacementPayload {
        guard let action = VisualPlacementPayload.Action(rawValue: action) else {
            throw VisualPlacementPayloadError.selectionTypeMismatch }
        var decodedSelection: VisualPlacementPayload.Selection?
        if let s = selection {
            guard let type = VisualPlacementPayload.Selection.SelectionType(rawValue: s.type) else {
                throw VisualPlacementPayloadError.selectionTypeMismatch }
            decodedSelection = .init(type: type,
                              assetID: s.assetID.flatMap(UUID.init(uuidString:)),
                              sourceAttachmentID: s.sourceAttachmentID.flatMap(UUID.init(uuidString:)),
                              module: s.module,
                              recordID: s.recordID.flatMap(UUID.init(uuidString:)))
        }
        var decodedPresentation: VisualPlacementPayload.Presentation?
        if let p = presentation {
            guard let fit = VisualPlacementPayload.Presentation.Fit(rawValue: p.fit),
                  let borderStyle = VisualPlacementPayload.Presentation.BorderStyle(rawValue: p.borderStyle),
                  let borderWeight = VisualPlacementPayload.Presentation.BorderWeight(rawValue: p.borderWeight) else {
                throw VisualPlacementPayloadError.selectionTypeMismatch }
            decodedPresentation = .init(fit: fit, focusX: p.focusX, focusY: p.focusY,
                                 scale: p.scale, rotationDegrees: p.rotationDegrees,
                                 borderStyle: borderStyle, borderWeight: borderWeight,
                                 softenPhotoInDark: p.softenPhotoInDark)
        }
        return VisualPlacementPayload(schemaVersion: schemaVersion, action: action,
                                      selection: decodedSelection, presentation: decodedPresentation)
    }
}

extension VisualPlacementCoding {
    /// 解码负载；JSON 坏 / 枚举未知 / UUID 串坏 → 抛错（corrupt 路径）
    static func decode(from json: String) throws -> VisualPlacementPayload {
        guard let data = json.data(using: .utf8) else { throw VisualPlacementPayloadError.missingSelection }
        return try decoder.decode(PayloadDTO.self, from: data).toPayload()
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}

// MARK: - 素材类型（VisualAsset.kind 的值域）

enum VisualAssetKind: String, Equatable {
    case sticker
    case photo
    /// 未知 kind 只读占位（02 §4.2）
    static func from(raw: String?) -> VisualAssetKind? {
        raw.flatMap { VisualAssetKind(rawValue: $0) }
    }
}
