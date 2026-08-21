//
//  HoloWidgetChrome.swift
//  HoloWidgets
//
//  品牌有机风设计语言（日光暖沙 / 暮色发光）：
//  全部 8 个小组件共享的壳层、图形与零件。
//

import SwiftUI
import WidgetKit

// MARK: - Brand Tokens

enum HoloWidgetBrand {
    // 壳层底色
    static let background = Color(red: 0.988, green: 0.976, blue: 0.945)
    static let backgroundEnd = Color(red: 0.965, green: 0.929, blue: 0.867)
    static let darkBackgroundTop = Color(red: 0.075, green: 0.106, blue: 0.090)
    static let darkBackgroundBottom = Color(red: 0.047, green: 0.067, blue: 0.055)

    // 卡片
    static let card = Color.white.opacity(0.66)
    static let cardStrong = Color.white.opacity(0.85)
    static let cardOnDark = Color.white.opacity(0.10)

    // 品牌橙
    static let primary = Color(red: 244 / 255, green: 109 / 255, blue: 56 / 255)
    static let primaryOnDark = Color(red: 1.0, green: 132 / 255, blue: 82 / 255)
    static let primaryLight = Color(red: 254 / 255, green: 215 / 255, blue: 170 / 255)
    static let primaryDark = Color(red: 234 / 255, green: 88 / 255, blue: 12 / 255)

    // 域色：快捷入口/优先级点等按功能分色
    static let green = Color(red: 22 / 255, green: 163 / 255, blue: 74 / 255)
    static let greenOnDark = Color(red: 74 / 255, green: 222 / 255, blue: 128 / 255)
    static let purple = Color(red: 124 / 255, green: 92 / 255, blue: 252 / 255)
    static let purpleOnDark = Color(red: 167 / 255, green: 139 / 255, blue: 250 / 255)
    static let blue = Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255)
    static let blueOnDark = Color(red: 147 / 255, green: 197 / 255, blue: 253 / 255)
    static let rose = Color(red: 244 / 255, green: 63 / 255, blue: 94 / 255)
    static let roseOnDark = Color(red: 251 / 255, green: 113 / 255, blue: 133 / 255)

    // 文字
    static let textPrimary = Color(red: 0.2, green: 0.188, blue: 0.168)
    static let textPrimaryOnDark = Color.white.opacity(0.95)
    static let textSecondary = Color(red: 0.545, green: 0.514, blue: 0.471)
    static let textSecondaryOnDark = Color.white.opacity(0.62)

    static let success = Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255)
    static let successOnDark = Color(red: 74 / 255, green: 222 / 255, blue: 128 / 255)
    static let error = Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255)
    static let progressTrackOnDark = Color.white.opacity(0.15)

    static func card(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? cardOnDark : card
    }

    static func cardStrong(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.15) : cardStrong
    }

    static func hairline(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.11) : Color(red: 0.573, green: 0.439, blue: 0.251).opacity(0.16)
    }

    static func primary(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? primaryOnDark : primary
    }

    static func primarySubtle(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? primaryOnDark.opacity(0.20) : primaryLight.opacity(0.38)
    }

    static func success(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? successOnDark : success
    }

    static func domainGreen(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? greenOnDark : green
    }

    static func domainPurple(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? purpleOnDark : purple
    }

    static func domainBlue(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? blueOnDark : blue
    }

    static func domainRose(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? roseOnDark : rose
    }

    static func textPrimary(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? textPrimaryOnDark : textPrimary
    }

    static func textSecondary(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? textSecondaryOnDark : textSecondary
    }

    static func progressTrack(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? progressTrackOnDark : primaryLight.opacity(0.45)
    }

    /// #RRGGBB → Color（账本分类色用；解析失败回退品牌橙）
    static func color(fromHex hex: String, colorScheme: ColorScheme) -> Color {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.hasPrefix("#") { sanitized.removeFirst() }
        guard sanitized.count == 6,
              let value = UInt64(sanitized, radix: 16) else {
            return primary(for: colorScheme)
        }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        return Color(red: red, green: green, blue: blue)
    }
}

