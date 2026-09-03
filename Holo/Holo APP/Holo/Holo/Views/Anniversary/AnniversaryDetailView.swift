//
//  AnniversaryDetailView.swift
//  Holo
//
//  纪念日详情页 —— 沉浸式仪式感三态：倒数（翻牌+年度环+里程碑）/ 累计 / 当天庆祝
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
    @State private var showShare = false
    @State private var orbDrift: CGFloat = 0
    @State private var arcRotation: Double = 0

    var body: some View {
        ZStack {
            immersiveBackground

            VStack(spacing: 0) {
                topBar

                if anniversary.isToday {
                    celebrationContent
                } else {
                    ScrollView(showsIndicators: false) {
                        mainContent
                    }
                    footerArea
                }
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
        .sheet(isPresented: $showShare) {
            AnniversaryShareSheet(card: makeShareCard(), tint: themeColor)
        }
    }

    // MARK: - 沉浸背景（暮色发光 · 保留原有基因）

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

    // MARK: - 顶部栏

    private var topBar: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Button {
                showShare = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - 主内容（倒数 / 累计）

    private var mainContent: some View {
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
            .padding(.top, 8)

            // 名称 + 语义标签
            Text(anniversary.title)
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 16)

            Text(headline)
                .font(.system(size: 13))
                .foregroundColor(themeColor.opacity(0.85))
                .padding(.top, 6)

            // 翻牌数字 + 单位
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                AnniversaryFlipDigits(
                    number: anniversary.displayDays,
                    cardWidth: digitCardSize,
                    cardHeight: digitCardSize * 1.38,
                    fontSize: digitCardSize * 0.83)

                if !unitLabel.isEmpty {
                    Text(unitLabel)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            .padding(.top, 22)
            .padding(.bottom, 18)

            // 完整日期
            Text(fullDateLabel)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.42))

            // 备注
            if let note = anniversary.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            // 年度进度环（每年重复专属）
            if let progress = anniversary.yearlyCycleProgress {
                HStack(spacing: 16) {
                    AnniversaryCycleRing(progress: progress, tint: themeColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "这一年的等待已走过 \(Int((progress * 100).rounded()))%"))
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundColor(.white)
                        Text(cycleSubText)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.55))
                            .lineSpacing(3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
                .padding(.top, 20)
            }

            // 里程碑轨道
            VStack(spacing: 0) {
                AnniversaryMilestoneTrack(
                    info: anniversary.milestoneInfo,
                    tint: themeColor,
                    title: String(localized: "在一起的日子"))
                HStack {
                    Text(String(localized: "已同行 \(anniversary.totalDaysSinceStart) 天"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
            .padding(.top, 12)

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity)
    }

    /// 数字位数多时缩小卡片，避免小屏溢出
    private var digitCardSize: CGFloat {
        let count = String(anniversary.displayDays).count
        switch count {
        case ...2: return 58
        case 3: return 50
        default: return 40
        }
    }

    // MARK: - 当天庆祝态

    private var celebrationContent: some View {
        ZStack {
            // 静态彩带
            AnniversaryConfetti(tint: themeColor, count: 42)

            VStack(spacing: 0) {
                Spacer()

                Text(todayBadgeText)
                    .font(.system(size: 12.5, weight: .heavy))
                    .kerning(0.5)
                    .foregroundColor(Color(red: 0.99, green: 0.79, blue: 0.46))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.98, green: 0.57, blue: 0.24).opacity(0.14))
                            .overlay(Capsule().strokeBorder(Color(red: 0.99, green: 0.63, blue: 0.35).opacity(0.4), lineWidth: 1)))

                Text(String(localized: "\(anniversary.title)\n就是今天"))
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .padding(.top, 18)

                // 岁数 / 周年大卡
                if !celebrationBigText.isEmpty {
                    ZStack {
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .fill(LinearGradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.07)], startPoint: .top, endPoint: .bottom))
                            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 1.2))
                        VStack(spacing: 2) {
                            Text(celebrationBigText)
                                .font(.system(size: 58, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.white)
                            Text(celebrationBigUnit)
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundColor(.white.opacity(0.65))
                        }
                    }
                    .frame(width: 150, height: 150)
                    .shadow(color: themeColor.opacity(0.4), radius: 26, y: 10)
                    .padding(.top, 22)
                }

                Text(headline)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Color(red: 0.99, green: 0.79, blue: 0.46))
                    .padding(.top, 14)

                Text(wishText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))
                    .multilineTextAlignment(.center)
                    .lineSpacing(7)
                    .padding(.horizontal, 36)
                    .padding(.top, 18)

                Spacer()

                Button {
                    showShare = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "gift.fill")
                        Text(String(localized: "把祝福说出口"))
                    }
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        LinearGradient(colors: [themeColor, themeColor.darker(by: 0.25)], startPoint: .leading, endPoint: .trailing))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: themeColor.opacity(0.45), radius: 16, y: 7)
                }
                .padding(.bottom, 12)
            }
        }
    }

    private var todayBadgeText: String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("y年M月d日EEEE")
        return formatter.string(from: anniversary.repeatYearly ? anniversary.nextOccurrenceDate() : anniversary.date)
    }

    /// 当天大卡数字：生日=岁数，周年=第N年，其余不显示数字卡
    private var celebrationBigText: String {
        switch anniversary.anniversaryType {
        case .birthday:
            let n = anniversary.anniversaryNumber
            return n > 0 ? "\(n)" : ""
        default:
            return anniversary.repeatYearly && anniversary.anniversaryNumber > 0 ? "\(anniversary.anniversaryNumber)" : ""
        }
    }

    private var celebrationBigUnit: String {
        anniversary.anniversaryType == .birthday
            ? String(localized: "岁 · 生日快乐")
            : String(localized: "周年 · 快乐")
    }

    /// 当天祝福语（P0 固定模板，按类型；P2 由 HoloAI 基于记忆生成）
    private var wishText: String {
        switch anniversary.anniversaryType {
        case .birthday: return String(localized: "「愿岁岁常欢愉，年年皆胜意。\n生日快乐！」")
        case .anniversary: return String(localized: "「又一年，幸好还是我们。\n周年快乐！」")
        case .countdown: return String(localized: "「等了好久的日子，终于到了！」")
        case .milestone: return String(localized: "「这一步走了 \(anniversary.totalDaysSinceStart) 天，值得！」")
        }
    }

    // MARK: - 底部区域（非庆祝态）

    private var footerArea: some View {
        VStack(spacing: 12) {
            if !linkedTasks.isEmpty {
                Text(String(localized: "已生成 \(linkedTasks.count) 条关联任务"))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.35))
            }

            HStack(spacing: 11) {
                Button {
                    showShare = true
                } label: {
                    Text(String(localized: "分享这一天"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Button {
                    showEdit = true
                } label: {
                    Text(String(localized: "编辑"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - 分享卡

    private func makeShareCard() -> AnniversaryShareCard {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("y年M月d日")

        if anniversary.isToday {
            return AnniversaryShareCard(
                icon: anniversary.icon,
                title: anniversary.title,
                dateText: formatter.string(from: anniversary.date),
                bigText: celebrationBigText.isEmpty ? "🎉" : celebrationBigText,
                unitLine: String(localized: "就是今天 🎉"),
                wishText: wishText,
                tint: themeColor)
        }

        let mode = anniversary.displayMode
        let unit: String
        switch mode {
        case .countdown: unit = String(localized: "还有 \(anniversary.displayDays) 天")
        case .elapsed: unit = String(localized: "已经 \(anniversary.displayDays) 天")
        }
        return AnniversaryShareCard(
            icon: anniversary.icon,
            title: anniversary.title,
            dateText: formatter.string(from: anniversary.date),
            bigText: "\(anniversary.displayDays)",
            unitLine: unit,
            wishText: anniversary.note,
            tint: themeColor)
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
        case .countdown(let days): return days == 0 ? "" : String(localized: "天后")
        case .elapsed: return String(localized: "天")
        }
    }

    private var headline: String {
        let mode = anniversary.displayMode
        switch mode {
        case .countdown(let days):
            if anniversary.repeatYearly {
                let n = anniversary.anniversaryNumber + 1
                return days == 0 ? String(localized: "第 \(n) 个周年 · 今天") : String(localized: "第 \(n) 个周年")
            }
            return days == 0 ? String(localized: "就是今天") : String(localized: "距离这天还有")
        case .elapsed:
            return anniversary.repeatYearly ? String(localized: "已经走过") : String(localized: "已经过去")
        }
    }

    private var cycleSubText: String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("y年M月d日")
        return String(localized: "自上个周期 \(formatter.string(from: anniversary.previousOccurrenceDate())) 起 · 到期翻入新的一轮")
    }

    private var fullDateLabel: String {
        let formatter = DateFormatter()
        let baseDate = anniversary.repeatYearly ? anniversary.nextOccurrenceDate() : anniversary.date
        formatter.setLocalizedDateFormatFromTemplate("y年M月d日EEEE")
        var label = formatter.string(from: baseDate)
        if anniversary.isLunar {
            label += String(localized: " · 农历\(anniversary.lunarDateText)")
        } else if anniversary.repeatYearly {
            label += String(localized: " · 每年")
        }
        return label
    }
}
