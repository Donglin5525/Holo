//
//  TransactionCategoryGrid.swift
//  Holo
//
//  AddTransactionSheet 内联分类网格 — 5 列网格 + 分段 Tab + 一级/二级下钻
//  + 长按拖拽排序（2026-11-09 空间优化：标题行已删，「最近使用」顶卡头；
//    长按原地松手=打开分类管理，长按后拖动=排序落位）
//

import SwiftUI
import CoreData
import os

// MARK: - 分类网格视图

extension AddTransactionSheet {

    /// 支出/收入切换 Tab（分段控件：灰轨道 + 白色浮起选中块）
    var typeTabBar: some View {
        HStack(spacing: 0) {
            typeSegmentButton(title: String(localized: "支出"), isSelected: transactionType == .expense,
                              accessibilityID: "transactionSheet.expenseSegment") {
                switchType(to: .expense)
            }
            typeSegmentButton(title: String(localized: "收入"), isSelected: transactionType == .income,
                              accessibilityID: "transactionSheet.incomeSegment") {
                switchType(to: .income)
            }
        }
        .padding(3)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.sm)
                .fill(Color.holoToolInset)
        )
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Color.holoCardBackground)
    }

    /// 分段按钮：选中=白块浮起（圆角 6 轻投影）+ 橙字 15pt；未选中=灰字
    private func typeSegmentButton(title: String, isSelected: Bool,
                                   accessibilityID: String,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? .holoPrimary : .holoToolTextSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.holoCardBackground : Color.clear)
                        .shadow(color: .black.opacity(0.10), radius: 3, x: 0, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
    }

    /// 分类网格区域（标题行已删：一级态「最近使用」直接顶卡头；下钻态仅留返回小胶囊）
    var categoryGrid: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let parent = drillDownParent {
                // 二级下钻态：整行标题已删，只留「‹ 分类名」返回小胶囊（高 24；胶囊与宫格间距按原型 12）
                VStack(alignment: .leading, spacing: 12) {
                    drillDownBackChip(parent)
                    categoryGridBody
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            } else {
                // 一级总览：无标题行，「最近使用」直接顶卡头
                if !recentCategories.isEmpty {
                    recentCategorySection
                }
                categoryGridBody
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .padding(16)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .animation(HoloAnimation.smooth, value: drillDownParent?.objectID)
        .sheet(isPresented: $showCategoryManagement) {
            // 分类管理页内含 NavigationLink，必须自带导航栈容器，否则页内跳转全部失效
            NavigationStack { CategoryManagementView(showsDoneButton: true) }
        }
        .sheet(isPresented: $showAddCategory) {
            AddCategorySheet(parentId: addCategoryParentId, type: transactionType) {
                Task { await loadCategories() }
            }
        }
        .onChange(of: showCategoryManagement) { _, isShowing in
            if !isShowing {
                Task { await loadCategories() }
            }
        }
        .onAppear {
            // 长按松手→打开管理页 与 排序落位→持久化 的会话回调装配
            categoryReorder.onOpenManagement = {
                showCategoryManagement = true
            }
            categoryReorder.onCommit = { ids, _ in
                persistCategoryOrder(ids)
            }
        }
    }

    /// 网格主体：直接放非滚动容器撑满卡宽（一级 10 格两行 / 下钻二级四行全部展开无滚动）
    private var categoryGridBody: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: CategoryGridReorderFeel.columnSpacing), count: 5)
        let order = categoryReorder.effectiveOrder(baseline: displayedCategoryIds)
        let categories = categoriesForOrder(order)

        return LazyVGrid(columns: columns, spacing: CategoryGridReorderFeel.rowSpacing) {
            ForEach(categories, id: \.objectID) { category in
                if drillDownParent == nil {
                    reorderableParentCategoryButton(category)
                } else {
                    reorderableChildCategoryButton(category)
                }
            }
            // 「＋新增」格不参与排序、恒在末位
            if drillDownParent == nil {
                addTopLevelCategoryButton()
            } else if let parent = drillDownParent {
                addChildCategoryButton(parent)
            }
        }
        // 换位让位动画（会话顺序驱动 ForEach 重排，identity 保持→平滑滑动）
        .animation(HoloAnimation.snappy, value: order)
        // 列宽收集（换位计算的几何输入；onGeometryChange 回调上下文写状态不会引发渲染循环）
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { gridWidth in
            categoryReorder.noteGridMetrics(
                columnWidth: (gridWidth - CategoryGridReorderFeel.columnSpacing * 4) / 5
            )
        }
    }

    /// 当前展示的分类序（一级=当前类型顶层；二级=下钻父级的子分类）
    private var displayedCategories: [Category] {
        drillDownParent.map(childCategoriesForParent) ?? topLevelCategories
    }

    /// 去重后的 id 序（iCloud 副本行同 id，会话按唯一 id 进行）
    private var displayedCategoryIds: [UUID] {
        var seen = Set<UUID>()
        return displayedCategories.compactMap { category in
            guard seen.insert(category.id).inserted else { return nil }
            return category.id
        }
    }

    /// 会话顺序 → 分类对象（会话期间分类集合变化即回退 baseline 重取）
    private func categoriesForOrder(_ order: [UUID]) -> [Category] {
        let byId = Dictionary(displayedCategories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let resolved = order.compactMap { byId[$0] }
        return resolved.count == displayedCategoryIds.count ? resolved : displayedCategories
    }

    /// 下钻返回小胶囊：高 24、橙字浅橙底圆角，左对齐（点它回一级；也是交互→收键盘）
    private func drillDownBackChip(_ parent: Category) -> some View {
        Button {
            showNumericKeypad = false
            categoryReorder.cancelDrag()
            withAnimation(HoloAnimation.smooth) {
                drillDownParent = nil
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Text(parent.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(.holoPrimary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color.holoPrimary.opacity(0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 最近常用分类横向展示（胶囊样式，和下方完整分类网格区分层级）
    private var recentCategorySection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("最近使用")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HoloSpacing.sm) {
                    ForEach(recentCategories, id: \.objectID) { category in
                        recentCategoryButton(category)
                    }
                }
            }
        }
    }

    /// 最近使用分类按钮（键盘态点击是选中分类、不收键盘——敲数字→点chip→✓一步保存链路的命脉）
    private func recentCategoryButton(_ category: Category) -> some View {
        let isSelected = selectedCategory?.objectID == category.objectID
        return Button {
            withAnimation {
                selectedCategory = category
                drillDownParent = categories.first { $0.id == category.parentId }
            }
        } label: {
            HStack(spacing: 6) {
                transactionCategoryIcon(category, size: 16)

                Text(category.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? .holoTextPrimary : .holoTextSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                Capsule()
                    .fill(category.swiftUIColor.opacity(isSelected ? 0.2 : 0.12))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? category.swiftUIColor : Color.holoTextSecondary.opacity(0.12), lineWidth: 1)
            )
            // 最近使用分类名称来自数据，保持胶囊完整宽度后再交给横向滚动条处理
            .fixedSize(horizontal: true, vertical: false)
            .holoRowHitArea(alignment: .center)
        }
        .buttonStyle(.plain)
    }

    /// 一级分类格（可长按拖拽排序）— 点击下钻到二级
    private func reorderableParentCategoryButton(_ category: Category) -> some View {
        let hasSelectedChild = selectedCategory.map { selected in
            childCategoriesForParent(category).contains { $0.objectID == selected.objectID }
                || selected.parentId == category.id
        } ?? false

        return ReorderableCategoryCell(
            category: category,
            iconColor: category.swiftUIColor,
            isSelected: hasSelectedChild,
            model: categoryReorder,
            onTap: {
                withAnimation(HoloAnimation.smooth) {
                    drillDownParent = category
                }
            },
            onInteraction: { showNumericKeypad = false }
        )
        .zIndex(categoryReorder.draggingId == category.id ? 10 : 0)
    }

    /// 二级分类格（可长按拖拽排序）— 点击选中
    private func reorderableChildCategoryButton(_ category: Category) -> some View {
        let isSelected = selectedCategory?.objectID == category.objectID

        return ReorderableCategoryCell(
            category: category,
            iconColor: drillDownParent?.swiftUIColor ?? .holoPrimary,
            isSelected: isSelected,
            model: categoryReorder,
            onTap: {
                withAnimation(HoloAnimation.quick) {
                    selectedCategory = category
                }
            },
            onInteraction: { showNumericKeypad = false }
        )
        .zIndex(categoryReorder.draggingId == category.id ? 10 : 0)
    }

    /// 一级分类末尾的快速新增入口
    private func addTopLevelCategoryButton() -> some View {
        categoryAddButton(title: String(localized: "新增"), accessibilityLabel: String(localized: "新增一级分类")) {
            addCategoryParentId = nil
            showAddCategory = true
        }
    }

    /// 二级分类末尾的快速新增入口
    private func addChildCategoryButton(_ parent: Category) -> some View {
        categoryAddButton(title: String(localized: "新增"), accessibilityLabel: String(localized: "在\(parent.name)下新增二级分类")) {
            addCategoryParentId = parent.id
            showAddCategory = true
        }
    }

    private func categoryAddButton(
        title: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            showNumericKeypad = false
            action()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.holoPrimary.opacity(0.12))
                        .frame(width: 48, height: 48)

                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                }

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.holoPrimary)
                    .lineLimit(1)
            }
            .holoRowHitArea(alignment: .center)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - 分类数据方法