// MARK: - Timeline Entry

struct HoloWidgetEntry<T>: TimelineEntry {
    let date: Date
    let value: T
    let entitlement: HoloWidgetEntitlementSnapshot
}

func widgetEntitlement(for context: TimelineProviderContext) -> HoloWidgetEntitlementSnapshot {
    if context.isPreview { return .plusPreview() }
    return HoloWidgetSnapshotStore().readEntitlement() ?? .free()
}

// MARK: - 壳层（日光暖沙 / 暮色发光）

extension View {
    func holoWidgetBackground(colorScheme: ColorScheme) -> some View {
        containerBackground(for: .widget) {
            HoloWidgetShellBackground(colorScheme: colorScheme)
        }
    }
}

private struct HoloWidgetShellBackground: View {
    let colorScheme: ColorScheme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [HoloWidgetBrand.darkBackgroundTop, HoloWidgetBrand.darkBackgroundBottom]
                    : [HoloWidgetBrand.background, HoloWidgetBrand.backgroundEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // 右上暖光晕
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            colorScheme == .dark
                                ? HoloWidgetBrand.primaryOnDark.opacity(0.20)
                                : Color(red: 1.0, green: 0.78, blue: 0.55).opacity(0.55),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 150
                    )
                )
                .frame(width: 300, height: 300)
                .offset(x: 80, y: -110)

            // 左下橙呼吸
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            colorScheme == .dark
                                ? HoloWidgetBrand.purpleOnDark.opacity(0.10)
                                : HoloWidgetBrand.primary.opacity(0.08),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 110
                    )
                )
                .frame(width: 220, height: 220)
                .offset(x: -260, y: 190)

            // 右下有机斑点：远看是留白，近看有形状
            OrganicBlobShape()
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(0.05)
                        : HoloWidgetBrand.primary.opacity(0.10)
                )
                .frame(width: 132, height: 120)
                .offset(x: 34, y: 48)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(HoloWidgetBrand.hairline(for: colorScheme), lineWidth: 1)
        )
    }
}

/// 有机斑点：一颗不完美的圆，Holo 的签名形状
struct OrganicBlobShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.width * x, y: rect.height * y)
        }

        var path = Path()
        path.move(to: point(0.52, 0.06))
        path.addCurve(to: point(0.89, 0.21), control1: point(0.66, 0.03), control2: point(0.83, 0.09))
        path.addCurve(to: point(0.95, 0.63), control1: point(0.97, 0.34), control2: point(0.99, 0.50))
        path.addCurve(to: point(0.60, 0.94), control1: point(0.90, 0.79), control2: point(0.75, 0.92))
        path.addCurve(to: point(0.17, 0.78), control1: point(0.40, 0.97), control2: point(0.25, 0.91))
        path.addCurve(to: point(0.05, 0.35), control1: point(0.07, 0.66), control2: point(0.02, 0.49))
        path.addCurve(to: point(0.52, 0.06), control1: point(0.09, 0.19), control2: point(0.32, 0.09))
        path.closeSubpath()
        return path
    }
}

/// 语音光球的波浪圆环（沿用的有机轮廓线）
struct OrganicWaveShape: Shape {
    let phase: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let steps = 120

        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let angle = t * 2 * .pi
            let wave = sin(angle * 4 + phase) * 0.08 + cos(angle * 3 - phase) * 0.055
            let radiusX = rect.width * 0.38 * (1 + wave)
            let radiusY = rect.height * 0.36 * (1 - wave * 0.65)
            let point = CGPoint(
                x: center.x + CGFloat(cos(angle) * radiusX),
                y: center.y + CGFloat(sin(angle) * radiusY)
            )

            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        path.closeSubpath()
        return path
    }
}

// MARK: - 罗盘圆环

/// 进度圆环；可选「时间流逝」标记点（白点带描边，压在弧上）
struct HoloWidgetRingGauge: View {
    /// 0...1
    let progress: Double
    let lineWidth: CGFloat
    let trackColor: Color
    let progressColor: Color
    var markerFraction: Double?
    var markerFill: Color = .white

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = (side - lineWidth) / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let clamped = min(max(progress, 0), 1)

