import SwiftUI

struct ThoughtCalendarMasthead: View {
    @Environment(\.sizeCategory) private var sizeCategory
    let date: Date

    var body: some View {
        Group {
            if sizeCategory.isAccessibilityCategory {
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    HStack {
                        Text(ThoughtPaperDate.text(date, format: "yyyy.MM"))
                        Spacer(minLength: HoloSpacing.sm)
                        Text(ThoughtPaperDate.text(date, format: "EEE"))
                    }
                    day
                    Text(ThoughtPaperDate.text(date, format: "HH:mm"))
                }
            } else {
                HStack(alignment: .center, spacing: HoloSpacing.lg) {
                    VStack(spacing: HoloSpacing.xs) {
                        Text(ThoughtPaperDate.text(date, format: "yyyy"))
                        Text(ThoughtPaperDate.text(date, format: "M月"))
                    }
                    day
                    VStack(spacing: HoloSpacing.xs) {
                        Text(ThoughtPaperDate.text(date, format: "EEE"))
                        Text(ThoughtPaperDate.text(date, format: "HH:mm"))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, HoloSpacing.md)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ThoughtStyle.calendar.accent.opacity(0.25)).frame(height: 0.5)
        }
    }

    private var day: some View {
        Text(ThoughtPaperDate.text(date, format: "d"))
            .font(ThoughtTypography.font(.serif, size: ThoughtPaperMetrics.calendarSize, relativeTo: .largeTitle))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}
