import Foundation

// MARK: - 每日结算时间（日界平移）

/// 习惯「一天」从几点结算。默认凌晨 0 点 = 自然日；设为 8:00 则 0:00–7:59 的打卡算前一天
/// （夜猫子睡前习惯拖过零点、晨间习惯在结算前完成，都不该被切到第二天）。
///
/// 实现等价于把该习惯的时间轴整体向前平移结算时长，让它的日界落回零点，因此只有一条规则：
/// - 「真实时刻」（实时打卡、此刻、创建时刻）先平移再切天；
/// - 「日坐标」（补签目标日、暂停窗口、用户在日历上选的日子）本身就是整日，原样使用。
/// 存量数据不改写：口径是读取规则而非数据，用户改结算时间后历史记录按新口径即时重算，
/// 多设备间无需迁移即一致。
nonisolated enum HabitDayAttribution {

    /// 真实时刻 → 日界坐标
    static func attributedMoment(_ moment: Date, dayEndMinutes: Int) -> Date {
        guard dayEndMinutes != 0 else { return moment }
        return moment.addingTimeInterval(-TimeInterval(dayEndMinutes) * 60)
    }

    static func attributedDay(_ moment: Date, dayEndMinutes: Int, calendar: Calendar) -> Date {
        calendar.startOfDay(for: attributedMoment(moment, dayEndMinutes: dayEndMinutes))
    }

    /// 记录的归属时刻。补签记录（isRetroactive）与整日坐标记录（date 恰为零点，种子/导入等
    /// 按天写入的数据）按日坐标原样返回；实时打卡记录按结算时间平移。
    static func attributedMoment(
        recordDate: Date,
        isRetroactive: Bool,
        dayEndMinutes: Int,
        calendar: Calendar
    ) -> Date {
        guard dayEndMinutes != 0 else { return recordDate }
        if isRetroactive || calendar.startOfDay(for: recordDate) == recordDate { return recordDate }
        return attributedMoment(recordDate, dayEndMinutes: dayEndMinutes)
    }

    /// 归属到 [firstDay, lastDay] 这些日子的记录，在真实时间轴（SQL `date` 字段）上的超集窗口：
    /// 实时记录最晚可写到 lastDay 次日的结算时刻。SQL 按此窗口取超集，再用归属函数在内存精确判定。
    static func rawFetchWindow(
        firstDay: Date,
        lastDay: Date,
        dayEndMinutes: Int,
        calendar: Calendar
    ) -> (start: Date, end: Date) {
        let dayAfterLast = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastDay)) ?? lastDay
        let end = dayAfterLast.addingTimeInterval(TimeInterval(dayEndMinutes) * 60)
        return (calendar.startOfDay(for: firstDay), end)
    }

    /// 结算时间的展示文本（如「8:00」）
    static func displayText(hour: Int, minute: Int) -> String {
        String(format: "%d:%02d", hour, minute)
    }
}
