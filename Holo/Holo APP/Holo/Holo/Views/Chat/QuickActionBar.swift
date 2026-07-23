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
