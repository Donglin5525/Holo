//
//  HoloMemoryCenterView.swift
//  Holo
//
//  「Holo 记忆」管理主页（减法版契约 =
//  docs/_common/plans/2026-10-28-Holo记忆与上下文重构方案/原型/记忆重构-核心画面原型-减法版.html 画面 ①②）
//
//  减法六刀落地：卡片两行（一句话 + 一行来源灰字，胶囊删除）、
//  分段 已记住/值得确认、四类分组、搜索收进导航（列表短了不是第一动作）、
//  历史/停用/设置 收进列表底部；空态族、暂停横幅、行内回执保留。
//

import SwiftUI

struct HoloMemoryCenterView: View {
    @StateObject private var viewModel: HoloMemoryCenterViewModel
    @Environment(\.dismiss) private var dismiss

    /// 自定义返回；缺省用导航栈 dismiss（页面自绘导航栏，隐藏系统返回避免双返回钮）。
    var onBack: (() -> Void)?
    /// 空态「去找 Holo 聊聊」动作：跨模块跳 AI 必须由宿主接线；
    /// 跳转类回调不设默认空值，漏接=编译不过
    let onOpenChat: () -> Void

    @State private var showPastList = false
    @State private var showStoppedList = false
    @State private var showMemorySettings = false
    /// 搜索收进导航：默认不常驻，点放大镜展开（减法原型 ① 注）。
    @State private var showSearch = false

