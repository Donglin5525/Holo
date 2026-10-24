//
//  TaskListFilterBar.swift
//  Holo
//
//  任务首页筛选器（过滤胶囊 / 清单菜单 / 归档入口 / 排序胶囊）——
//  2026-10-24 随真机主线程栈溢出排险从 TaskListView 拆出（纯搬移，界面/行为零变化）。
//

import SwiftUI

struct TaskListFilterBar: View {

    @ObservedObject var repository: TodoRepository
    let overdueCount: Int
    @Binding var selectedFilter: TaskFilterType
    @Binding var sortOption: TaskSortOption
    @Binding var sortAscending: Bool
    @Binding var showSortSheet: Bool
    @Binding var showArchiveManagement: Bool

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // 「今日」为第一视图（任务模块最高频视角）
                    filterChip(.today)
                    filterChip(.inbox)
                    filterChip(.all)
                    filterChip(.completed)

                    // 过期：带红色计数角标
                    filterChip(.overdue)
                        .overlay(alignment: .topTrailing) {
                            if overdueCount > 0 {
                                Text("\(overdueCount)")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(Color.holoError))
                                    .offset(x: 5, y: -5)
                                    .allowsHitTesting(false)
                            }
                        }

                    // 清单筛选收纳为单入口
                    listMenuChip

                    // 归档入口
                    Button {
                        showArchiveManagement = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "archivebox")
                                .font(.system(size: 12, weight: .medium))
                            Text("归档")
                                .font(.holoCaption)
                        }
                        .foregroundColor(.holoTextSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(Color.holoCardBackground)
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            style: StrokeStyle(lineWidth: 1, dash: [4])
                                        )
                                        .foregroundColor(.holoDivider)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, HoloSpacing.xs)
                // 右侧留白到胶囊间距一档：滚到最右时最后一枚胶囊不硬贴排序按钮
                .padding(.trailing, HoloSpacing.md)
            }
            // 右缘渐隐：横向滚动容器无系统指示条，给出「还有更多」的暗示，
            // 避免最后一枚胶囊在视口边缘被直线硬切（iPad 双栏窄列下尤其明显）
            .overlay(alignment: .trailing) {
                LinearGradient(
                    colors: [.holoBackground.opacity(0), .holoBackground],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 14)
                .allowsHitTesting(false)
            }

            // 排序入口固定筛选条右端：不随过滤胶囊滚动、始终可见
            // （非默认排序时高亮显示当前排法，让排序状态可见、可改）
            sortChip
        }
        .padding(.vertical, HoloSpacing.md)
        .background(Color.holoBackground)
    }

    /// 所有清单（包括没有文件夹的）
    private var allLists: [TodoList] {
        repository.allActiveLists()
    }

    /// 当前上下文的默认排序（主列表=截止时间早→晚，已完成页=完成时间最近在前）
    private var contextDefaultSort: TaskSortOption {
        selectedFilter == .completed ? .completed : .due
    }

    /// 排序胶囊：默认与过滤胶囊同族样式；用户改过排序后浅橙底 + 橙字显示当前排法
    private var sortChip: some View {
        let isDefault = sortOption == contextDefaultSort
            && sortAscending == contextDefaultSort.defaultAscending

        return Button {
            showSortSheet = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                Text(isDefault
                     ? String(localized: "排序")
                     : "\(sortOption.title) · \(sortOption.directionLabel(ascending: sortAscending))")
                    .font(.holoCaption)
                    .lineLimit(1)
            }
            .foregroundColor(isDefault ? .holoTextSecondary : .holoPrimaryDark)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(
                    isDefault ? Color.holoCardBackground : Color.holoPrimary.opacity(0.10)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    isDefault ? Color.holoDivider : Color.holoPrimary.opacity(0.35),
                    lineWidth: 1
                )
            )
            // 排序文案随选择变宽，fixedSize 防止胶囊被压成省略号（同清单胶囊）
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    /// 筛选胶囊：选中态为品牌橙渐变实底 + 轻投影（与 Hero 同源语言）
    private func filterChip(_ filter: TaskFilterType) -> some View {
        let isSelected = selectedFilter == filter

        return Button {
            withAnimation(HoloAnimation.quick) {
                selectedFilter = filter
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: filter.icon)
                    .font(.system(size: 12, weight: .medium))
                Text(filter.title)
                    .font(.holoCaption)
            }
            .foregroundColor(isSelected ? .white : .holoTextSecondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(LinearGradient(colors: [.holoPrimary, .holoPrimaryDark], startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color.holoCardBackground)
                )
            )
            .overlay(
                Capsule().strokeBorder(isSelected ? Color.clear : Color.holoDivider, lineWidth: 1)
            )
            .shadow(color: isSelected ? Color.holoPrimary.opacity(0.26) : .clear, radius: 6, x: 0, y: 3)
            // 横向滚动条中的胶囊按内容取宽，避免父级宽度提案裁掉首字符或图标
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }

    /// 清单筛选：Menu 收纳，选中后胶囊显示清单色点与名称
    private var listMenuChip: some View {
        let selectedList: TodoList? = {
            if case .list(let id) = selectedFilter {
                return allLists.first(where: { $0.id == id })
            }
            return nil
        }()

        return Menu {
            ForEach(allLists, id: \.id) { list in
                Button {
                    withAnimation(HoloAnimation.quick) {
                        selectedFilter = .list(list.id)
                    }
                } label: {
                    HStack {
                        Text(list.name)
                        if selectedFilter == .list(list.id) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let list = selectedList {
                    Circle()
                        .fill(Color(hex: list.color ?? "#007AFF"))
                        .frame(width: 8, height: 8)
                    Text(list.name)
                        .font(.holoCaption)
                        .lineLimit(1)
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12, weight: .medium))
                    Text("清单")
                        .font(.holoCaption)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundColor(selectedList != nil ? .white : .holoTextSecondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(
                    selectedList != nil
                        ? AnyShapeStyle(LinearGradient(colors: [.holoPrimary, .holoPrimaryDark], startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color.holoCardBackground)
                )
            )
            .overlay(
                Capsule().strokeBorder(selectedList != nil ? Color.clear : Color.holoDivider, lineWidth: 1)
            )
            // Menu 换 label 内容时可能沿用旧的宽度提案；按内容取宽，且在清单切换时重建
            // Menu，避免旧的短文案布局缓存把新名称的首字符或色点裁掉。
            .fixedSize(horizontal: true, vertical: false)
        }
        .id(selectedList?.id)
    }
}
