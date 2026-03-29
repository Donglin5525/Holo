//
//  MoodSelectorView.swift
//  Holo
//
//  观点模块 - 心情选择器
//  用于选择想法关联的心情
//

import SwiftUI

// MARK: - MoodSelectorView

/// 心情选择器视图
struct MoodSelectorView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    @Binding var selectedMood: ThoughtMoodType?

    // MARK: - Body

    var body: some View {
        NavigationView {
            VStack(spacing: HoloSpacing.md) {
                // 心情网格
                moodGrid

                // 清除选择按钮
                if selectedMood != nil {
                    clearButton
                }

                Spacer()
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.md)
            .background(Color.holoBackground)
            .navigationTitle("选择心情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundColor(.holoPurple)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Mood Grid

    private var moodGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: HoloSpacing.md) {
            ForEach(ThoughtMoodType.allCases, id: \.self) { mood in
                MoodCard(
                    mood: mood,
                    isSelected: selectedMood == mood
                ) {
                    selectedMood = mood
                    HapticManager.light()
                }
            }
        }
    }

    // MARK: - Clear Button

    private var clearButton: some View {
        Button {
            selectedMood = nil
            HapticManager.light()
        } label: {
            HStack {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 14))
                Text("清除选择")
                    .font(.holoCaption)
            }
            .foregroundColor(.holoTextSecondary)
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.sm)
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.md)
        }
    }
}

// MARK: - Mood Card

/// 心情卡片组件
struct MoodCard: View {
    let mood: ThoughtMoodType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: HoloSpacing.sm) {
                // Emoji 图标
                Text(mood.emoji)
                    .font(.system(size: 32))

                // 心情名称
                Text(mood.displayName)
                    .font(.holoCaption)
                    .foregroundColor(isSelected ? .white : .holoTextPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HoloSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(isSelected ? mood.color : mood.backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(isSelected ? mood.color : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Preview

#Preview {
    MoodSelectorView(selectedMood: .constant(.happy))
}