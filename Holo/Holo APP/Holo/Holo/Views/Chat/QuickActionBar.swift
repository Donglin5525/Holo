//
//  QuickActionBar.swift
//  Holo
//
//  能力启动台
//  替代原有 CRUD 快捷按钮，展示高价值 AI 能力入口
//

import SwiftUI

struct QuickActionBar: View {

    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.capabilities) { capability in
                    Button {
                        viewModel.handleCapabilityTap(capability)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: capability.systemImage)
                                .font(.system(size: 12))
                            Text(capability.title)
                                .font(.system(size: 13))
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
                    }
                    .disabled(viewModel.isStreaming || !capability.isEnabled)
                    .opacity(capability.isEnabled ? 1.0 : 0.5)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }
}
