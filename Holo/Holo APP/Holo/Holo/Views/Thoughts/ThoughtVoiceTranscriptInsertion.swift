//
//  ThoughtVoiceTranscriptInsertion.swift
//  Holo
//
//  观点语音输入文本插入辅助
//

import Foundation

enum ThoughtVoiceTranscriptInsertion {
    static func makeInsertionText(
        transcript: String,
        currentContent: String,
        selectedRange: NSRange
    ) -> String {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
