//
//  HomeView.swift
//  Holo
//
//  首页视图 - Holo 应用的主界面
//  包含问候语、日程提醒、中央语音助手、功能入口和底部导航
//

import SwiftUI

/// 首页视图
/// 设计布局：
/// - Header: 顶部问候语和用户头像
/// - Main: 中央语音助手 + 五角形功能入口按钮（支持长按拖拽排序）
/// - Nav: 底部浮动导航栏
struct HomeView: View {
    
    // MARK: - Properties
    
    /// 用户昵称（后续从用户数据中获取）
    @State private var userName: String = "东林"
    
    /// 当前日程提醒
    @State private var currentSchedule: String = "10:00 • 团队同步会议"
    
    /// 当前选中的导航标签
    @State private var selectedTab: BottomNavBar.TabItem = .ai
    
    /// 是否显示财务页面
    @State private var showFinanceView: Bool = false
    
    /// 是否显示习惯页面
    @State private var showHabitsView: Bool = false

    /// 是否显示设置页面
    @State private var showSettingsView: Bool = false
    
    // MARK: - 五角形功能按钮拖拽排序状态
    
    /// 图标配置仓库（负责持久化）
    @StateObject private var iconRepository = HomeIconConfigRepository.shared
    
    /// 功能按钮配置数组（顺序决定五角形位置：顶部 -> 右上 -> 右下 -> 左下 -> 左上）
    /// 从 iconRepository 加载并按 sortOrder 排序
    @State private var featureItems: [FeatureButtonConfig] = []
    
    /// 当前正在拖拽的按钮配置
    @State private var draggingItem: FeatureButtonConfig? = nil
    
    /// 拖拽偏移量
    @State private var dragOffset: CGSize = .zero
    
    /// 拖拽起始位置索引
    @State private var draggingFromIndex: Int? = nil
    
    /// 是否正在进行长按手势（防止点击误触发）
    @GestureState private var isLongPressing: Bool = false
    
    // MARK: - 五角形布局常量
    
    /// 五角形半径（距离语音按钮中心的距离，需大于语音按钮 192pt/2 + 按钮宽度 56pt/2 = 124pt）
    private let pentagonRadius: CGFloat = 155
    
    /// 五角形区域的总高度
    private let pentagonAreaHeight: CGFloat = 420
    
    // MARK: - Body
    
