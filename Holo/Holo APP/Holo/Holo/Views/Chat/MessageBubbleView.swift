//
//  MessageBubbleView.swift
//  Holo
//
//  消息气泡视图
//  区分用户/AI 消息样式
//

import SwiftUI

struct MessageBubbleView: View {

    let message: ChatMessage
    let streamingText: String?
    var onIntentTagTap: ((ChatMessage) -> Void)? = nil

    private var displayText: String {
        streamingText ?? message.content
    }

    private var isUser: Bool {
        message.role == "user"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser {
                Spacer(minLength: 60)
            }

            if !isUser {
                // AI 头像
                aiAvatar
            }

            // 气泡内容
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                bubbleContent

                // 意图标签
                if let intent = message.intent, !isUser {
                    intentTag(intent)
                }
            }

            if isUser {
                // 用户头像
                userAvatar
            }

            if !isUser {
                Spacer(minLength: 60)
            }
        }
    }

    // MARK: - Avatars

    private var aiAvatar: some View {
        Circle()
            .fill(Color.holoPrimary.opacity(0.15))
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundColor(.holoPrimary)
            }
    }

    private var userAvatar: some View {
        Circle()
            .fill(Color.blue.opacity(0.15))
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.blue)
            }
    }

    // MARK: - Bubble Content

    @ViewBuilder
    private var bubbleContent: some View {
        if message.isStreaming && displayText.isEmpty {
            // 加载中指示器
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.gray.opacity(0.5))
                        .frame(width: 6, height: 6)
                        .modifier(TypingDotAnimation(delay: Double(index) * 0.2))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(bubbleBackground)
            .clipShape(BubbleShape(isUser: isUser))
        } else {
            StreamingTextView(
                text: displayText,
                isStreaming: message.isStreaming && streamingText != nil
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubbleBackground)
            .clipShape(BubbleShape(isUser: isUser))
        }
    }

    private var bubbleBackground: Color {
        isUser ? Color.blue.opacity(0.12) : Color(.systemGray6)
    }

    // MARK: - Intent Tag

    private func intentTag(_ intent: String) -> some View {
        let isFinance = intent == "record_expense" || intent == "record_income"
        let hasTransaction = message.linkedTransactionId != nil

        return Button {
            if isFinance && hasTransaction {
                onIntentTagTap?(message)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: intentIcon(intent))
                    .font(.system(size: 10))
                Text(intentLabel(intent))
                    .font(.system(size: 11))
                if isFinance && hasTransaction {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .foregroundColor(.holoPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.holoPrimary.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func intentIcon(_ intent: String) -> String {
        switch intent {
        case "record_expense", "record_income": return "yensign.circle"
        case "create_task": return "checklist"
        case "record_mood": return "heart.circle"
        case "check_in": return "flame.circle"
        default: return "sparkles"
        }
    }

    private func intentLabel(_ intent: String) -> String {
        switch intent {
        case "record_expense": return "已记账"
        case "record_income": return "已记账"
        case "create_task": return "已创建任务"
        case "record_mood": return "已记录心情"
        case "check_in": return "已打卡"
        default: return intent
        }
    }
}

// MARK: - Bubble Shape

struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        let tailSize: CGFloat = 6

        var path = Path()

        if isUser {
            // 用户消息：右下角有小尾巴
            path.addRoundedRect(in: CGRect(x: 0, y: 0, width: rect.width - tailSize, height: rect.height), cornerSize: CGSize(width: radius, height: radius))
            path.addRoundedRect(in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height - tailSize), cornerSize: CGSize(width: radius, height: radius))
        } else {
            // AI 消息：左下角有小尾巴
            path.addRoundedRect(in: CGRect(x: tailSize, y: 0, width: rect.width - tailSize, height: rect.height), cornerSize: CGSize(width: radius, height: radius))
            path.addRoundedRect(in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height - tailSize), cornerSize: CGSize(width: radius, height: radius))
        }

        return path
    }
}

// MARK: - Typing Animation

struct TypingDotAnimation: ViewModifier {
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(0.4)
            .animation(
                .easeInOut(duration: 0.6)
                    .repeatForever(autoreverses: true)
                    .delay(delay),
                value: true
            )
    }
}
