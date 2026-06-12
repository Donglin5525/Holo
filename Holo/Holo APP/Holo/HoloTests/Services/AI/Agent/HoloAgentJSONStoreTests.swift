//
//  HoloAgentJSONStoreTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 1.2 JSON Store 通用基类（actor）测试
//  运行：swiftc <HoloAgentJSONStore.swift> <本测试> -o /tmp/holo_agent_store_test && /tmp/holo_agent_store_test
//

import Foundation

@main
struct HoloAgentJSONStoreTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async {
        await test文件不存在返回空()
        await test保存后可读取()
        await test损坏JSON备份并返回空()
        await test原子写入不留temp()
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
        let loaded = await store.load()
        expect(loaded.isEmpty, "文件不存在时应返回空数组，实际 \(loaded.count)")
    }

    private static func test保存后可读取() async {
        let dir = makeTempDir()
        let store = HoloAgentJSONStore<Item>(fileName: "items.json", directory: dir)
        let items = [Item(id: "a", value: 1), Item(id: "b", value: 2)]
        try? await store.save(items)
        let loaded = await store.load()
        expect(loaded.count == 2, "保存后应读到 2 项，实际 \(loaded.count)")
        expect(loaded == items, "保存后内容应与写入一致")
    }

    private static func test损坏JSON备份并返回空() async {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("corrupt.json")
        try? Data("{ 这是无效 JSON !!!".utf8).write(to: url)
        let store = HoloAgentJSONStore<Item>(fileName: "corrupt.json", directory: dir)
        let loaded = await store.load()
        expect(loaded.isEmpty, "损坏 JSON 应返回空数组，实际 \(loaded.count)")
        let backupURL = dir.appendingPathComponent("corrupt.json.backup.json")
        expect(FileManager.default.fileExists(atPath: backupURL.path), "损坏文件应被备份为 .backup.json")
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
}
