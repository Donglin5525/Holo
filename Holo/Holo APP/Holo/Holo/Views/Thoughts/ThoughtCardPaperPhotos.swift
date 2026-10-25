import SwiftUI

/// 列表保持摘要密度，胶片取一张横幅，其余模板沿用可横滑的图片预览。
struct ThoughtCardPaperPhotos: View {
    let sources: [ThoughtPaperPhotoSource]
    let style: ThoughtStyle
    let onOpen: (UUID) -> Void
    @State private var availableWidth: CGFloat = 1

    var body: some View {
        Group {
            if style == .film {
                ThoughtPaperPhotos(sources: Array(sources.prefix(1)), style: style, width: availableWidth, compact: true, onOpen: onOpen)
                    .overlay(alignment: .bottomTrailing) {
                        if sources.count > 1 {
                            Text(String(format: String(localized: "%d 张"), sources.count))
                                .font(.holoLabel)
                                .padding(HoloSpacing.xs)
                                .background(Color.holoToolSurface, in: Capsule())
                                .padding(HoloSpacing.xs)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { max(1, $0.size.width) } action: { availableWidth = $0 }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HoloSpacing.sm) {
                        ForEach(sources) { source in
                            ThoughtPaperPhotos(sources: [source], style: style, width: style == .post ? 96 : 80, compact: true, onOpen: onOpen)
                        }
                    }
                }
            }
        }
    }
}