            ZStack {
                Circle()
                    .stroke(trackColor, lineWidth: lineWidth)

                if clamped > 0.004 {
                    Circle()
                        .trim(from: 0, to: clamped)
                        .stroke(
                            progressColor,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }

                if let fraction = markerFraction {
                    let angle = min(max(fraction, 0), 1) * 2 * .pi - .pi / 2
                    Circle()
                        .fill(markerFill)
                        .frame(width: lineWidth * 0.66, height: lineWidth * 0.66)
                        .overlay(
                            Circle().strokeBorder(trackColor, lineWidth: lineWidth * 0.18)
                        )
                        .position(
                            x: center.x + radius * CGFloat(cos(angle)),
                            y: center.y + radius * CGFloat(sin(angle))
                        )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// 270° 仪表弧（目标进度用）
struct HoloWidgetSpeedometerGauge: View {
    /// 0...1
    let progress: Double
    let lineWidth: CGFloat
    let trackColor: Color
    let progressColor: Color

    var body: some View {
        let clamped = min(max(progress, 0), 1)
        return ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(trackColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))

            if clamped > 0.004 {
                Circle()
                    .trim(from: 0, to: 0.75 * clamped)
                    .stroke(progressColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(135))
            }
        }
    }
}

// MARK: - 锁定态（非 Plus）

struct HoloLockedWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Link(destination: URL(string: "holo://ai")!) {
            VStack(spacing: family == .systemSmall ? 9 : 11) {
                ZStack {
                    OrganicWaveShape(phase: 0.4)
                        .stroke(
                            HoloWidgetBrand.primary(for: colorScheme).opacity(0.35),
                            lineWidth: 1.2
                        )
                    Circle()
                        .fill(HoloWidgetBrand.primarySubtle(for: colorScheme))
                    Image(systemName: "lock.fill")
                        .font(.system(size: family == .systemSmall ? 17 : 20, weight: .semibold))
                        .foregroundStyle(HoloWidgetBrand.primary(for: colorScheme))
                }
                .frame(width: family == .systemSmall ? 46 : 52, height: family == .systemSmall ? 46 : 52)

                Text("Holo Plus 小组件")
                    .font(.system(size: family == .systemSmall ? 13 : 15, weight: .semibold))
                    .foregroundStyle(HoloWidgetBrand.textPrimary(for: colorScheme))
                Text("打开 Holo 升级后使用")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(HoloWidgetBrand.textSecondary(for: colorScheme))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(14)
        }
    }
}

// MARK: - 图标（emoji / SF Symbol 双轨）

enum HoloWidgetIconText {
    /// 与 App 内图标存储同口径：非 ASCII 视为 emoji，其余按 SF Symbol 渲染
    @ViewBuilder
    static func icon(_ name: String, size: CGFloat) -> some View {
        let isEmoji = name.unicodeScalars.contains { !$0.isASCII }
        if isEmoji {
            Text(name)
                .font(.system(size: size))
        } else {
            Image(systemName: name)
                .font(.system(size: size * 0.86, weight: .semibold))
        }
    }
}

// MARK: - 优先级色点

enum HoloWidgetPriorityDot {
    /// 3=紧急 2=高 1=中 0=低
    static func color(priority: Int, colorScheme: ColorScheme) -> Color {
        switch priority {
        case 3: return HoloWidgetBrand.domainRose(for: colorScheme)
        case 2: return HoloWidgetBrand.primary(for: colorScheme)
        case 1: return HoloWidgetBrand.domainBlue(for: colorScheme)
        default: return HoloWidgetBrand.textSecondary(for: colorScheme)
        }
    }
}

// MARK: - 文案格式化

extension Double {
    var currencyText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "¥"
        formatter.maximumFractionDigits = self.rounded() == self ? 0 : 2
        return formatter.string(from: NSNumber(value: self)) ?? "¥0"
    }
}

extension Date {
    var widgetDateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter.string(from: self)
    }
}
