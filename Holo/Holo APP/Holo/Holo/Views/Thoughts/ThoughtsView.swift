//
//  ThoughtsView.swift
//  Holo
//
//  观点模块 - 根视图容器
//  从首页 fullScreenCover 进入，顶部有返回按钮
//

import SwiftUI
import CoreData

// MARK: - Thought Tab 枚举

/// 观点模块底部 Tab 枚举
enum ThoughtTab: String, CaseIterable {
    case list = "列表"
    case add = "新增"

    /// 对应的 SF Symbol 图标名
    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .add: return "plus"
        }
    }
}

// MARK: - ThoughtsView

/// 观点模块根视图
/// 管理观点模块的主界面
struct ThoughtsView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    @State private var selectedTab: ThoughtTab = .list
    @State private var showAddThought: Bool = false

    private let thoughtRepository = ThoughtRepository()

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.holoBackground.ignoresSafeArea()

            Group {
                switch selectedTab {
                case .list:
                    ThoughtListView(
                        onBack: { dismiss() },
                        showAddThought: $showAddThought,
                        thoughtRepository: thoughtRepository
                    )
                case .add:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .swipeBackToDismiss { dismiss() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            thoughtTabBar
        }
        .sheet(isPresented: $showAddThought) {
            ThoughtEditorView {
                // 保存后刷新列表
                NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
            }
        }
    }

    // MARK: - 底部 Tab 栏

    /// 底部导航栏
    private var thoughtTabBar: some View {
        GeometryReader { geo in
            let bottomInset = max(geo.safeAreaInsets.bottom, 20)
            HStack(spacing: 0) {
                // 列表 Tab
                thoughtTabButton(.list)

                // 新增按钮
                thoughtAddButton
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, bottomInset)
            .background(
                Color.holoCardBackground
                    .shadow(color: HoloShadow.card, radius: 10, x: 0, y: -2)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        .frame(height: 88)
        .frame(maxWidth: .infinity)
        .background(Color.holoCardBackground.ignoresSafeArea(edges: .bottom))
        .zIndex(40)
    }

    /// 普通 Tab 按钮
    private func thoughtTabButton(_ tab: ThoughtTab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(selectedTab == tab ? Color.holoPrimary : Color.clear)
                    .frame(width: 4, height: 4)

                Image(systemName: tab.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(selectedTab == tab ? .holoPrimary : .holoTextSecondary)

                Text(tab.rawValue)
                    .font(.holoTinyLabel)
                    .foregroundColor(selectedTab == tab ? .holoPrimary : .holoTextSecondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 右侧新增按钮
    private var thoughtAddButton: some View {
        Button {
            showAddThought = true
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(Color.clear)
                    .frame(width: 4, height: 4)

                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.holoPrimary)
                    .clipShape(Circle())

                Text("新增")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoPrimary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Preview

#Preview {
    ThoughtsView()
}
