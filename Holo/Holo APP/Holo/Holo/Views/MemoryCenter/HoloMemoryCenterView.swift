//
//  HoloMemoryCenterView.swift
//  Holo
//
//  「Holo 记忆」管理主页（方案 §3.2 M01；视觉契约 =
//  docs/prototypes/2026-10-23-holo-memory-center-prototype.html 画面 02-07，1:1）
//
//  M07 全量：分段/计数、搜索、筛选、分组列表、行标签体系、空态族、
//  暂停横幅；观察中行内操作（符合/改一下/不符合）与行内回执+撤销；
//  行→详情导航；更多菜单进「过去的记忆/已停用」。
//

import SwiftUI

struct HoloMemoryCenterView: View {
    @StateObject private var viewModel: HoloMemoryCenterViewModel
    @Environment(\.dismiss) private var dismiss

    /// 自定义返回；缺省用导航栈 dismiss（页面自绘导航栏，隐藏系统返回避免双返回钮）。
    var onBack: (() -> Void)?
    var onOpenMemorySettings: () -> Void
    /// 空态「去找 Holo 聊聊」动作（M08 接路由）。
    var onOpenChat: () -> Void

    @State private var showPastList = false
    @State private var showStoppedList = false

    init(
        onBack: (() -> Void)? = nil,
        onOpenMemorySettings: @escaping () -> Void = {},
        onOpenChat: @escaping () -> Void = {}
    ) {
        _viewModel = StateObject(wrappedValue: HoloMemoryCenterViewModel())
        self.onBack = onBack
        self.onOpenMemorySettings = onOpenMemorySettings
        self.onOpenChat = onOpenChat
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            content
        }
        .background(Color.holoToolBackground)
        .buttonStyle(.plain)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showPastList) {
            HoloMemoryBucketListView(bucket: .history)
        }
        .navigationDestination(isPresented: $showStoppedList) {
            HoloMemoryBucketListView(bucket: .stopped)
        }
        .task { await viewModel.load() }
    }

    // MARK: - 导航（返回键最左，§8.5）

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

            Spacer()

            Menu {
                Button("过去的记忆") { showPastList = true }
                Button("已停用") { showStoppedList = true }
                Button("记忆设置", action: onOpenMemorySettings)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.holoToolText)
                    .frame(width: 34, height: 34)
                    .background(Color.holoToolSurface, in: Circle())
                    .overlay(Circle().strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
            }
            .accessibilityLabel("更多")
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
                pageHead
                searchBar
                segmentRow
                filterRow

                if let notice = viewModel.actionNotice {
                    noticeBanner(notice)
                }
                if let receipt = viewModel.receipt {
                    receiptRow(receipt)
                }

                if viewModel.rememberedCount == 0 && viewModel.observingCount == 0 {
                    memoryEmptyState
                } else if viewModel.selectedBucket == .remembered {
                    rememberedContent
                } else {
                    observingContent
                }
            }
            .padding(.horizontal, HoloSpacing.page)
            .padding(.bottom, 28)
        }
        .refreshable { await viewModel.load() }
    }

    // MARK: - 头部

    private var pageHead: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Holo 记忆")
                .holoText(.pageTitle)
                .foregroundStyle(Color.holoToolText)
            Text("Holo 对你的理解都保存在这里，来源可查，去留由你。")
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    private var searchBar: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(Color.holoToolTextSecondary)
            TextField("搜索记忆", text: $viewModel.searchText)
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolText)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 13)
        .frame(height: 40)
        .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .strokeBorder(Color.holoToolBorder, lineWidth: 0.5)
        )
        .padding(.top, 14)
    }

    // MARK: - 分段（灰轨道 + 浮起选中块，§8.8 唯一样式；无红色催办）

    private var segmentRow: some View {
        HStack(spacing: 0) {
            segmentButton("已记住", count: viewModel.rememberedCount, selection: .remembered)
            segmentButton("观察中", count: viewModel.observingCount, selection: .observing)
        }
        .padding(2.5)
        .background(Color.holoToolInset, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func segmentButton(
        _ title: String,
        count: Int,
        selection: HoloMemoryCenterViewModel.BucketSelection
    ) -> some View {
        Button {
            withAnimation(HoloAnimation.quick) { viewModel.selectedBucket = selection }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 13.5, weight: viewModel.selectedBucket == selection ? .bold : .medium))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(0.75)
            }
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
        .accessibilityLabel("\(title) \(count) 条")
    }

    // MARK: - 筛选 chips（§4.3：领域 / 时间 / 形成方式）

    private var filterRow: some View {
        HStack(spacing: HoloSpacing.sm) {
            domainChip
            timeChip
            originChip
            if viewModel.isFilterActive {
                Button("清除") { viewModel.resetFilters() }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.holoToolAction)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 12)
    }

    private var domainChip: some View {
        Menu {
            Button("全部领域") { viewModel.domainFilter = nil }
            ForEach(viewModel.availableDomains, id: \.self) { domain in
                Button(HoloMemoryCenterViewModel.domainTitle(domain)) {
                    viewModel.domainFilter = domain
                }
            }
        } label: {
            // 领域 chip 常显当前选中态（未筛=全部领域），与原型一致。
            filterChipLabel(
                viewModel.domainFilter.map(HoloMemoryCenterViewModel.domainTitle) ?? "全部领域",
                isActive: true
            )
        }
    }

    private var timeChip: some View {
        Menu {
            ForEach(HoloMemoryCenterViewModel.TimeFilter.allCases) { filter in
                Button(filter.title) { viewModel.timeFilter = filter }
            }
        } label: {
            filterChipLabel(
                viewModel.timeFilter.title,
                isActive: viewModel.timeFilter != .all
            )
        }
    }

    private var originChip: some View {
        Menu {
            ForEach(HoloMemoryCenterViewModel.OriginFilter.allCases) { filter in
                Button(filter.title) { viewModel.originFilter = filter }
            }
        } label: {
            filterChipLabel(
                viewModel.originFilter.title,
                isActive: viewModel.originFilter != .all
            )
        }
    }

    private func filterChipLabel(_ title: String, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .opacity(0.7)
        }
        .foregroundStyle(isActive ? Color.holoToolAction : Color.holoToolTextSecondary)
        .padding(.horizontal, 13)
        .frame(height: 30)
        .background(
            isActive ? Color.holoToolSurface : Color.clear,
            in: Capsule()
        )
        .overlay(Capsule().strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
        .contentShape(Capsule())
    }

    // MARK: - 已记住（§4.1：近段/长期分组，空分组隐藏）

    @ViewBuilder
    private var rememberedContent: some View {
        if viewModel.answeringEnabled == false {
            pauseBanner
        }
        if viewModel.recentRows.isEmpty && viewModel.longTermRows.isEmpty {
            if viewModel.isFilterActive {
                filterEmptyState
            } else {
                // 已记住为空、观察中有内容：引导切换，不称系统没有任何记忆（§4.5）。
                switchToObservingState
            }
        } else {
            if !viewModel.recentRows.isEmpty {
                groupHeader("最近这段时间", sub: "会随生活变化更新")
                listContainer(viewModel.recentRows)
            }
            if !viewModel.longTermRows.isEmpty {
                groupHeader("长期了解", sub: "跨阶段的稳定偏好与事实")
                listContainer(viewModel.longTermRows)
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
                Button("前往记忆设置", action: onOpenMemorySettings)
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

    private func groupHeader(_ title: String, sub: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 16.5, weight: .bold))
                .foregroundStyle(Color.holoToolText)
            Text(sub)
                .font(.system(size: 12))
                .foregroundStyle(Color.holoToolTextSecondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
        .padding(.bottom, 9)
        .padding(.horizontal, 2)
    }

    // MARK: - 观察中（§4.2：页内说明 + 行内操作；无催办）

    private var observingContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .padding(.top, 2)
                (
                    Text("这些理解还拿不准，")
                        .foregroundStyle(Color.holoToolTextSecondary)
                    + Text("暂不作为事实使用")
                        .foregroundStyle(Color.holoToolText)
                    + Text("。你可以查看依据，或告诉 Holo 更准确的情况。不处理也没关系，它们不会自己变成「已记住」。")
                        .foregroundStyle(Color.holoToolTextSecondary)
                )
                .font(.system(size: 12.5))
                .lineSpacing(3)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 2)

            if viewModel.currentRows.isEmpty {
                if viewModel.isFilterActive {
                    filterEmptyState
                } else {
                    Text("眼下没有拿不准的理解。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.holoToolTextSecondary.opacity(0.8))
                        .padding(.top, 14)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.currentRows.enumerated()), id: \.element.recordID) { index, projection in
                        observingRow(projection)
                        if index < viewModel.currentRows.count - 1 {
                            Rectangle()
                                .fill(Color.holoToolBorder.opacity(0.5))
                                .frame(height: 0.5)
                                .padding(.leading, 15)
                        }
                    }
                }
                .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.lg))
                .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
                Text("观察中的内容不会催办、不会计数上通知。逐条处理完可以随时离开，不需要清空。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary.opacity(0.8))
                    .padding(.top, 12)
            }
        }
    }

    // MARK: - 列表容器与行（单一容器 + 分隔线，不层层套卡，§15）

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

    /// 已记住行：进详情（操作在详情页）。
    private func memoryRow(_ projection: HoloMemoryManagementProjection) -> some View {
        NavigationLink {
            HoloMemoryCenterDetailView(recordID: projection.recordID)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(projection.displayText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.holoToolText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        ForEach(HoloMemoryRowTags.tags(for: projection), id: \.text) { tag in
                            HoloMemoryTagBadge(tag: tag)
                        }
                        Spacer(minLength: 0)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.holoToolTextSecondary.opacity(0.6))
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    /// 观察中行：陈述 + 状态标签 + 三个行内操作（原型画面 05）。
    private func observingRow(_ projection: HoloMemoryManagementProjection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink {
                HoloMemoryCenterDetailView(recordID: projection.recordID)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(projection.displayText)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.holoToolText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            ForEach(HoloMemoryRowTags.tags(for: projection), id: \.text) { tag in
                                HoloMemoryTagBadge(tag: tag)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.holoToolTextSecondary.opacity(0.6))
                        .padding(.top, 2)
                }
                .padding(.horizontal, 15)
                .padding(.top, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            if projection.allowedActions.contains(.confirm)
                || projection.allowedActions.contains(.markInaccurate) {
                HStack(spacing: 8) {
                    if projection.allowedActions.contains(.confirm) {
                        observingActionButton("符合现在的情况", prominent: true) {
                            Task { await viewModel.perform(.confirm, on: projection) }
                        }
                    }
                    if projection.allowedActions.contains(.correct) {
                        NavigationLink {
                            HoloMemoryCenterDetailView(recordID: projection.recordID, autoOpenEdit: true)
                        } label: {
                            Text("改一下")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.holoToolText)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
                        }
                        .accessibilityLabel("改一下")
                    }
                    if projection.allowedActions.contains(.markInaccurate) {
                        observingActionButton("不符合", prominent: false) {
                            Task { await viewModel.perform(.markInaccurate(reason: nil), on: projection) }
                        }
                    }
                }
                .padding(.horizontal, 15)
                .padding(.top, 10)
                .padding(.bottom, 13)
            } else {
                Spacer().frame(height: 0)
                Color.clear.frame(height: 13)
            }
        }
    }

    private func observingActionButton(
        _ title: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominent ? Color.holoToolOnAction : Color.holoToolText)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    prominent ? Color.holoToolAction : Color.holoToolSurface,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(prominent ? Color.clear : Color.holoToolBorder, lineWidth: 0.5)
                )
        }
        .accessibilityLabel(title)
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
                .overlay(Text(viewModel.automaticMemoryEnabled ? "🫧" : "🌱").font(.system(size: 34)))
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
                    action: onOpenMemorySettings
                )
            }
        }
        .padding(.top, 56)
    }

    private var switchToObservingState: some View {
        VStack(spacing: HoloSpacing.sm) {
            Text("眼下还没有确定下来的理解")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.holoToolText)
            Text("观察中的内容会先放在另一个页签。")
                .font(.system(size: 13))
                .foregroundStyle(Color.holoToolTextSecondary)
            Button {
                withAnimation(HoloAnimation.quick) { viewModel.selectedBucket = .observing }
            } label: {
                Text("看看观察中")
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
