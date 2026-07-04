//
//  KanbanMoodSection.swift
//  Holo
//
//  今日看板 — 今日记录输入卡片
//  输入内容自动同步到观点模块
//

import SwiftUI
import os.log

struct KanbanMoodSection: View {

    @State private var text: String = ""
    @State private var isSaved: Bool = false

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            sectionHeader

            VStack(spacing: 10) {
                textEditor

                if isSaved {
                    savedView
                } else {
                    saveRow
                }
            }
            .padding(16)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
            .shadow(color: HoloShadow.card, radius: 4, y: 1)
        }
    }

    private var sectionHeader: some View {
        HStack {
            Label("今日记录", systemImage: "pencil.line")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var textEditor: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(Color.holoBackground)

            if text.isEmpty {
                Text("记录今天发生了什么...")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPlaceholder)
                    .padding(12)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 80)
                .padding(8)
                .disabled(isSaved)
        }
    }

    private var saveRow: some View {
        HStack {
            Spacer()
            saveButton
        }
    }

    private var saveButton: some View {
        Button { saveRecord() } label: {
            Text("保存")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(canSave ? Color.holoPrimary : Color.holoPrimary.opacity(0.4))
                .clipShape(Capsule())
        }
        .disabled(!canSave)
    }

    private var savedView: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.holoSuccess)
            Text("已保存到观点模块")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.holoSuccess)
        }
    }

    // MARK: - Actions

    private func saveRecord() {
        do {
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }

            let repo = ThoughtRepository()
            _ = try repo.create(
                content: content,
                mood: nil,
                tags: []
            )

            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isSaved = true
            }
            HapticManager.success()
        } catch {
            Logger(subsystem: "com.holo.app", category: "UI").error("保存今日记录失败: \(error.localizedDescription)")
        }
    }
}
