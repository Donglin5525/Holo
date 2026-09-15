//
//  WorkoutSessionListCard.swift
//  Holo
//
//  当日运动会话列表卡（运动详情页）：一行一次运动（类型/时间段/时长/距离/能量），
//  点击行进入单次运动明细弹层（WorkoutSessionDetailSheet）。
//

import SwiftUI
import HealthKit

// MARK: - WorkoutSessionListCard

struct WorkoutSessionListCard: View {
    let sessions: [WorkoutSessionData]
    let onSelect: (WorkoutSessionData) -> Void

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack {
                Text("今日运动")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Text(String(localized: "\(sessions.count) 次训练"))
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            ForEach(sessions) { session in
                sessionRow(session)
            }
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }

    private func sessionRow(_ session: WorkoutSessionData) -> some View {
        Button {
            onSelect(session)
        } label: {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: session.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoChart3)
                    .frame(width: 36, height: 36)
                    .background(Color.holoChart3.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.localizedName)
                        .font(.holoLabel)
                        .foregroundColor(.holoTextPrimary)

                    Text("\(Self.timeFormatter.string(from: session.start))–\(Self.timeFormatter.string(from: session.end))")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(localized: "\(Int(session.minutes.rounded())) 分钟"))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.holoTextPrimary)

                    Text(sessionSummary(session))
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.holoTextSecondary.opacity(0.5))
            }
            .padding(HoloSpacing.sm)
            .background(Color.holoNestedCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 行尾摘要：有距离给「X.X 公里」、无距离给卡路里、都缺省只显示时长
    private func sessionSummary(_ session: WorkoutSessionData) -> String {
        if let meters = session.distanceMeters {
            return String(localized: "\(String(format: "%.1f", meters / 1000)) 公里")
        }
        if let kcal = session.kilocalories {
            return String(localized: "\(Int(kcal.rounded())) 千卡")
        }
        return session.sourceName
    }
}

#Preview {
    let calendar = Calendar.current
    let day = calendar.startOfDay(for: Date())
    return WorkoutSessionListCard(
        sessions: [
            WorkoutSessionData(
                id: UUID(), start: day.addingTimeInterval(8 * 3600), end: day.addingTimeInterval(8 * 3600 + 42 * 60),
                activityTypeRaw: HKWorkoutActivityType.running.rawValue, typeName: "跑步",
                distanceMeters: 6800, kilocalories: 380, averageHeartRate: 152, maxHeartRate: 171, sourceName: "Apple Watch"
            ),
            WorkoutSessionData(
                id: UUID(), start: day.addingTimeInterval(19 * 3600), end: day.addingTimeInterval(19 * 3600 + 30 * 60),
                activityTypeRaw: HKWorkoutActivityType.traditionalStrengthTraining.rawValue, typeName: "力量训练",
                distanceMeters: nil, kilocalories: 210, averageHeartRate: 128, maxHeartRate: 155, sourceName: "Apple Watch"
            )
        ],
        onSelect: { _ in }
    )
    .padding()
    .background(Color.holoBackground)
}
