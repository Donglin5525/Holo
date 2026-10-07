import Foundation
import SQLite3
@main struct SemanticEdgeProbe {
 static func main() async throws {
  setvbuf(stdout, nil, _IONBF, 0)
  let mode = CommandLine.arguments.dropFirst().first ?? "normal"
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("holo-review-probe-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  if mode == "open" {
   let badRoot = root.appendingPathComponent("file")
   try Data([1]).write(to: badRoot)
   let store = await ThoughtSemanticStore(root: badRoot)
   do { try await store.open(); print("unexpected success") }
   catch { print("open failure captured:", error) }
   return
  }
  let store = await ThoughtSemanticStore(root: root)
  try await store.open()
  let dimension = mode == "negative" ? -1 : 1024
  let item = ThoughtSemanticStore.SemanticItem(id: UUID(), contentHash: "test", modelVersion: ThoughtSemanticStore.defaultModelVersion, dimension: dimension, vectorKey: 1, state: "active", priority: 0, lastAccessedAt: nil, updatedAt: Date())
  try await store.upsertItem(item, vector: [Float16(1)])
  print("malformed row accepted, dimension=\(dimension), blobBytes=2")
  let rows = try await store.loadAllActiveVectors(modelVersion: ThoughtSemanticStore.defaultModelVersion)
  print("read returned:",rows.first?.vector.count ?? 0)
 }
}
