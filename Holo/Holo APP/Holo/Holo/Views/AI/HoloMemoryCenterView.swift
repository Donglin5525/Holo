//
//  HoloMemoryCenterView.swift
//  Holo
//
//  所有入口统一展示领域/跨域记忆，不再旁路读取旧 JSON Store。
//

import SwiftUI

struct HoloMemoryCenterView: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            DomainMemorySection()
                .padding(HoloSpacing.lg)
        }
        .background(Color.holoBackground.ignoresSafeArea())
        .navigationTitle("记忆管理")
        .navigationBarTitleDisplayMode(.inline)
    }
}
