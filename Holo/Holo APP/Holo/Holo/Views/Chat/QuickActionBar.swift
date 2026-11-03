//
//  QuickActionBar.swift
//  Holo
//
//  常驻能力行
//  输入框上方横向滚动的 AI 能力入口，对话全程可见。
//

import SwiftUI

struct QuickActionBar: View {

    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.persistentCapabilities) { capability in
                    // 「一个发现」胶囊插在「周期回放」之前（常驻行顺序：深度分析/一个发现/周期回放/规划目标）；
                    // 仅有效发现时渲染，无数字无红点无闪烁（01 §1）
                    if capability.id == .periodReplay {
                        DiscoveryCapsuleView(state: viewModel.discoveryPresentationState) {
                            viewModel.openDiscoveryFinding()
                        }
                    }
                    Button {
                        viewModel.handleCapabilityTap(capability)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: capability.systemImage)
                                .font(.system(size: 12))
                            Text(capability.title)
                                .font(.system(size: 13))
                            // 「深度分析」是可展开的场景面板入口：箭头随面板开合翻转，
                            // 告诉用户这颗胶囊点开还有一层（其余胶囊保持直发语义）
                            if capability.id == .recentAnalysis {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .rotationEffect(.degrees(viewModel.showAnalysisScenarioPanel ? 180 : 0))
                            }
                        }
                        .foregroundColor(capability.isEmphasized ? .white : .holoPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            capability.isEmphasized
                                ? Color.holoPrimary
                                : Color.holoPrimary.opacity(0.1)
                        )
                        .cornerRadius(16)
                        // 能力名称可由配置扩展，横向滚动时不让父级压缩胶囊内容
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .disabled(viewModel.isStreaming || !capability.isEnabled)
                    .opacity(capability.isEnabled ? 1.0 : 0.5)
                    .accessibilityHint(capability.id == .recentAnalysis ? String(localized: "展开分析场景目录") : "")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }
}
