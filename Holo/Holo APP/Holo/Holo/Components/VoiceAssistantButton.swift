//
//  VoiceAssistantButton.swift
//  Holo
//
//  中央语音助手按钮组件
//  带有渐变背景、发光效果和多层装饰圆环
//

import SwiftUI

/// 中央语音助手按钮
/// 设计特点：
/// - 渐变背景 (浅橙 -> 主橙 -> 深橙)
/// - 多层装饰圆环
/// - 外发光效果
/// - 底部提示文字
struct VoiceAssistantButton: View {
    
    // MARK: - Properties
    
    /// 按钮点击回调
    let action: () -> Void
    
    /// 按钮是否处于激活状态
    @State private var isAnimating = false
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 24) {
            // 主按钮区域
            ZStack {
                // 最外层装饰圆环 (320pt)
                outerRing(size: 320, opacity: 0.05)
                
                // 中层装饰圆环 (256pt)
                outerRing(size: 256, opacity: 0.1)
                
                // 主按钮 (192pt)
                mainButton
            }
            .frame(width: 192, height: 192)
            
            // 底部提示文字
            Text("Tap to speak")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
    }
    
    // MARK: - 子视图
    
    /// 装饰圆环
    /// - Parameters:
    ///   - size: 圆环尺寸
    ///   - opacity: 边框透明度
    /// - Returns: 圆环视图
    private func outerRing(size: CGFloat, opacity: Double) -> some View {
        Circle()
            .stroke(Color.holoPrimary.opacity(opacity), lineWidth: 1)
            .frame(width: size, height: size)
    }
    
    /// 主按钮
    private var mainButton: some View {
        Button(action: action) {
            ZStack {
                // 渐变背景
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .holoPrimaryLight,      // #FED7AA - 浅橙
                                .holoPrimary,           // #F46D38 - 主橙
                                .holoPrimaryDark        // #EA580C - 深橙
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                // 高光渐变叠加
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.4),
                                Color.white.opacity(0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(0.8)
                
                // 麦克风图标
                Image(systemName: "mic.fill")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 2)
            }
        }
        .frame(width: 192, height: 192)
        .shadow(color: .holoPrimary.opacity(0.3), radius: 30, x: 0, y: 0)
        .scaleEffect(isAnimating ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isAnimating)
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.holoBackground
            .ignoresSafeArea()
        
        VoiceAssistantButton {
            print("Voice assistant tapped")
        }
    }
}