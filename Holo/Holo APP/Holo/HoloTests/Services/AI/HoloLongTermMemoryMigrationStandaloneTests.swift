import Foundation

@main
struct HoloLongTermMemoryMigrationStandaloneTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() throws {
        let json = """
        [
          {
            "id":"legacy-confirmed","type":"recurringPattern","title":"6月22日支出1999",
            "summary":"单笔支出","confidence":"medium","confirmationState":"confirmed",
            "sensitivity":"normal","evidence":[],
            "createdAt":"2026-06-22T00:00:00Z","updatedAt":"2026-06-22T00:00:00Z"
          },
          {
            "id":"semantic-v2","type":"recurringPattern","title":"跑步节奏恢复",
            "summary":"兼容摘要","confidence":"high","confirmationState":"silentlyAccepted",
            "sensitivity":"normal","evidence":[{
              "id":"e1","source":"memoryInsight","sourceID":"habit-running",
              "excerpt":"连续三周跑步","observedAt":"2026-07-13T00:00:00Z"
            }],
            "createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-13T00:00:00Z",
            "subjectKey":"habit:running","semanticType":"stablePattern","displaySummary":"连续三周保持跑步",
            "aiUseSummary":"健康建议可参考跑步节奏，但需结合最新记录。",
            "useScopes":["coreContext","recentInsight"],
            "prohibitedInferences":["不要表述为强制偏好"]
          }
        ]
        """

        let result = try HoloLongTermMemoryMigration.decodeAndFilter(Data(json.utf8))
        expect(result.removedLegacyCount == 1, "应删除全部旧格式记录")
        expect(result.memories.count == 1, "应只保留严格新格式记录")
        expect(result.memories[0].id == "semantic-v2", "保留的新格式记录错误")
        expect(result.memories[0].subjectKey == "habit:running", "稳定主题键应为必填字段")
        expect(result.memories[0].semanticType == .stablePattern, "语义类型应为必填字段")
        expect(result.memories[0].displaySummary == "连续三周保持跑步", "应使用新格式展示摘要")
        print("HoloLongTermMemoryMigration standalone tests passed")
    }
}
