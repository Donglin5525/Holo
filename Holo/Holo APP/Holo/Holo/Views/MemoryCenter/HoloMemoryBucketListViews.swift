//
//  HoloMemoryBucketListViews.swift
//  Holo
//
//  「过去的记忆」与「已停用」两个次级页（方案 §3.2 M04/M05；
//  视觉契约 = 原型画面 13/14）。从管理页「更多」进入，不占主分段。
//

import Combine
import SwiftUI

@MainActor
final class HoloMemoryBucketListViewModel: ObservableObject {
    enum ListState: Equatable {
        case loading
        case loaded([HoloMemoryManagementProjection])
        case failed
    }

    @Published private(set) var state: ListState = .loading
    @Published var notice: String?

    let bucket: HoloMemoryManagementBucket
    private var service: HoloMemoryUserControlService?

    init(bucket: HoloMemoryManagementBucket) {
        self.bucket = bucket
    }

    func load() async {
        state = .loading
        do {
            let repository = try await HoloMemoryRuntime.shared.repository()
            let controller = try await HoloMemoryRuntime.shared.persistenceController()
            let service = HoloMemoryUserControlService(
                repository: repository,
                eventStore: HoloMemoryControlEventStore(controller: controller)
            )
            self.service = service
            _ = try? await service.reconcileOutstanding()
            let readService = HoloMemoryManagementReadService(repository: repository)
            let snapshot = try await readService.loadSnapshot(answeringEnabled: true)
            state = .loaded(snapshot.applying(.init(bucket: bucket)))
        } catch {
            NSLog("[HoloMemoryBucketList] 加载失败: \(String(describing: error))")
            state = .failed
        }
    }

    func perform(_ action: HoloMemoryUserControlAction, on projection: HoloMemoryManagementProjection) async {
        guard let service else { return }
        do {
            let request = HoloMemoryUserControlRequest(
                operationID: "op-\(UUID().uuidString)",
                recordID: projection.recordID,
                expectedContentVersion: projection.contentVersion,
                action: action,
                issuedAt: Date()
            )
            let outcome = try await service.apply(request, projection: projection)
            switch outcome {
            case .applied, .alreadyApplied:
                await load()
            case .conflict:
                notice = "这条记忆已有新修改，已刷新。"
                await load()
            default:
                notice = "没做成：内容没有变化，稍后再试。"
            }
        } catch {
            notice = "暂时没做成，稍后再试一次。"
        }
    }
}

/// 通用次级页（过去/停用共用骨架：说明 + 单容器列表 + 行标签 + 行内操作）。
struct HoloMemoryBucketListView: View {
    @StateObject private var viewModel: HoloMemoryBucketListViewModel
    @Environment(\.dismiss) private var dismiss

    init(bucket: HoloMemoryManagementBucket) {
        _viewModel = StateObject(wrappedValue: HoloMemoryBucketListViewModel(bucket: bucket))
    }

    private var isStopped: Bool { viewModel.bucket == .stopped }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: HoloSpacing.sm) {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.holoToolText)
                        .frame(width: 34, height: 34)
                        .background(Color.holoToolSurface, in: Circle())
                        .overlay(Circle().strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
                }
                .accessibilityLabel("返回")
                Text(isStopped ? "已停用" : "过去的记忆")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.holoToolText)
                    .padding(.leading, 4)
                Spacer()
            }
            .padding(.horizontal, HoloSpacing.md)
            .frame(height: 50)

            content
        }
        .background(Color.holoToolBackground)
        .buttonStyle(.plain)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            VStack(spacing: HoloSpacing.md) {
                Text("加载失败").holoText(.sectionTitle).foregroundStyle(Color.holoToolText)
                Button("重试") { Task { await viewModel.load() } }
                    .holoText(.body).foregroundStyle(Color.holoToolAction)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let rows):
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(isStopped
                         ? "停用 = 不再影响回答，内容保留、随时恢复；删除 = 清除内容本身。"
                         : "已经过期、被替代或来源失效的理解。只作回看，不会用于现在的回答。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .lineSpacing(3)
                        .padding(.top, 4)

                    if let notice = viewModel.notice {
                        Text(notice)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.holoToolWarning)
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.holoToolWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .padding(.top, 10)
                    }

                    if rows.isEmpty {
                        VStack(spacing: HoloSpacing.sm) {
                            Text(isStopped ? "没有停用的记忆" : "没有过去的记忆")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.holoToolText)
                            Text(isStopped ? "停用的内容会出现在这里。" : "过期或被替代的理解会出现在这里。")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.holoToolTextSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.recordID) { index, projection in
                                row(projection)
                                if index < rows.count - 1 {
                                    Rectangle()
                                        .fill(Color.holoToolBorder.opacity(0.5))
                                        .frame(height: 0.5)
                                        .padding(.leading, 15)
                                }
                            }
                        }
                        .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.lg))
                        .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
                        .padding(.top, 14)

                        Text(isStopped
                             ? "重新启用会重新校验来源、时效与适用范围，通过后才回到「已记住」。停用期间，相同说法的理解不会自动重建。"
                             : "每条都会写明原因。如果某个「过去」又变回了现在，进详情重新核对即可。")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.holoToolTextSecondary.opacity(0.85))
                            .lineSpacing(3)
                            .padding(.top, 12)
                    }
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.bottom, 28)
            }
        }
    }

    private func row(_ projection: HoloMemoryManagementProjection) -> some View {
        HStack(alignment: .center, spacing: 10) {
            // 陈述区进详情；操作按钮独立并排，不嵌套在链接 label 内（§12 独立操作）。
            NavigationLink {
                HoloMemoryCenterDetailView(recordID: projection.recordID)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(projection.displayText.isEmpty ? "（内容已删除）" : projection.displayText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.holoToolText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        ForEach(HoloMemoryRowTags.tags(for: projection), id: \.text) { tag in
                            HoloMemoryTagBadge(tag: tag)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            if isStopped && projection.allowedActions.contains(.restore) {
                Button("重新启用") {
                    Task { await viewModel.perform(.restore, on: projection) }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.holoToolAction)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Color.holoToolSurface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.holoToolAction.opacity(0.5), lineWidth: 1))
                .accessibilityLabel("重新启用")
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.holoToolTextSecondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
