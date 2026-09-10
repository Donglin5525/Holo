//
//  DeviceIntelligenceIndexView.swift
//  Holo
//
//  设备智能索引状态页（语义图谱 V3 §4.1/§5.3）
//
//  AI 相关状态的唯一可见处：主页面不出现任何索引进度/失败/配额，
  // 用户主动进来才看到概括状态；提供「删除设备智能索引」销毁入口
//  （§5.3：销毁向量/候选/簇/摘要，不删除想法原文）。
//

import SwiftUI

struct DeviceIntelligenceIndexView: View {

    @State private var statusText = ""
    @State private var engineVersionText = ""
    @State private var showDestroyConfirm = false
    @State private var destroyed = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text("状态")
                        .font(.holoLabel)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoTextSecondary)
                    Text(statusText)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    if !engineVersionText.isEmpty {
                        Text(engineVersionText)
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(HoloSpacing.md)
                .background(RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .fill(Color.holoCardBackground))

                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text("这个索引是什么")
                        .font(.holoLabel)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoTextSecondary)
                    Text("Holo 在你的设备上为想法建立语义索引，用来静默归类主题、生成主题摘要。索引数据只存在本机，不上传 iCloud；云端只处理单次请求的最小内容，不留副本。删除索引不会删除你的想法。")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .lineSpacing(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(HoloSpacing.md)
                .background(RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .fill(Color.holoCardBackground))

                if !destroyed {
                    Button {
                        showDestroyConfirm = true
                    } label: {
                        Text("删除设备智能索引")
                            .font(.holoBody)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: HoloRadius.md)
                                .fill(Color.red.opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, HoloSpacing.sm)
                } else {
                    Label("索引已删除。重新开启后会在后台逐步重建。", systemImage: "checkmark.circle")
                        .font(.holoCaption)
                        .foregroundColor(.holoSuccess)
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.sm)
        }
        .background(Color.holoBackground)
        .navigationTitle(String(localized: "设备智能索引"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadStatus() }
        .alert("删除设备智能索引？", isPresented: $showDestroyConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await destroyIndex() }
            }
        } message: {
            Text("向量、候选关系、主题摘要将全部删除且不可恢复；你的想法原文、主题与标签不受影响。")
        }
    }

    @MainActor
    private func loadStatus() async {
        let indexFlag = ThoughtSemanticFeatureFlags.index
        guard indexFlag != .off,
              let store = await ThoughtSemanticPipeline.shared.store else {
            statusText = String(localized: "设备智能索引未开启")
            engineVersionText = ""
            return
        }
        let manifest = try? await store.manifest()
        let pending = (try? await store.pendingJobCount()) ?? 0
        if let manifest {
            engineVersionText = String(localized: "索引版本 \(manifest.activeModelVersion)")
        }
        if pending > 0 {
            statusText = String(localized: "最近内容已可用，历史内容仍在逐步整理（剩 \(pending) 条）")
        } else {
            statusText = String(localized: "你的想法已完成索引，最近内容随时可用")
        }
        destroyed = false
    }

    @MainActor
    private func destroyIndex() async {
        try? await ThoughtSemanticChangeFeed.shared.destroyIndex()
        destroyed = true
        statusText = String(localized: "设备智能索引未开启")
        engineVersionText = ""
    }
}
