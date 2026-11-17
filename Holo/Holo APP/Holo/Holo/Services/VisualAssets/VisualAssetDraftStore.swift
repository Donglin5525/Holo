//
//  VisualAssetDraftStore.swift
//  Holo
//
//  纯视觉草稿的文件协议（2026-11-16 方案 02 §5.3）：制作/编辑中途退出不丢已完成的抠图
//  与修边结果；提交成功后按回执清理，save 后进程被杀的重启路径按 operationID 对账。
//  - 新文件先原子写成功，再更新 manifest；写文件/写 manifest 失败必须让调用方知道
//    （类型化错误，不吞成日志假成功）
//  - 恢复先验证文件 SHA256；已提交 operation 走回执不再次应用
//  - 不保存外部 URL / NSManagedObjectID；scopeGeneration 变化后旧草稿不出现在新账号
//

import Foundation
import CommonCrypto

/// draft 持久化用的 kind 原始串（不携带运行枚举语义，未知值可保留）
enum VisualDraftKindRaw: String, Codable {
    case sticker, photo
}

extension VisualAssetKind {
    var draftRaw: VisualDraftKindRaw { VisualDraftKindRaw(rawValue: rawValue) ?? .sticker }
}

/// visualDraftV1：一次未提交的视觉编辑会话
struct VisualAssetDraftV1: Codable, Equatable {
    var schemaVersion: Int = 1
    var scopeGeneration: Int
    var operationID: UUID
    var editorSessionID: String
    var ownerKind: String
    var ownerKey: String
    var slot: String
    var expectedSlotWinnerRevisionID: UUID?
    var kind: VisualDraftKindRaw
    /// 文件名 → SHA256（文件本体在草稿目录）
    var files: [String: String]
    var payload: VisualDraftPayloadCodable?
    /// 提交成功后的回执（有回执 = 只需对账清理，不再恢复编辑）
    var receipt: VisualDraftReceiptCodable?
}

struct VisualDraftPayloadCodable: Codable, Equatable {
    var action: String
    var borderStyle: String
    var borderWeight: String
    var rotationDegrees: Double
}

struct VisualDraftReceiptCodable: Codable, Equatable {
    var operationID: UUID
    var assetID: UUID?
    var revisionID: UUID
}

enum VisualDraftStoreError: Error, Equatable {
    case writeFailed(String)
    case hashMismatch(file: String)
    case decodingFailed(String)
}

final class VisualAssetDraftStore {

    static let shared = VisualAssetDraftStore()

    private let root: URL
    private let queue = DispatchQueue(label: "holo.visual.draft", qos: .utility)

    init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            root = rootDirectory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            root = base.appendingPathComponent("VisualAssetDrafts", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - 写（原子：文件先落，manifest 后落）

    /// 保存/覆盖一份草稿。fileContents 的 key 是稳定文件名；hash 在写入时计算并登记。
    func save(_ draft: VisualAssetDraftV1, fileContents: [String: Data]) throws {
        var thrown: Error?
        queue.sync {
            do {
                let opDir = root.appendingPathComponent(draft.operationID.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: opDir, withIntermediateDirectories: true)
                var files = draft.files
                for (name, data) in fileContents {
                    let tmp = opDir.appendingPathComponent("." + name + ".tmp")
                    try data.write(to: tmp, options: .atomic)
                    let url = opDir.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    try FileManager.default.moveItem(at: tmp, to: url)
                    files[name] = Self.sha256(data)
                }
                var full = draft
                full.files = files
                let manifest = opDir.appendingPathComponent("manifest.json")
                let encoded = try JSONEncoder().encode(full)
                try encoded.write(to: manifest, options: .atomic)
            } catch let e as VisualDraftStoreError {
                thrown = e
            } catch {
                thrown = VisualDraftStoreError.writeFailed("\(error)")
            }
        }
        if let thrown { throw thrown }
    }

    // MARK: - 读（hash 校验）

    /// 恢复草稿：manifest 解码 + 全部文件 hash 核对
    func restore(operationID: UUID) throws -> (draft: VisualAssetDraftV1, contents: [String: Data])? {
        var result: (VisualAssetDraftV1, [String: Data])?
        var thrown: Error?
        queue.sync {
            let opDir = root.appendingPathComponent(operationID.uuidString, isDirectory: true)
            let manifest = opDir.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { return }
            do {
                let draft = try JSONDecoder().decode(VisualAssetDraftV1.self, from: Data(contentsOf: manifest))
                var contents: [String: Data] = [:]
                for (name, expectedHash) in draft.files {
                    let fileData = try Data(contentsOf: opDir.appendingPathComponent(name))
                    guard Self.sha256(fileData) == expectedHash else {
                        thrown = VisualDraftStoreError.hashMismatch(file: name)
                        return
                    }
                    contents[name] = fileData
                }
                result = (draft, contents)
            } catch let e as VisualDraftStoreError {
                thrown = e
            } catch {
                thrown = VisualDraftStoreError.decodingFailed("\(error)")
            }
        }
        if let thrown { throw thrown }
        return result
    }

    /// 提交成功后清理（确认无在途任务才删目录）
    func clear(operationID: UUID) {
        queue.sync {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(operationID.uuidString, isDirectory: true))
        }
    }

    /// scope 切换后：清掉所有旧 generation 的草稿（旧账号草稿不出现在新账号恢复项）
    func clearStale(generation: Int) {
        queue.sync {
            guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
            for dir in dirs {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                      let draft = try? JSONDecoder().decode(VisualAssetDraftV1.self, from: data),
                      draft.scopeGeneration != generation else { continue }
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    static func sha256(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            _ = CC_SHA256(raw.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
