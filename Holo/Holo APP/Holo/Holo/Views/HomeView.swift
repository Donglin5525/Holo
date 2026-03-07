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
/// - Main: 中央语音助手 + 四个功能入口按钮
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
                // TODO: 跳转到个人中心
                print("Profile tapped")
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: HoloRadius.full)
                        .fill(.ultraThinMaterial)
                        .frame(width: 52, height: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: HoloRadius.full)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
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
            
            // 四个功能入口按钮
            featureButtons
        }
        .padding(.horizontal, HoloSpacing.lg)
    }
    
    /// 四个功能入口按钮
    private var featureButtons: some View {
        GeometryReader { geometry in
            ZStack {
                // 左上 - 任务
                FeatureButton(config: .task) {
                    // TODO: 跳转到任务页面
                    print("Task tapped")
                }
                .position(
                    x: 39 + 28,  // 左边距 + 按钮宽度一半
                    y: 96 + 40   // 上边距 + 按钮高度一半
                )
                
                // 右上 - 财务
                FeatureButton(config: .finance) {
                    showFinanceView = true
                }
                .position(
                    x: geometry.size.width - 39 - 28,  // 右边距 + 按钮宽度一半
                    y: 96 + 40
                )
                
                // 左下 - 健康
                FeatureButton(config: .health) {
                    // TODO: 跳转到健康页面
                    print("Health tapped")
                }
                .position(
                    x: 39 + 28,
                    y: geometry.size.height - 96 - 40
                )
                
                // 右下 - 观点
                FeatureButton(config: .thoughts) {
                    // TODO: 跳转到观点页面
                    print("Thoughts tapped")
                }
                .position(
                    x: geometry.size.width - 39 - 28,
                    y: geometry.size.height - 96 - 40
                )
            }
        }
        .frame(height: 500)  // 功能按钮区域高度
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