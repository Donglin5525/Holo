import SwiftUI

struct MemoryConstellationCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let summary: MemoryConstellationSummary
    let signals: [MemoryConstellationSignal]
    let snippets: [MemoryStorySnippet]
    let isRefreshing: Bool
    let lastUpdatedAt: Date?
    let onRefresh: () -> Void

    @State private var selectedModule: MemoryConstellationModule = .health

    private let positions: [MemoryConstellationModule: CGPoint] = [
        .habit: CGPoint(x: 0.22, y: 0.28),
        .finance: CGPoint(x: 0.76, y: 0.24),
        .task: CGPoint(x: 0.66, y: 0.66),
        .thought: CGPoint(x: 0.30, y: 0.72),
        .health: CGPoint(x: 0.50, y: 0.48)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            header
            constellationStage
            selectedSignalPanel

            if !snippets.isEmpty {
                snippetsSection
            }
        }
        .padding(HoloSpacing.lg)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(cardBorder, lineWidth: 1)
        )
        .onAppear {
            if signals.contains(where: { $0.module == selectedModule }) == false,
               let first = signals.first {
                selectedModule = first.module
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(accentColor)

                Text("生活星图")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)

                Spacer()

                Button {
                    onRefresh()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(isRefreshing ? 90 : 0))

                        Text(isRefreshing ? "更新中" : "更新")
                            .font(.holoTinyLabel)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(isRefreshing ? .holoTextPlaceholder : accentColor)
                    .padding(.horizontal, HoloSpacing.sm)
                    .frame(height: 28)
                    .background(accentColor.opacity(colorScheme == .dark ? 0.16 : 0.10))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(accentColor.opacity(colorScheme == .dark ? 0.28 : 0.20), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
            }

            Text(refreshStatusText)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextPlaceholder)
                .lineLimit(1)

            Text(summary.title)
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(summary.body)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var constellationStage: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    drawConstellationLines(context: &context, size: size)
                }

                ForEach(signals) { signal in
                    signalButton(signal)
                        .position(point(for: signal.module, in: proxy.size))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(stageBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(stageBorder, lineWidth: 1)
            )
        }
        .frame(height: 238)
    }

    private func signalButton(_ signal: MemoryConstellationSignal) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                selectedModule = signal.module
            }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(signalFill(signal))
                        .frame(width: signal.module == .health ? 54 : 46, height: signal.module == .health ? 54 : 46)
                        .overlay(
                            Circle()
                                .stroke(signalStroke(signal), style: StrokeStyle(lineWidth: 1.5, dash: signal.isDashed ? [4, 4] : []))
                        )
                        .shadow(color: signalGlow(signal), radius: selectedModule == signal.module ? 10 : 4)

                    Image(systemName: signal.module.iconName)
                        .font(.system(size: signal.module == .health ? 20 : 17, weight: .semibold))
                        .foregroundColor(signalIcon(signal))
                }

                Text(signal.title)
                    .font(.holoTinyLabel)
                    .fontWeight(selectedModule == signal.module ? .semibold : .regular)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
            }
            .frame(width: 72, height: 78)
        }
        .buttonStyle(.plain)
    }

    private var selectedSignalPanel: some View {
        let signal = signals.first { $0.module == selectedModule } ?? signals.first

        return VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: signal?.module.iconName ?? "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accentColor)

                Text(signal?.summary ?? "正在整理")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(2)

                Spacer()
            }

            Text(signal?.detail ?? "Holo 正在把这一段生活信号整理成更清楚的解释。")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoGlassBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private var snippetsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("可回看的片段")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            VStack(spacing: HoloSpacing.xs) {
                ForEach(snippets.prefix(3)) { snippet in
                    HStack(spacing: HoloSpacing.sm) {
                        Image(systemName: snippet.iconName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(accentColor)
                            .frame(width: 28, height: 28)
                            .background(accentColor.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(snippet.title)
                                .font(.holoCaption)
                                .foregroundColor(.holoTextPrimary)
                                .lineLimit(2)

                            if let subtitle = snippet.subtitle {
                                Text(subtitle)
                                    .font(.holoTinyLabel)
                                    .foregroundColor(.holoTextPlaceholder)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func drawConstellationLines(context: inout GraphicsContext, size: CGSize) {
        let ordered: [MemoryConstellationModule] = [.habit, .finance, .task, .health, .thought, .habit]
        var path = Path()

        for (index, module) in ordered.enumerated() {
            let point = point(for: module, in: size)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        context.stroke(
            path,
            with: .color(lineColor),
            style: StrokeStyle(lineWidth: 1, dash: colorScheme == .dark ? [5, 6] : [3, 5])
        )
    }

    private func point(for module: MemoryConstellationModule, in size: CGSize) -> CGPoint {
        let normalized = positions[module] ?? CGPoint(x: 0.5, y: 0.5)
        return CGPoint(x: size.width * normalized.x, y: size.height * normalized.y)
    }

    private var accentColor: Color {
        colorScheme == .dark ? Color.cyan : Color.holoPrimary
    }

    private var refreshStatusText: String {
        if isRefreshing {
            return "正在根据最新记录整理"
        }

        if let lastUpdatedAt {
            return "5 个信号 · \(Self.relativeUpdateText(for: lastUpdatedAt))"
        }

        return "5 个信号 · 进入时自动整理"
    }

    private static func relativeUpdateText(for date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)

        if elapsed < 60 {
            return "刚刚更新"
        }

        if elapsed < 3600 {
            return "\(max(Int(elapsed / 60), 1)) 分钟前更新"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M.d HH:mm 更新"
        return formatter.string(from: date)
    }

    private var cardBackground: some ShapeStyle {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.05, green: 0.07, blue: 0.13), Color.holoCardBackground]
                : [Color(red: 1.0, green: 0.98, blue: 0.93), Color.holoCardBackground],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var cardBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.holoBorder.opacity(0.65)
    }

    private var stageBackground: some ShapeStyle {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.04, green: 0.06, blue: 0.11), Color(red: 0.08, green: 0.10, blue: 0.18)]
                : [Color.white.opacity(0.72), Color(red: 0.96, green: 0.92, blue: 0.84).opacity(0.66)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var stageBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.holoBorder.opacity(0.45)
    }

    private var lineColor: Color {
        colorScheme == .dark ? Color.cyan.opacity(0.42) : Color.holoPrimary.opacity(0.36)
    }

    private func signalFill(_ signal: MemoryConstellationSignal) -> Color {
        if selectedModule == signal.module {
            return accentColor.opacity(colorScheme == .dark ? 0.34 : 0.20)
        }
        return colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.82)
    }

    private func signalStroke(_ signal: MemoryConstellationSignal) -> Color {
        if selectedModule == signal.module {
            return accentColor.opacity(0.75)
        }
        return signal.isDashed ? Color.holoTextPlaceholder.opacity(0.55) : accentColor.opacity(0.28)
    }

    private func signalGlow(_ signal: MemoryConstellationSignal) -> Color {
        selectedModule == signal.module ? accentColor.opacity(0.25) : Color.clear
    }

    private func signalIcon(_ signal: MemoryConstellationSignal) -> Color {
        if signal.level == .critical {
            return .holoError
        }
        if signal.level == .warning {
            return colorScheme == .dark ? Color.orange.opacity(0.92) : Color.holoPrimary
        }
        return accentColor
    }
}
