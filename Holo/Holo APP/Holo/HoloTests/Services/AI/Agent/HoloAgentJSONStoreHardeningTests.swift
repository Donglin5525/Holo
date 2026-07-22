//
//  HoloAgentJSONStoreHardeningTests.swift
//  HoloTests
//
//  Holo Agent 稳定执行 — Phase 1（§5.5，修 P0-5）
//  JSON Store 硬化 XCTest（HoloTests target）：
//  - 读取权限/损坏错误抛 typed error 而非返回 []
//  - 解码失败进入 quarantine，mutate/save 一律拒绝，禁止空数组覆盖原文件
//  - destination 不存在时首次保存成功
//  - 暂时读取失败后不产生覆盖写
//  standalone 版本见 HoloAgentJSONStoreTests.swift。
//

import XCTest
@testable import Holo

final class HoloAgentJSONStoreHardeningTests: XCTestCase {

    private struct Item: Codable, Equatable {
        let id: String
        let value: Int
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-agent-store-hardening-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// §5.5：文件不存在 → 空数组（唯一合法的空库语义）。
    func testLoad_文件不存在返回空() async throws {
        let store = HoloAgentJSONStore<Item>(fileName: "none.json", directory: makeTempDir())
        let loaded = try await store.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    /// §5.5：暂时不可读（无权限）必须抛 readFailed，旧实现会静默返回 [] 进而被覆盖。
    func testLoad_无权限抛readFailed而非返回空() async throws {
        let dir = makeTempDir()
        let store = HoloAgentJSONStore<Item>(fileName: "locked.json", directory: dir)
        try await store.save([Item(id: "a", value: 1)])
        let fileURL = dir.appendingPathComponent("locked.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path) }

        do {
            _ = try await store.load()
            XCTFail("无权限读取应抛 readFailed，而非返回空数组")
        } catch let error as HoloAgentStoreError {
            guard case .readFailed = error else {
                return XCTFail("应抛 readFailed，实际 \(error)")
            }
        }

        // 暂时失败后的 mutate 不得执行 transform、不得写盘覆盖（P0-5 核心）
        do {
            _ = try await store.mutate { all in all.append(Item(id: "b", value: 2)) }
            XCTFail("读取失败时 mutate 应直接上抛，不得执行 transform")
        } catch let error as HoloAgentStoreError {
            guard case .readFailed = error else {
                return XCTFail("mutate 应抛 readFailed，实际 \(error)")
            }
        }

        // 恢复权限：原数据必须完好（未被空数组覆盖）
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        let recovered = try await store.load()
        XCTAssertEqual(recovered, [Item(id: "a", value: 1)], "暂时读取失败后原数据不得被覆盖")
    }

    /// §5.5：解码失败 → 隔离备份 + decodeFailed；此后 mutate/save 抛错，禁止覆盖。
    func testLoad_解码失败隔离并拒绝后续写入() async throws {
        let dir = makeTempDir()
        let fileURL = dir.appendingPathComponent("corrupt.json")
        let corruptPayload = Data("{ 无效 JSON !!!".utf8)
        try corruptPayload.write(to: fileURL)
        let store = HoloAgentJSONStore<Item>(fileName: "corrupt.json", directory: dir)

        do {
            _ = try await store.load()
            XCTFail("损坏 JSON 应抛 decodeFailed")
        } catch let error as HoloAgentStoreError {
            guard case .decodeFailed = error else {
                return XCTFail("应抛 decodeFailed，实际 \(error)")
            }
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("corrupt.json.backup.json").path),
            "损坏文件应生成隔离备份"
        )

        // quarantine：mutate 拒绝（load 阶段抛），save 拒绝（storeQuarantined）
        do {
            _ = try await store.mutate { all in all.append(Item(id: "x", value: 1)) }
            XCTFail("隔离后 mutate 应抛错")
        } catch let error as HoloAgentStoreError {
            guard case .decodeFailed = error else {
                return XCTFail("隔离后 mutate 应抛 decodeFailed，实际 \(error)")
            }
        }
        do {
            try await store.save([Item(id: "y", value: 2)])
            XCTFail("隔离后 save 应抛 storeQuarantined")
        } catch let error as HoloAgentStoreError {
            guard case .storeQuarantined = error else {
                return XCTFail("隔离后 save 应抛 storeQuarantined，实际 \(error)")
            }
        }

        let onDisk = try Data(contentsOf: fileURL)
        XCTAssertEqual(onDisk, corruptPayload, "隔离后原文件不得被覆盖改写")
    }

    /// §5.5：destination 不存在时首次保存必须成功（旧实现 replaceItemAt 直接失败）。
    func testSave_destination不存在首次原子创建() async throws {
        let dir = makeTempDir()
        let store = HoloAgentJSONStore<Item>(fileName: "fresh.json", directory: dir)
        try await store.save([Item(id: "first", value: 1)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("fresh.json").path))
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [Item(id: "first", value: 1)])
    }