    var body: some View {
        ZStack {
            // 背景色
            Color.holoBackground
                .ignoresSafeArea()
            
            // 装饰元素
            backgroundDecorations
            
            // 主内容
            VStack(spacing: 0) {
                // 顶部 Header
                headerView
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.xxl)
                    .padding(.bottom, HoloSpacing.md)
                
                // 日程提醒 - 位于 Header 下方，语音按钮上方
                scheduleReminder
                
                Spacer()
                
                // 中央主内容区域（语音按钮 + 功能入口）
                mainContent
                
                Spacer()
                
                // 底部导航栏
                BottomNavBar(selectedTab: $selectedTab)
            }
        }
        // 将 fullScreenCover 挂在整个 HomeView 上，更稳定
        .fullScreenCover(isPresented: $showFinanceView) {
            FinanceView()
                .preferredColorScheme(DarkModeManager.shared.colorScheme)
        }
        .fullScreenCover(isPresented: $showHabitsView) {
            HabitsView()
                .preferredColorScheme(DarkModeManager.shared.colorScheme)
        }
        // 设置页面（Sheet 形式）
        .sheet(isPresented: $showSettingsView) {
            SettingsView()
        }
        // 页面加载时从持久化存储加载图标配置
        .onAppear {
            loadFeatureItemsFromRepository()
        }
        // 监听 repository 变化，自动刷新
        .onChange(of: iconRepository.visibleConfigs) { _, _ in
            loadFeatureItemsFromRepository()
        }
    }
    
    // MARK: - 数据加载
    
    /// 从 Repository 加载图标配置，转换为 FeatureButtonConfig 数组
    private func loadFeatureItemsFromRepository() {
        let orderedIds = iconRepository.getVisibleIconIds()
        
        // 将持久化的顺序映射到 FeatureButtonConfig
        featureItems = orderedIds.compactMap { iconId in
            // 从默认配置中查找对应的 FeatureButtonConfig
            FeatureButtonConfig.defaultItems.first { $0.id == iconId }
        }
        
        // 如果持久化数据为空或不完整，使用默认配置
        if featureItems.isEmpty {
            featureItems = FeatureButtonConfig.defaultItems
        }
    }
    
    // MARK: - 子视图
    
    /// 背景装饰元素
    private var backgroundDecorations: some View {
        ZStack {
            // 右上角蓝色圆点
            Circle()
                .fill(Color.holoInfo.opacity(0.2))
                .frame(width: 8, height: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 40)
                .padding(.top, 80)
            
            // 左下角紫色圆点
            Circle()
                .fill(Color.holoPurple.opacity(0.2))
                .frame(width: 12, height: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 32)
                .padding(.bottom, 128)
        }
    }
    
    /// 顶部 Header
    private var headerView: some View {
        HStack {
            // 左侧问候语
            VStack(alignment: .leading, spacing: 4) {
                Text("有机智能")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                    .kerning(1.2)
                
                Text("你好，\(userName)")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
            }
            
            Spacer()
            
            // 右侧用户按钮
            Button {
                showSettingsView = true
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: HoloRadius.full)
                        .fill(.ultraThinMaterial)
                        .frame(width: 52, height: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: HoloRadius.full)
                                .stroke(Color.holoBorder, lineWidth: 1)
                        )
                    
                    Image(systemName: "person.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.holoTextPrimary)
                }
            }
        }
    }
    
    /// 中央主内容区域
    private var mainContent: some View {
        ZStack {
            // 中央语音助手按钮
            VoiceAssistantButton {
                // TODO: 激活语音助手
                print("Voice assistant activated")
            }
            
            // 五角形功能入口按钮（支持拖拽排序）
            featureButtons
        }
        .padding(.horizontal, HoloSpacing.lg)
    }
    
    // MARK: - 五角形功能按钮布局
    
    /// 五角形功能入口按钮
    /// 布局逻辑：以语音按钮中心为圆心，5 个位置按五角形均匀分布
    /// 位置顺序：顶部(0) -> 右上(1) -> 右下(2) -> 左下(3) -> 左上(4)
    private var featureButtons: some View {
        GeometryReader { geometry in
            // 整体上移 10pt，使布局更紧凑
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2 - 10)
            let positions = calculatePentagonPositions(center: center, radius: pentagonRadius)
            
            ZStack {
                ForEach(Array(featureItems.enumerated()), id: \.element.id) { index, item in
                    let isDragging = draggingItem?.id == item.id
                    let position = positions[index]
                    
                    // 使用纯内容视图，避免 Button 拦截手势
                    FeatureButtonContent(config: item)
                        .contentShape(Rectangle())  // 扩大点击区域
                        .scaleEffect(isDragging ? 1.15 : 1.0)
                        .shadow(
                            color: isDragging ? .black.opacity(0.2) : .clear,
                            radius: isDragging ? 15 : 0,
                            x: 0,
                            y: isDragging ? 10 : 0
                        )
                        .zIndex(isDragging ? 100 : 0)
                        .position(
                            x: isDragging ? position.x + dragOffset.width : position.x,
                            y: isDragging ? position.y + dragOffset.height : position.y
                        )
                        // 长按 + 拖拽组合手势（高优先级）
                        .gesture(
                            createDragGesture(for: item, at: index, positions: positions)
                        )
                        // 点击手势（同时触发，仅在非拖拽和非长按状态下生效）
                        .simultaneousGesture(
                            TapGesture()
                                .onEnded {
                                    // 只有在没有拖拽且没有长按时才处理点击
                                    if draggingItem == nil && !isLongPressing {
                                        handleFeatureButtonTap(item)
                                    }
                                }
                        )
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragging)
                }
            }
        }
        .frame(height: pentagonAreaHeight)
    }
    
    // MARK: - 五角形位置计算
    
    /// 计算五角形五个顶点的位置
    /// - Parameters:
    ///   - center: 圆心位置
    ///   - radius: 半径
    /// - Returns: 五个位置点的数组，从顶部开始顺时针排列
    private func calculatePentagonPositions(center: CGPoint, radius: CGFloat) -> [CGPoint] {
        var positions: [CGPoint] = []
        
        // 五角形每个顶点之间的角度间隔（360° / 5 = 72°）
        let angleStep = 2 * CGFloat.pi / 5
        
        // 起始角度：-90°（即 270°），使第一个顶点在正上方
        let startAngle = -CGFloat.pi / 2
        
        for i in 0..<5 {
            let angle = startAngle + CGFloat(i) * angleStep
            let x = center.x + radius * cos(angle)
            let y = center.y + radius * sin(angle)
            positions.append(CGPoint(x: x, y: y))
        }
        
        return positions
    }
    
    // MARK: - 拖拽手势处理
    
    /// 创建长按 + 拖拽组合手势
    /// - Parameters:
    ///   - item: 当前按钮配置
    ///   - index: 当前在数组中的索引
    ///   - positions: 五角形位置数组
    /// - Returns: 组合手势
    private func createDragGesture(
        for item: FeatureButtonConfig,
        at index: Int,
        positions: [CGPoint]
    ) -> some Gesture {
        // 长按手势：0.5 秒触发
        let longPress = LongPressGesture(minimumDuration: 0.5)
            .updating($isLongPressing) { currentState, gestureState, _ in
                // 当长按开始时，更新 GestureState
                gestureState = currentState
            }
            .onEnded { _ in
                // 触发 Haptic 反馈
                let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                impactFeedback.impactOccurred()
                
                // 设置拖拽状态
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    draggingItem = item
                    draggingFromIndex = index
                }
            }
        
        // 拖拽手势：设置 minimumDistance 为 0，让拖拽在长按完成后立即响应
        let drag = DragGesture(minimumDistance: 0)
            .onChanged { value in
                // 只有在长按激活后才处理拖拽
                guard draggingItem != nil else { return }
                
                dragOffset = value.translation
                
                // 检测是否接近其他位置，如果是则交换
                checkAndSwapPosition(
                    currentPosition: CGPoint(
                        x: positions[index].x + value.translation.width,
                        y: positions[index].y + value.translation.height
                    ),
                    positions: positions
                )
            }
            .onEnded { _ in
                // 拖拽结束，保存新顺序到持久化存储
                let orderedIds = featureItems.map { $0.id }
                iconRepository.updateOrder(orderedIds)
                
                // 重置拖拽状态
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    draggingItem = nil
                    draggingFromIndex = nil
                    dragOffset = .zero
                }
            }
        
        // 组合手势：先长按，再拖拽
        return longPress.sequenced(before: drag)
    }
    
    /// 检测拖拽位置并在必要时交换
    /// - Parameters:
    ///   - currentPosition: 当前拖拽位置
    ///   - positions: 五角形位置数组
    private func checkAndSwapPosition(currentPosition: CGPoint, positions: [CGPoint]) {
        guard let fromIndex = draggingFromIndex else { return }
        
        // 检测距离阈值（50pt 范围内触发交换）
        let swapThreshold: CGFloat = 50
        
        for (targetIndex, targetPosition) in positions.enumerated() {
            // 跳过自身位置
            guard targetIndex != fromIndex else { continue }
            
            // 计算当前拖拽位置与目标位置的距离
            let distance = hypot(
                currentPosition.x - targetPosition.x,
                currentPosition.y - targetPosition.y
            )
            
            // 如果距离小于阈值，执行交换
            if distance < swapThreshold {
                // 触发轻微 Haptic 反馈
                let selectionFeedback = UISelectionFeedbackGenerator()
                selectionFeedback.selectionChanged()
                
                // 交换数组中的位置
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    featureItems.swapAt(fromIndex, targetIndex)
                    draggingFromIndex = targetIndex
                    
                    // 重置偏移量，让按钮"吸附"到新位置
                    dragOffset = .zero
                }
                
                break
            }
        }
    }
    
    // MARK: - 按钮点击处理
    
    /// 处理功能按钮点击事件
    /// - Parameter item: 被点击的按钮配置
    private func handleFeatureButtonTap(_ item: FeatureButtonConfig) {
        switch item.id {
        case "task":
            print("Task tapped")
        case "finance":
            showFinanceView = true
        case "health":
            print("Health tapped")
        case "thoughts":
            print("Thoughts tapped")
        case "habit":
            showHabitsView = true
        default:
            print("\(item.title) tapped")
        }
    }
    
    /// 日程提醒
    private var scheduleReminder: some View {
        HStack(spacing: 8) {
            // 绿色状态指示点
            Circle()
                .fill(Color.holoSuccess)
                .frame(width: 8, height: 8)
            
            // 日程文字
            Text(currentSchedule)
                .font(.holoLabel)
                .foregroundColor(.holoTextPrimary)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 10)
        )
    }
}

// MARK: - Preview

#Preview {
    HomeView()
}