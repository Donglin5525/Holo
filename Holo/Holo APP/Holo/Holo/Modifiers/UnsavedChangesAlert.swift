//
//  UnsavedChangesAlert.swift
//  Holo
//
//  未保存修改确认弹窗
//  用于所有编辑视图的退出确认
//

import SwiftUI

/// 未保存修改确认弹窗 Modifier
/// 当用户尝试退出编辑页面时，如果有未保存的修改，弹出确认弹窗
struct UnsavedChangesAlert: ViewModifier {
    @Binding var isPresented: Bool
    let onConfirmDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("放弃修改？", isPresented: $isPresented) {
                Button("放弃", role: .destructive) {
                    onConfirmDismiss()
                }
                Button("继续编辑", role: .cancel) {}
            } message: {
                Text("你有未保存的修改，确定要退出吗？")
            }
    }
}

extension View {
    /// 添加未保存修改确认弹窗
    /// - Parameters:
    ///   - isPresented: 控制弹窗显示的绑定
    ///   - onConfirmDismiss: 确认放弃后执行的关闭操作
    func unsavedChangesAlert(
        isPresented: Binding<Bool>,
        onConfirmDismiss: @escaping () -> Void
    ) -> some View {
        self.modifier(UnsavedChangesAlert(
            isPresented: isPresented,
            onConfirmDismiss: onConfirmDismiss
        ))
    }
}
