//
//  AnniversaryDetailView.swift
//  Holo
//
//  纪念日详情页 —— 沉浸式仪式感
//

import SwiftUI
import CoreData

struct AnniversaryDetailView: View {

    // @ObservedObject：NSManagedObject 属性变化自动驱动刷新，
    // 编辑 sheet 保存后详情页能立即反映新数据
    @ObservedObject var anniversary: Anniversary
    var onBack: () -> Void

    private var repository: AnniversaryRepository { AnniversaryRepository.shared }
    @State private var showEdit = false
    @State private var orbDrift: CGFloat = 0
    @State private var arcRotation: Double = 0
    @State private var numberRevealed = false

    var body: some View {
        ZStack {
            immersiveBackground

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerContent
                Spacer()
                footerArea
            }
            .padding(.horizontal, 24)
        }
        .preferredColorScheme(.dark)
        .navigationBarHidden(true)
        .swipeBackToDismiss(ignoreNavigationStack: true) {
            onBack()
        }
        .onAppear {
            HapticManager.medium()
            withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) { orbDrift = 1.0 }
            withAnimation(.linear(duration: 60).repeatForever(autoreverses: false)) { arcRotation = 360 }
            withAnimation(.easeOut(duration: 0.9).delay(0.2)) { numberRevealed = true }
        }
        // 纪念日被删除（如在编辑表单里删除）时自动关闭详情页，避免展示已删数据
        .onReceive(NotificationCenter.default.publisher(for: .anniversaryDataDidChange)) { _ in
            if anniversary.isSoftDeleted || anniversary.isArchived {
                onBack()
            }
        }
        .sheet(isPresented: $showEdit) {
            AddAnniversarySheet(editingAnniversary: anniversary)
        }
    }

    // MARK: - 沉浸背景

    private var immersiveBackground: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.08).ignoresSafeArea()

            // 主光晕
            Circle()
                .fill(RadialGradient(
                    colors: [themeColor.opacity(0.20), themeColor.opacity(0)],
                    center: .center, startRadius: 0, endRadius: 230))
                .frame(width: 460, height: 460)
                .offset(y: orbDrift * 8)
                .blur(radius: 70)

            // 装饰弧线
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(themeColor.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .frame(width: 330, height: 330)
                .rotationEffect(.degrees(-30 + arcRotation * 0.3))

            Circle()
                .trim(from: 0.4, to: 0.7)
                .stroke(themeColor.opacity(0.10), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .frame(width: 300, height: 300)
                .rotationEffect(.degrees(60 + arcRotation * 0.5))
        }
        .allowsHitTesting(false)
    }

    // MARK: - 顶部栏（与任务详情页一致的触控区域）

    private var topBar: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 44, height: 44)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - 中心内容

    private var centerContent: some View {
        VStack(spacing: 0) {
            // 类型图标（存量 SF Symbol / 新默认 emoji 兼容）
            Group {
                if EmojiCatalog.isEmojiIcon(anniversary.icon) {
                    Text(anniversary.icon)
                        .font(.system(size: 42))
                } else {
                    Image(systemName: anniversary.icon)
                        .font(.system(size: 34, weight: .light))
                        .foregroundColor(.white.opacity(0.85))
                }
            }

            // 名称
            Text(anniversary.title)
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 18)

            // 语义标签
            Text(headline)
                .font(.system(size: 13))
                .foregroundColor(themeColor.opacity(0.8))
                .padding(.top, 6)

            // 超大天数 + 单位
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(anniversary.displayDays)")
                    .font(.system(size: 84, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .opacity(numberRevealed ? 1 : 0)
                    .scaleEffect(numberRevealed ? 1 : 0.7)
                if !unitLabel.isEmpty {
                    Text(unitLabel)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            .padding(.top, 26)
            .padding(.bottom, 26)

            // 完整日期
            Text(fullDateLabel)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.42))

            // 备注
            if let note = anniversary.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 底部区域

    private var footerArea: some View {
        VStack(spacing: 12) {
            if !linkedTasks.isEmpty {
                Text("已生成 \(linkedTasks.count) 条关联任务")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.35))
            }

            Button {
                showEdit = true
            } label: {
                Text("编辑")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - 数据

    private var linkedTasks: [TodoTask] {
        let request = TodoTask.fetchRequest()
        request.predicate = NSPredicate(format: "sourceAnniversaryId == %@ AND deletedFlag == NO", anniversary.id as CVarArg)
        return (try? repository.context.fetch(request)) ?? []
    }

    // MARK: - 计算

    private var themeColor: Color {
        Color(hex: anniversary.color)
    }

    private var unitLabel: String {
        let mode = anniversary.displayMode
        switch mode {
        case .countdown(let days): return days == 0 ? "" : "天后"
        case .elapsed: return "天前"
        }
    }

    private var headline: String {
        let mode = anniversary.displayMode
        switch mode {
        case .countdown(let days):
            if anniversary.repeatYearly {
                let n = anniversary.anniversaryNumber + 1
                return days == 0 ? "第 \(n) 个周年 · 今天" : "第 \(n) 个周年"
            }
            return days == 0 ? "就是今天" : "距离这天还有"
        case .elapsed:
            return anniversary.repeatYearly ? "已经走过" : "已经过去"
        }
    }

    private var fullDateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        let baseDate = anniversary.repeatYearly ? anniversary.nextOccurrenceDate() : anniversary.date
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        var label = formatter.string(from: baseDate)
        if anniversary.repeatYearly { label += " · 每年" }
        return label
    }
}
