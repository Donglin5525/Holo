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
        .buttonStyle(KeypadButtonStyle(pressedTint: pressedTint))
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

    /// 按压叠层色：✓ 已是品牌橙底，按压改用黑色遮罩变深；其余按键叠加品牌橙半透明
    private var pressedTint: Color {
        key == "✓" ? Color.black.opacity(0.12) : Color.holoPrimary.opacity(0.16)
    }
}

// MARK: - Keypad Button Press Animation

/// 键盘按钮按压缩放动画 + 品牌色按压反馈
struct KeypadButtonStyle: ButtonStyle {
    /// 按压时叠加的颜色（默认品牌橙，✓ 用黑色遮罩模拟按下变深）
    var pressedTint: Color = Color.holoPrimary.opacity(0.16)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(pressedTint)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}
