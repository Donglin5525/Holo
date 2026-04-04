//
//  QuickActionBar.swift
//  Holo
//
//  快捷操作栏
//  横向滚动的快捷模板按钮
//

import SwiftUI

struct QuickActionBar: View {

    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(QuickAction.allCases, id: \.self) { action in
                    Button {
                        viewModel.sendQuickAction(action)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: action.icon)
                                .font(.system(size: 12))
                            Text(action.rawValue)
                                .font(.system(size: 13))
                        }
                        .foregroundColor(.holoPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.holoPrimary.opacity(0.1))
                        .cornerRadius(16)
                    }
                    .disabled(viewModel.isStreaming)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }
}