    init(
        onBack: (() -> Void)? = nil,
        onOpenChat: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: HoloMemoryCenterViewModel())
        self.onBack = onBack
        self.onOpenChat = onOpenChat
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            content
        }
        .background(Color.holoToolBackground)
        .buttonStyle(.plain)
        #if canImport(UIKit)
        .navigationBarBackButtonHidden(true)
        #if canImport(UIKit)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        #endif
        .navigationDestination(isPresented: $showPastList) {
            HoloMemoryBucketListView(bucket: .history)
        }
        .navigationDestination(isPresented: $showStoppedList) {
            HoloMemoryBucketListView(bucket: .stopped)
        }
        .navigationDestination(isPresented: $showMemorySettings) {
            PersonalMemorySettingsView(onOpenMemoryGallery: {
                // 从记忆中心进设置再「进入记忆长廊」：跳长廊（深链由 HomeView 消费，
                // 个人页/聊天页宿主随模块切换自动退场）
                DeepLinkState.shared.navigate(to: .memoryGallery(focusNewMemories: false))
            })
        }
        .task { await viewModel.load() }
    }

    // MARK: - 导航（返回键最左；搜索收进导航，减法原型 ①）

    private var navBar: some View {
        HStack(spacing: HoloSpacing.sm) {
            Button(action: {
                if let onBack {
                    onBack()
                } else {
                    dismiss()
                }
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.holoToolText)
                    .frame(width: 34, height: 34)
                    .background(Color.holoToolSurface, in: Circle())
                    .overlay(Circle().strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
            }
            .accessibilityLabel("返回")

            Spacer(minLength: 0)

            Text("Holo 记忆")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.holoToolText)

            Spacer(minLength: 0)

            Button {
                withAnimation(HoloAnimation.standard) { showSearch.toggle() }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.holoToolText)
                    .frame(width: 34, height: 34)
                    .background(Color.holoToolSurface, in: Circle())
                    .overlay(Circle().strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
            }
            .accessibilityLabel(showSearch ? "收起搜索" : "搜索记忆")
        }
        .padding(.horizontal, HoloSpacing.md)
        .frame(height: 50)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            failureView
        case .loaded:
            loadedContent
        }
    }

    private var failureView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(Color.holoToolWarning)
            Text("记忆加载失败")
                .holoText(.sectionTitle)
                .foregroundStyle(Color.holoToolText)
            Text("已保存的内容没有丢，稍后再试一次。")
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
            Button {
                Task { await viewModel.load() }
            } label: {
                Text("重试")
                    .holoText(.body)
                    .foregroundStyle(Color.holoToolAction)
                    .padding(.horizontal, HoloSpacing.lg)
                    .frame(height: 44)
                    .background(Color.holoToolSurface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var loadedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if showSearch {
                    searchBar
                }
                segmentRow

                if let notice = viewModel.actionNotice {
                    noticeBanner(notice)
                }
                if let receipt = viewModel.receipt {
                    receiptRow(receipt)
                }

                if viewModel.rememberedCount == 0 && viewModel.observingCount == 0 && viewModel.worthConfirming.isEmpty {
                    memoryEmptyState
                } else if viewModel.selectedBucket == .remembered {
                    rememberedContent
                } else {
                    // 值得确认（减法原型 ②：一句人话 + 一个主按钮）
                    HoloMemoryWorthConfirmingSection(viewModel: viewModel)
                }

                if viewModel.selectedBucket == .remembered {
                    moreEntry
                }
            }
            .padding(.horizontal, HoloSpacing.page)
            .padding(.bottom, 28)
        }
        .refreshable { await viewModel.load() }
    }

    // MARK: - 搜索（点导航展开；含领域筛选）

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.holoToolTextSecondary)
                TextField("搜索记忆", text: $viewModel.searchText)
                    .holoText(.supporting)
                    .foregroundStyle(Color.holoToolText)
                    .autocorrectionDisabled()
                if viewModel.isFilterActive {
                    Button("清除") { viewModel.resetFilters() }
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.holoToolAction)
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 40)
            .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: HoloRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .strokeBorder(Color.holoToolBorder, lineWidth: 0.5)
            )

            domainChip
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var domainChip: some View {
        HStack(spacing: HoloSpacing.sm) {
            Menu {
                Button("全部领域") { viewModel.domainFilter = nil }
                ForEach(viewModel.availableDomains, id: \.self) { domain in
                    Button(HoloMemoryCenterViewModel.domainTitle(domain)) {
                        viewModel.domainFilter = domain
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(viewModel.domainFilter.map(HoloMemoryCenterViewModel.domainTitle) ?? "全部领域")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.7)
                }
                .foregroundStyle(Color.holoToolAction)
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background(Color.holoToolSurface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
                .contentShape(Capsule())
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 分段（灰轨道 + 浮起选中块，§8.8 唯一样式；无红色催办）

    private var segmentRow: some View {
        HStack(spacing: 0) {
            segmentButton("已记住", selection: .remembered)
            segmentButton("值得确认", selection: .worthConfirming)
        }
        .padding(2.5)
        .background(Color.holoToolInset, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func segmentButton(
        _ title: String,
        selection: HoloMemoryCenterViewModel.BucketSelection
    ) -> some View {
        Button {
            withAnimation(HoloAnimation.quick) { viewModel.selectedBucket = selection }
        } label: {
            Text(title)
                .font(.system(size: 13.5, weight: viewModel.selectedBucket == selection ? .bold : .medium))
                .foregroundStyle(viewModel.selectedBucket == selection ? Color.holoToolAction : Color.holoToolTextSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background {
                    if viewModel.selectedBucket == selection {
                        Capsule()
                            .fill(Color.holoToolSurface)
                            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .accessibilityLabel(title)
    }

    // MARK: - 已记住（减法原型 ①：四类分组，卡片两行）

    @ViewBuilder
    private var rememberedContent: some View {
        if viewModel.answeringEnabled == false {
            pauseBanner
        }
        if !viewModel.confirmedKnowledge.isEmpty {
            // 知识层确认条目（规律确认/发现保存）：无记录载体，单独成组置顶，
            // 与四类记录分组同一列表容器（2026-11-01 补件：确认后不再消失）。
            groupHeader("你确认的理解")
            VStack(spacing: 8) {
                ForEach(viewModel.confirmedKnowledge) { knowledge in
                    HoloMemoryConfirmedKnowledgeRow(knowledge: knowledge)
                }
            }
            .padding(.top, 2)
        }
        if viewModel.currentRows.isEmpty {
            if viewModel.isFilterActive {
                filterEmptyState
            } else if viewModel.worthConfirming.isEmpty && viewModel.confirmedKnowledge.isEmpty {
                memoryEmptyState
            } else if viewModel.confirmedKnowledge.isEmpty {
                // 已记住（记录类）为空、知识层也为空、值得确认有内容：引导切换，不称系统没有任何记忆（§4.5）。
                // 知识层已有确认条目时上方已显示「你确认的理解」分组，不能再挂「还没有确定下来」空态（11-05 挑刺 P0#2）。
                VStack(spacing: HoloSpacing.sm) {
                    Text("眼下还没有确定下来的理解")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.holoToolText)
                    Text("有几条 Holo 观察到的规律，等你确认。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.holoToolTextSecondary)
                    Button {
                        withAnimation(HoloAnimation.quick) { viewModel.selectedBucket = .worthConfirming }
                    } label: {
                        Text("看看值得确认")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.holoToolAction)
                            .padding(.horizontal, 22)
                            .frame(height: 40)
                            .background(Color.holoToolSurface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            }
        } else {
            ForEach(viewModel.rememberedGroups) { group in
                groupHeader(group.group.title)
                listContainer(group.rows)
            }
        }
    }

    private var pauseBanner: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("记忆辅助回答已关闭")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.holoToolInfo)
            HStack(spacing: 4) {
                Text("已保存的记忆仍在这里正常管理，只是暂时不用于回答。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.holoToolTextSecondary)
                Button("前往记忆设置") { showMemorySettings = true }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.holoToolInfo)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolInfo.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.holoToolInfo.opacity(0.25), lineWidth: 1)
        )
        .padding(.top, 2)
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.holoToolTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
            .padding(.bottom, 7)
            .padding(.horizontal, 2)
    }

    // MARK: - 列表容器与行（两行卡：一句话 + 一行来源灰字，减法原型 ①）

    private func listContainer(_ rows: [HoloMemoryManagementProjection]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.recordID) { index, projection in
                memoryRow(projection)
                if index < rows.count - 1 {
                    Rectangle()
                        .fill(Color.holoToolBorder.opacity(0.5))
                        .frame(height: 0.5)
                        .padding(.leading, 15)
                }
            }
        }
        .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .strokeBorder(Color.holoToolBorder, lineWidth: 0.5)
        )
    }

    /// 已记住行：两行（陈述 + 来源灰字），进详情；操作在详情页。
    private func memoryRow(_ projection: HoloMemoryManagementProjection) -> some View {
        NavigationLink {
            HoloMemoryCenterDetailView(recordID: projection.recordID)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(projection.displayText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.holoToolText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(rowSubline(for: projection))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.holoToolTextSecondary.opacity(0.6))
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    private func rowSubline(for projection: HoloMemoryManagementProjection) -> String {
        viewModel.rowMetaByRecordID[projection.recordID]?.subline
            ?? HoloMemorySourceLine.originOnlyText(projection.originLabel)
    }

    /// 列表底部「历史 · 停用 · 设置 ▾」次级入口（减法原型 ① 底行）。
    private var moreEntry: some View {
        Menu {
            Button("过去的记忆") { showPastList = true }
            Button("已停用") { showStoppedList = true }
            Button("记忆设置") { showMemorySettings = true }
        } label: {
            HStack(spacing: 4) {
                Text("历史 · 停用 · 设置")
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.7)
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.holoToolTextSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .padding(.top, 16)
    }

    // MARK: - 回执与提示（§5.1 行内回执 + 撤销；失败保草稿）

    private func receiptRow(_ receipt: HoloMemoryCenterViewModel.ActionReceipt) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(Color.holoToolSuccess)
            Text(receipt.text)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Color.holoToolText)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("撤销") {
                Task { await viewModel.undoReceipt() }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.holoToolAction)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(Color.holoToolSurface, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
        }
        .padding(12)
        .background(Color.holoToolSuccess.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.holoToolSuccess.opacity(0.25), lineWidth: 1))
        .padding(.bottom, 12)
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(Color.holoToolWarning)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.holoToolTextSecondary)
                .lineSpacing(3)
            Spacer(minLength: 0)
            Button {
                viewModel.actionNotice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            .accessibilityLabel("关闭提示")
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolWarning.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.holoToolWarning.opacity(0.25), lineWidth: 1))
        .padding(.bottom, 12)
    }

    // MARK: - 空态（四件套，§4.5）

    private var memoryEmptyState: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.holoToolInset)
                .frame(width: 74, height: 74)
                .overlay {
                    Image(systemName: viewModel.automaticMemoryEnabled ? "brain.head.profile" : "leaf")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(Color.holoToolAI)
                        .accessibilityHidden(true)
                }
            if viewModel.automaticMemoryEnabled {
                emptyCopy(
                    title: "还没有沉淀下来的理解",
                    body: "和 Holo 相处的过程中，合适的信息会慢慢留下——不需要刻意做什么。",
                    actionTitle: "去找 Holo 聊聊",
                    action: onOpenChat
                )
            } else {
                emptyCopy(
                    title: "自动形成已关闭",
                    body: "Holo 不会主动新增对你的理解。已保存的内容仍在这里，随时可管理。",
                    actionTitle: "前往记忆设置",
                    action: { showMemorySettings = true }
                )
            }
        }
        .padding(.top, 56)
    }

    private var filterEmptyState: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(Color.holoToolTextSecondary)
            Text("没有匹配的记忆")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.holoToolText)
            Text("换个说法，或清除筛选再试。")
                .font(.system(size: 13))
                .foregroundStyle(Color.holoToolTextSecondary)
            Button("清除筛选") { viewModel.resetFilters() }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.holoToolAction)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func emptyCopy(title: String, body: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.holoToolText)
                .padding(.top, 20)
            Text(body)
                .font(.system(size: 14))
                .foregroundStyle(Color.holoToolTextSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 10)
            Button(action: action) {
                Text(actionTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.holoToolText)
                    .padding(.horizontal, 26)
                    .frame(height: 44)
                    .background(Color.holoToolSurface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
            }
            .padding(.top, 22)
        }
    }
}

// MARK: - 领域中文名（M02 投影只出枚举，展示名统一在这里）

extension HoloMemoryCenterViewModel {
    static func domainTitle(_ domain: HoloMemoryDomain) -> String {
        switch domain {
        case .finance: return "财务"
        case .thought: return "想法"
        case .health: return "健康"
        case .habit: return "习惯"
        case .task: return "任务"
        case .goal: return "目标"
        case .conversation: return "对话"
        case .profile: return "个人档案"
        }
    }
}
