//
//  ThoughtVoiceTranscriptInsertion.swift
//  Holo
//
//  观点语音输入文本插入辅助
//

import Foundation

enum ThoughtVoiceInsertionStatus: Equatable {
    case polished, restored
}

/// 只在当前编辑器会话保存，用实际插入后的 UTF-16 范围定位这一段。
struct ThoughtVoiceReplacement {
    let expectedDocument: String
    let range: NSRange
    let alternate: String
    let status: ThoughtVoiceInsertionStatus

    func reversing(in document: String) -> ThoughtVoiceReplacement? {
        guard document.utf16.elementsEqual(expectedDocument.utf16),
              let stringRange = Range(range, in: document) else { return nil }
        let previous = String(document[stringRange])
        return ThoughtVoiceReplacement(
            expectedDocument: document.replacingCharacters(in: stringRange, with: alternate),
            range: NSRange(location: range.location, length: alternate.utf16.count),
            alternate: previous,
            status: status == .polished ? .restored : .polished
        )
    }
}

enum ThoughtVoiceTranscriptInsertion {
    static func makeInsertionText(
        transcript: String,
        currentContent: String,
        selectedRange: NSRange
    ) -> String {
        formatTranscriptForInsertion(transcript)
    }

    private static func formatTranscriptForInsertion(_ transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 100 else {
            return trimmed
        }

        if trimmed.contains("\n") {
            return normalizeExistingLineBreaks(in: trimmed)
        }

        let sentences = splitSentences(trimmed)
        guard sentences.count > 1 else {
            return trimmed
        }

        let paragraphs = mergeSentencesIntoReadableParagraphs(sentences)
        guard paragraphs.count > 1 else {
            return trimmed
        }

        return paragraphs.joined(separator: "\n\n")
    }

    private static func normalizeExistingLineBreaks(in text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let sentenceEndings: Set<Character> = ["。", "！", "？", "；", ".", "!", "?", ";"]

        for character in text {
            current.append(character)
            if sentenceEndings.contains(character) {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
                current = ""
            }
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            sentences.append(tail)
        }

        return sentences
    }

    private static func mergeSentencesIntoReadableParagraphs(_ sentences: [String]) -> [String] {
        var paragraphs: [String] = []
        var current = ""

        for sentence in sentences {
            guard !current.isEmpty else {
                current = sentence
                continue
            }

            let merged = current + sentence
            if merged.count <= 52, current.count < 28, sentence.count < 28 {
                current = merged
            } else {
                paragraphs.append(current)
                current = sentence
            }
        }

        if !current.isEmpty {
            paragraphs.append(current)
        }

        return paragraphs
    }
}
