import SwiftUI

/// 一次实际记录的回执，随对话排版。
struct ChatRecordReceiptRow: View {
    let title: String
    let value: String
    var isStatus = false

    var body: some View {
        HoloCardlessRow(showsDivider: false, verticalPadding: HoloSpacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: HoloSpacing.sm) {
                    titleText.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: HoloSpacing.sm)
                    valueText.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    titleText
                    valueText
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var titleText: some View {
        Text(title)
            .holoText(.body)
            .foregroundStyle(Color.holoToolText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var valueText: some View {
        Text(value)
            .holoText(.supporting)
            .fontWeight(isStatus ? .regular : .semibold)
            .monospacedDigit()
            .foregroundStyle(isStatus ? Color.holoToolTextSecondary : Color.holoToolText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
