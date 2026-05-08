import SwiftUI

/// 首页圆圈按钮中心图标预览 — 6 个方案对比
/// 在 Xcode Canvas 中预览，选择合适的方案后集成到 DailyKanbanEntryButton
struct DailyKanbanIconPreview: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                Text("今日看板图标方案")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 32) {
                    iconCard(title: "方案 A：日轮", subtitle: "Sun — 光芒四射的太阳") {
                        IconA_Sun()
                    }

                    iconCard(title: "方案 B：叠层", subtitle: "Layers — 重叠卡片") {
                        IconB_Layers()
                    }

                    iconCard(title: "方案 C：同心环", subtitle: "Rings — 进度环") {
                        IconC_Rings()
                    }

                    iconCard(title: "方案 D：网格", subtitle: "Grid — 看板格") {
                        IconD_Grid()
                    }

                    iconCard(title: "方案 E：指南针", subtitle: "Compass — 日程导航") {
                        IconE_Compass()
                    }

                    iconCard(title: "方案 F：脉冲", subtitle: "Pulse — 生命脉动") {
                        IconF_Pulse()
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 40)
        }
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
    }

    private func iconCard(title: String, subtitle: String, @ViewBuilder icon: () -> some View) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.996, green: 0.843, blue: 0.667),
                                Color(red: 0.957, green: 0.427, blue: 0.220),
                                Color(red: 0.918, green: 0.349, blue: 0.047)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 160, height: 160)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.4), Color.white.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 160, height: 160)
                    .opacity(0.8)

                icon()
            }

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

// MARK: - 方案 A：日轮（Sun）
/// 核心理念：太阳 = 今天，光芒 = 多维度数据
private struct IconA_Sun: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white, lineWidth: 3)
                .frame(width: 44, height: 44)

            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) * .pi / 4
                RayLine(
                    startX: cos(angle) * 28,
                    startY: sin(angle) * 28,
                    endX: cos(angle) * 38,
                    endY: sin(angle) * 38
                )
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
    }
}

// MARK: - 方案 B：叠层卡片（Layers）
/// 核心理念：重叠的卡片 = 多维看板数据层叠展示
private struct IconB_Layers: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.5), lineWidth: 2)
                .frame(width: 36, height: 44)
                .rotationEffect(.degrees(-12))
                .offset(x: -12, y: 8)

            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.7), lineWidth: 2)
                .frame(width: 36, height: 44)
                .rotationEffect(.degrees(0))
                .offset(x: 0, y: 0)

            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white, lineWidth: 2)
                .frame(width: 36, height: 44)
                .rotationEffect(.degrees(12))
                .offset(x: 12, y: -8)
        }
    }
}

// MARK: - 方案 C：同心环（Rings）
/// 核心理念：三个进度环 = 习惯/任务/健康 三大维度
private struct IconC_Rings: View {
    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 52, height: 52)

            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 40, height: 40)

            Circle()
                .trim(from: 0.3, to: 0.9)
                .stroke(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 28, height: 28)
        }
    }
}

// MARK: - 方案 D：网格看板（Grid）
/// 核心理念：2x2 网格 = 看板布局，每个格子代表一个维度
private struct IconD_Grid: View {
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                gridCell(opacity: 0.9, systemName: "checkmark")
                gridCell(opacity: 0.7, systemName: "flame.fill")
            }

            HStack(spacing: 8) {
                gridCell(opacity: 0.5, systemName: "heart.fill")
                gridCell(opacity: 0.3, systemName: "face.smiling")
            }
        }
    }

    private func gridCell(opacity: Double, systemName: String) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.white.opacity(opacity))
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 0.957, green: 0.427, blue: 0.220))
            )
    }
}

// MARK: - 方案 E：指南针（Compass）
/// 核心理念：指南针 = 每日导航，指向今天最重要的方向
private struct IconE_Compass: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: 2)
                .frame(width: 52, height: 52)

            ForEach(0..<4, id: \.self) { i in
                let angle = Double(i) * .pi / 2
                let isMain = i == 0
                RayLine(
                    startX: cos(angle) * 22,
                    startY: sin(angle) * 22,
                    endX: cos(angle) * (isMain ? 28 : 25),
                    endY: sin(angle) * (isMain ? 28 : 25)
                )
                .stroke(
                    Color.white.opacity(isMain ? 0.9 : 0.5),
                    style: StrokeStyle(lineWidth: isMain ? 2.5 : 1.5, lineCap: .round)
                )
            }

            TriangleShape()
                .fill(Color.white)
                .frame(width: 12, height: 18)
                .offset(y: -6)

            TriangleShape()
                .fill(Color.white.opacity(0.4))
                .frame(width: 12, height: 18)
                .rotationEffect(.degrees(180))
                .offset(y: 6)

            Circle()
                .fill(Color.white)
                .frame(width: 6, height: 6)
        }
    }
}

// MARK: - 方案 F：脉冲波形（Pulse）
/// 核心理念：心跳脉冲 = 活力、动态、每日脉动
private struct IconF_Pulse: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 1.5)
                .frame(width: 50, height: 50)

            PulseLineShape()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: 56, height: 28)

            Circle()
                .fill(Color.white)
                .frame(width: 5, height: 5)
                .offset(x: 14, y: 0)
        }
    }
}

// MARK: - Helper Shapes

private struct RayLine: Shape {
    let startX: CGFloat
    let startY: CGFloat
    let endX: CGFloat
    let endY: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX + startX, y: rect.midY + startY))
        path.addLine(to: CGPoint(x: rect.midX + endX, y: rect.midY + endY))
        return path
    }
}

private struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct PulseLineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let midY = rect.midY

        path.move(to: CGPoint(x: rect.minX, y: midY))
        path.addLine(to: CGPoint(x: w * 0.2, y: midY))
        path.addLine(to: CGPoint(x: w * 0.3, y: midY - h * 0.7))
        path.addLine(to: CGPoint(x: w * 0.4, y: midY + h * 0.5))
        path.addLine(to: CGPoint(x: w * 0.5, y: midY))
        path.addLine(to: CGPoint(x: w * 0.6, y: midY - h * 0.4))
        path.addLine(to: CGPoint(x: w * 0.7, y: midY + h * 0.3))
        path.addLine(to: CGPoint(x: w * 0.75, y: midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: midY))

        return path
    }
}

#Preview {
    DailyKanbanIconPreview()
}
