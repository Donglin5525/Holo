//
//  HoloAgentJSONStoreTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 1.2 JSON Store 通用基类（actor）测试
//  §5.5 硬化：load() 改 throws；损坏文件隔离 + quarantine；首次保存原子创建；文件保护属性。
//  运行：swiftc -parse-as-library \
//    "Holo/Services/AI/Agent/Persistence/HoloAgentJSONStore.swift" <本测试> \
//    -o /tmp/holo_agent_store_test && /tmp/holo_agent_store_test
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        await HoloAgentJSONStoreTests.main()
    }
}
#endif
struct HoloAgentJSONStoreTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async {
        await test文件不存在返回空()
        await test保存后可读取()
        await test损坏JSON备份并抛decodeFailed且隔离()
        await test隔离后mutate与save一律拒绝且不覆盖原文件()
        await test首次保存destination不存在时原子创建()
        await testReplace失败保留旧文件和temp()
        await test主文件缺失时恢复完整temp()
        await test原子写入不留temp()
        await test写盘后设置文件保护属性()
        print("HoloAgentJSONStoreTests passed")
    }

    // MARK: - 测试用 Codable 类型

    private struct Item: Codable, Equatable {
        let id: String
        let value: Int
    }

    /// 隔离测试目录，避免污染真实 Application Support
    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-agent-store-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 用例

    private static func test文件不存在返回空() async {
        let dir = makeTempDir()
        let store = HoloAgentJSONStore<Item>(fileName: "nonexistent.json", directory: dir)
        do {
            let loaded = try await store.load()
            expect(loaded.isEmpty, "文件不存在时应返回空数组，实际 \(loaded.count)")
        } catch {
            fatalError("文件不存在不应抛错，实际 \(error)")
        }
    }

    private static func test保存后可读取() async {
        let dir = makeTempDir()
        let store = HoloAgentJSONStore<Item>(fileName: "items.json", directory: dir)
        let items = [Item(id: "a", value: 1), Item(id: "b", value: 2)]
        do {
            try await store.save(items)
            let loaded = try await store.load()
            expect(loaded.count == 2, "保存后应读到 2 项，实际 \(loaded.count)")
            expect(loaded == items, "保存后内容应与写入一致")
        } catch {
            fatalError("保存/读取不应抛错，实际 \(error)")
        }
    }

    /// §5.5：损坏 JSON 不再静默返回 [] —— 抛 decodeFailed、生成隔离备份、进入 quarantine。
    private static func test损坏JSON备份并抛decodeFailed且隔离() async {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("corrupt.json")
        try? Data("{ 这是无效 JSON !!!".utf8).write(to: url)
        let store = HoloAgentJSONStore<Item>(fileName: "corrupt.json", directory: dir)
        do {
            _ = try await store.load()
            fatalError("损坏 JSON 应抛 decodeFailed，而非返回空数组")
        } catch let error as HoloAgentStoreError {
            guard case .decodeFailed = error else {
                fatalError("应抛 decodeFailed，实际 \(error)")
            }
        } catch {
            fatalError("应抛 HoloAgentStoreError，实际 \(error)")
        }
        let backupURL = dir.appendingPathComponent("corrupt.json.backup.json")
        expect(FileManager.default.fileExists(atPath: backupURL.path), "损坏文件应被备份为 .backup.json")
    }

    /// §5.5：隔离后 mutate/save 必须拒绝，且不得把空数组覆盖回原文件（P0-5）。
    private static func test隔离后mutate与save一律拒绝且不覆盖原文件() async {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("locked.json")
        let corruptPayload = Data("{ 仍然无效 !!!".utf8)
        try? corruptPayload.write(to: url)
        let store = HoloAgentJSONStore<Item>(fileName: "locked.json", directory: dir)
        // 触发隔离
        do { _ = try await store.load(); fatalError("应抛错") } catch {}

        do {
            _ = try await store.mutate { all in all.append(Item(id: "x", value: 1)) }
            fatalError("隔离后 mutate 应抛 storeQuarantined")
        } catch let error as HoloAgentStoreError {
            // load 阶段即抛 decodeFailed/quarantined；两者都属于「拒绝执行 transform」
            guard case .decodeFailed = error else {
                fatalError("隔离后 mutate 应抛 decodeFailed/storeQuarantined，实际 \(error)")
            }
        } catch {
            fatalError("应抛 HoloAgentStoreError，实际 \(error)")
        }
        do {
            try await store.save([Item(id: "y", value: 2)])
            fatalError("隔离后 save 应抛 storeQuarantined")
        } catch let error as HoloAgentStoreError {
            guard case .storeQuarantined = error else {
                fatalError("隔离后 save 应抛 storeQuarantined，实际 \(error)")
            }
        } catch {
            fatalError("应抛 HoloAgentStoreError，实际 \(error)")
        }

        let onDisk = (try? Data(contentsOf: url)) ?? Data()
        expect(onDisk == corruptPayload, "隔离后原文件不得被覆盖改写")
    }

    /// §5.5：destination 不存在时首次保存必须成功（旧实现 replaceItemAt 会失败）。
    private static func test首次保存destination不存在时原子创建() async {
        let dir = makeTempDir()
        let store = HoloAgentJSONStore<Item>(fileName: "fresh.json", directory: dir)
        let mainURL = dir.appendingPathComponent("fresh.json")
        expect(!FileManager.default.fileExists(atPath: mainURL.path), "前置：目标文件不存在")
        do {
            try await store.save([Item(id: "first", value: 1)])
        } catch {
            fatalError("首次保存（destination 不存在）应成功，实际抛错 \(error)")
        }
        expect(FileManager.default.fileExists(atPath: mainURL.path), "首次保存后主文件应存在")
    }

    private static func testReplace失败保留旧文件和temp() async {
        let dir = makeTempDir()
        let store = HoloAgentJSONStore<Item>(
            fileName: "replace.json",
            directory: dir,
            fileProtection: nil,
            replacementHandler: { _, _ in
                throw NSError(domain: "HoloAgentJSONStoreTests", code: 1)
            }
        )
        do {
            try await store.save([Item(id: "old", value: 1)])
            try await store.save([Item(id: "new", value: 2)])
            fatalError("replace 失败应抛 writeFailed")
        } catch let error as HoloAgentStoreError {
            guard case .writeFailed = error else { fatalError("应抛 writeFailed，实际 \(error)") }
        } catch {
            fatalError("应抛 HoloAgentStoreError，实际 \(error)")
        }
        expect(fileManagerExists(dir.appendingPathComponent("replace.json")), "旧主文件必须保留")
        expect(fileManagerExists(dir.appendingPathComponent("replace.json.tmp")), "完整 temp 必须保留")
        do {
            let loaded = try await store.load()
            expect(loaded == [Item(id: "old", value: 1)], "replace 失败后应继续读取旧数据")
        } catch {
            fatalError("读取旧数据不应失败：\(error)")
        }
    }

    private static func test主文件缺失时恢复完整temp() async {
        let dir = makeTempDir()
        let tempURL = dir.appendingPathComponent("recover.json.tmp")
        do {
            try JSONEncoder().encode([Item(id: "recovered", value: 3)]).write(to: tempURL, options: .atomic)
            let store = HoloAgentJSONStore<Item>(fileName: "recover.json", directory: dir, fileProtection: nil)
            let loaded = try await store.load()
            expect(loaded == [Item(id: "recovered", value: 3)], "应恢复完整 temp")
            expect(fileManagerExists(dir.appendingPathComponent("recover.json")), "恢复后主文件应存在")
            expect(!fileManagerExists(tempURL), "恢复后 temp 应已移入主文件")
        } catch {
            fatalError("temp 恢复不应失败：\(error)")
        }
    }

    private static func fileManagerExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func test原子写入不留temp() async {
        let dir = makeTempDir()
        let store = HoloAgentJSONStore<Item>(fileName: "atomic.json", directory: dir)
        try? await store.save([Item(id: "x", value: 99)])
        let mainURL = dir.appendingPathComponent("atomic.json")
        expect(FileManager.default.fileExists(atPath: mainURL.path), "原子写入后主文件应存在")
        let tempURL = dir.appendingPathComponent("atomic.json.tmp")
        expect(!FileManager.default.fileExists(atPath: tempURL.path), "原子写入后不应残留 temp 文件")
    }

    /// §4.2：写盘后文件与目录必须带 .completeUntilFirstUserAuthentication 保护。
    /// 注：iOS 与 macOS 对该属性的桥接类型不同（String / FileProtectionType），统一按 rawValue 比较。
    private static func test写盘后设置文件保护属性() async {
        #if targetEnvironment(simulator)
        // 模拟器会静默丢弃 protectionKey；HoloAgentJSONStoreHardeningTests
        // 通过注入 protectionApplier 验证真实调用，读回属性留给真机验收。
        return
        #endif
        let dir = makeTempDir()
        let subdir = dir.appendingPathComponent("protected", isDirectory: true)
        let store = HoloAgentJSONStore<Item>(fileName: "protected.json", directory: subdir)
        do {
            try await store.save([Item(id: "p", value: 1)])
            let fileAttrs = try FileManager.default.attributesOfItem(
                atPath: subdir.appendingPathComponent("protected.json").path)
            let protection = protectionRawValue(fileAttrs)
            expect(protection == FileProtectionType.completeUntilFirstUserAuthentication.rawValue,
                   "文件保护应为 completeUntilFirstUserAuthentication，实际 \(String(describing: protection))")
            let dirAttrs = try FileManager.default.attributesOfItem(atPath: subdir.path)
            let dirProtection = protectionRawValue(dirAttrs)
            expect(dirProtection == FileProtectionType.completeUntilFirstUserAuthentication.rawValue,
                   "目录保护应为 completeUntilFirstUserAuthentication，实际 \(String(describing: dirProtection))")
        } catch {
            fatalError("文件保护验证不应抛错，实际 \(error)")
        }
    }

    /// 读取文件保护属性值（兼容 String 与 FileProtectionType 两种桥接）。
    private static func protectionRawValue(_ attrs: [FileAttributeKey: Any]) -> String? {
        if let typed = attrs[.protectionKey] as? FileProtectionType { return typed.rawValue }
        return attrs[.protectionKey] as? String
    }
}