extension AddTransactionSheet {

    /// 当前类型下的一级分类列表
    /// 不过滤「无子分类」的一级分类——用户新增的空一级分类也应当可见
    private var topLevelCategories: [Category] {
        categories
            .filter { top in
                top.transactionType == transactionType
                && top.isTopLevel
                && !top.isSystem
            }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 获取指定一级分类的二级子分类
    private func childCategoriesForParent(_ parent: Category) -> [Category] {
        categories
            .filter { $0.parentId == parent.id }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 切换收入/支出类型（交互→收键盘；切域清排序会话）
    func switchType(to newType: TransactionType) {
        guard transactionType != newType else { return }
        categoryReorder.cancelDrag()
        showNumericKeypad = false
        withAnimation(HoloAnimation.standard) {
            transactionType = newType
            drillDownParent = nil
            selectedCategory = nil
        }
        Task { await loadRecentCategories() }
    }

    /// 排序落库：会话序（可见格）+ 未参与会话的同层行追加尾部，组装成同层全集
    /// 走 reorderCategories（全量校验 + iCloud 同步副本一并更新；分类管理页读同一字段）
    private func persistCategoryOrder(_ sessionIds: [UUID]) {
        let parentID = drillDownParent?.id
        let siblings = categories.filter { category in
            category.transactionType == transactionType
            && category.deletedAt == nil
            && category.parentId == parentID
        }
        let fullIds = CategoryGridReorderModel.fullSiblingOrder(sessionIds: sessionIds, siblings: siblings)

        do {
            try FinanceRepository.shared.reorderCategories(ids: fullIds, type: transactionType, parentID: parentID)
        } catch {
            HoloToastCenter.shared.show(error.localizedDescription, type: .error)
            Task { await loadCategories() } // 落库失败回滚显示到库内真实顺序
        }
    }

    /// 加载所有分类 + 最近常用
    /// 加载后同步清理已失效的 selectedCategory / drillDownParent 引用
    @MainActor
    func loadCategories() async {
        do {
            categories = try await FinanceRepository.shared.getAllCategories()
            await loadRecentCategories()
            cleanStaleCategoryRefs()
        } catch {
            Logger(subsystem: "com.holo.app", category: "CategoryGrid")
                .error("加载分类失败：\(error.localizedDescription)")
        }
    }

    /// 清理已删除分类的引用，避免 UI 访问已删除的 NSManagedObject 导致崩溃
    private func cleanStaleCategoryRefs() {
        let validIDs = Set(categories.map { $0.objectID })
        if let selected = selectedCategory, !validIDs.contains(selected.objectID) || selected.isDeleted {
            selectedCategory = nil
        }
        if let parent = drillDownParent, !validIDs.contains(parent.objectID) || parent.isDeleted {
            drillDownParent = nil
        }
    }

    /// 加载当前类型的最近常用分类
    @MainActor
    func loadRecentCategories() async {
        do {
            recentCategories = try await FinanceRepository.shared.getRecentCategories(
                type: transactionType
            )
        } catch {
            recentCategories = []
        }
    }
}
