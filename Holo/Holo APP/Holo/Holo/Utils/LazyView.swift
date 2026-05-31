//
//  LazyView.swift
//  Holo
//
//  延迟构建视图的包装器
//  用于 .sheet / .fullScreenCover 闭包中，避免 SwiftUI 在 sheet 未呈现时就构建目标视图
//

import SwiftUI

struct LazyView<Content: View>: View {
    let build: () -> Content
    var body: some View { build() }
}
