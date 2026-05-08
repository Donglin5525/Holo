//
//  TransactionKeypadComponents.swift
//  Holo
//
//  记账页面键盘组件 — KeypadButton + KeypadButtonStyle
//

import SwiftUI

// MARK: - Keypad Button

/// 键盘按钮
struct KeypadButton: View {
    let key: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                switch key {
                case "AC":
                    Text("AC")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.holoError)

                case "⌫":
                    Image(systemName: "delete.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                case "✓":
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)

                case "+", "-", "×", "÷":
                    Text(key)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                case "↩︎":
                    Image(systemName: "arrow.turn.down.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                case "00":
                    Text("00")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)

                default:
                    Text(key)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(buttonBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(KeypadButtonStyle())
    }

    /// 根据按键类型返回背景颜色
    private var buttonBackgroundColor: Color {
        switch key {
        case "✓":
            return Color.holoPrimary
        case "÷", "×", "-", "+", "⌫", "AC", "↩︎":
            return Color.holoBackground
        default:
            return Color.holoCardBackground
        }
    }
}

// MARK: - Keypad Button Press Animation

/// 键盘按钮按压缩放动画
struct KeypadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