    /// replace 失败时旧主文件与完整 temp 都必须保留，禁止“先删旧文件再 move”的丢文件窗口。
    func testSave_replace失败保留旧文件和temp() async throws {
        let dir = makeTempDir()
        let mainURL = dir.appendingPathComponent("replace.json")
        let tempURL = dir.appendingPathComponent("replace.json.tmp")
        let store = HoloAgentJSONStore<Item>(
            fileName: "replace.json",
            directory: dir,
            fileProtection: nil,
            replacementHandler: { _, _ in
                throw NSError(domain: "HoloAgentJSONStoreTests", code: 1)
            }
        )
        try await store.save([Item(id: "old", value: 1)])

        do {
            try await store.save([Item(id: "new", value: 2)])
            XCTFail("注入 replace 失败后 save 应抛 writeFailed")
        } catch let error as HoloAgentStoreError {
            guard case .writeFailed = error else {
                return XCTFail("应抛 writeFailed，实际 \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: mainURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        XCTAssertEqual(try await store.load(), [Item(id: "old", value: 1)])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode([Item].self, from: Data(contentsOf: tempURL)),
                       [Item(id: "new", value: 2)])
    }

    /// 主文件缺失但 temp 完整时，下次 load 应恢复 temp；两者并存时则永不覆盖旧主文件。
    func testLoad_主文件缺失时恢复完整temp() async throws {
        let dir = makeTempDir()
        let tempURL = dir.appendingPathComponent("recover.json.tmp")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([Item(id: "recovered", value: 3)]).write(to: tempURL, options: .atomic)

        let store = HoloAgentJSONStore<Item>(
            fileName: "recover.json",
            directory: dir,
            fileProtection: nil
        )
        XCTAssertEqual(try await store.load(), [Item(id: "recovered", value: 3)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("recover.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    /// §4.2：写盘后文件与目录必须应用 .completeUntilFirstUserAuthentication 保护。
    /// iOS 模拟器会静默丢弃 protectionKey（已用 simctl spawn 验证 set 成功但读回 nil），
    /// 故用注入的 spy 验证 store 确实对文件与目录应用了保护；真机读回验证留待真机验收。
    func testSave_文件保护属性应用() async throws {
        let dir = makeTempDir()
        let subdir = dir.appendingPathComponent("protected", isDirectory: true)
        var applied: [(path: String, protection: FileProtectionType)] = []
        let store = HoloAgentJSONStore<Item>(
            fileName: "p.json",
            directory: subdir,
            protectionApplier: { url, protection in
                applied.append((url.path, protection))
            }
        )
        try await store.save([Item(id: "p", value: 1)])

        let fileEntry = applied.first { $0.path.hasSuffix("p.json") }
        XCTAssertEqual(fileEntry?.protection, .completeUntilFirstUserAuthentication,
                       "保存后必须对数据文件应用文件保护")
        let dirEntry = applied.first { $0.path.hasSuffix("protected") }
        XCTAssertEqual(dirEntry?.protection, .completeUntilFirstUserAuthentication,
                       "创建目录时必须对目录应用文件保护")
    }
}
