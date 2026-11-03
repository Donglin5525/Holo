import SwiftUI

/// 图标操作共用 44pt 热区、可访问名称与业务色，视觉图标仍保持 16pt。
struct HoloIconButton: View {
    let systemName: String
    let title: LocalizedStringKey
    var showsSurface = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.holoToolText)
                .frame(width: 44, height: 44)
                .background(showsSurface ? Color.holoToolSurface : Color.clear, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(HoloPressStyle())
        .accessibilityLabel(Text(title))
    }
}
