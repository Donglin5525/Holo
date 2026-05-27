import Foundation

@main
struct HabitFocusSummaryStandaloneTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }

    static func main() {
        testSmokingGoalIsRecognizedAsNegativeFocusTopic()
        testManualPositiveMarkWinsOverNegativeKeywordButNeedsClarification()
        testNegativeHabitTrendTreatsMoreSmokingAsWorse()
        print("HabitFocusSummary standalone tests passed")
    }

    private static func testSmokingGoalIsRecognizedAsNegativeFocusTopic() {
        let signal = HabitFocusSignal.classify(
            habitName: "戒烟",
            isBadHabit: false,
            goalTitle: "戒烟 90 天",
            profileContext: "我正在戒烟，希望减少复吸。"
        )

        expect(signal.polarity == .negative, "戒烟主题应被识别为负向习惯")
        expect(signal.sources.contains(.habitKeyword), "习惯名关键词应作为来源")
        expect(signal.sources.contains(.goalKeyword), "目标关键词应作为来源")
        expect(signal.sources.contains(.profileKeyword), "档案关键词应作为来源")
        expect(signal.needsClarification == false, "三层信号一致时不应追问")
    }

    private static func testManualPositiveMarkWinsOverNegativeKeywordButNeedsClarification() {
        let signal = HabitFocusSignal.classify(
            habitName: "戒烟学习资料",
            isBadHabit: false,
            goalTitle: nil,
            profileContext: nil
        )

        expect(signal.polarity == .positive, "手动未标记坏习惯时不应直接覆盖为负向")
        expect(signal.needsClarification, "关键词冲突时应标记需要确认")
    }

    private static func testNegativeHabitTrendTreatsMoreSmokingAsWorse() {
        let current = HabitPerformanceSnapshot(
            habitName: "抽烟",
            polarity: .negative,
            successRule: .stayBelowTarget,
            completionRate: 4.0 / 7.0,
            totalValue: 18,
            targetValue: 3,
            unit: "根",
            controlledDays: 4,
            overLimitDays: 3,
            completedDays: 4,
            totalDays: 7
        )
        let previous = HabitPerformanceSnapshot(
            habitName: "抽烟",
            polarity: .negative,
            successRule: .stayBelowTarget,
            completionRate: 6.0 / 7.0,
            totalValue: 8,
            targetValue: 3,
            unit: "根",
            controlledDays: 6,
            overLimitDays: 1,
            completedDays: 6,
            totalDays: 7
        )

        let summary = HabitFocusSummary(
            habitName: "抽烟",
            signal: HabitFocusSignal(polarity: .negative, sources: [.manualBadHabit], needsClarification: false),
            current: current,
            previous: previous,
            currentStreak: 2,
            goalTitle: "戒烟"
        )

        expect(summary.trend == .worse, "负向习惯发生量增加应判定为恶化")
        expect(summary.totalValueDelta == 10, "总量变化应为 +10")
        expect(summary.overLimitDaysDelta == 2, "超标天数变化应为 +2")
        expect(summary.aiContextLine.contains("负向习惯"), "AI 摘要应标注负向习惯")
        expect(summary.aiContextLine.contains("发生总量 18根"), "AI 摘要应描述发生总量")
        expect(summary.aiContextLine.contains("比上期增加 10根"), "AI 摘要应描述坏趋势")
        expect(summary.aiContextLine.contains("超标 3 天"), "AI 摘要应描述超标天数")
        expect(!summary.aiContextLine.contains("完成更多"), "AI 摘要不能把坏习惯变多写成完成更多")
    }
}
