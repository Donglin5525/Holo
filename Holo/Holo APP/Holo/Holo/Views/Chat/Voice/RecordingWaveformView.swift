//
//  RecordingWaveformView.swift
//  Holo
//
//  语音输入声波视图
//

import Combine
import SwiftUI

struct RecordingWaveformView: View {
    let recordingService: VoiceRecordingServiceProviding
    let isRecording: Bool
    let isFrozen: Bool
    let isLoading: Bool

    @State private var samples: [CGFloat] = Array(repeating: 0.18, count: 32)
    @State private var loadingPhase: CGFloat = 0

    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(samples.indices, id: \.self) { index in
                Capsule()
                    .fill(barColor(for: index))
                    .frame(width: 4, height: 12 + samples[index] * 52)
                    .animation(.easeOut(duration: 0.12), value: samples[index])
            }
        }
        .frame(height: 80)
        .frame(maxWidth: .infinity)
        .onReceive(timer) { _ in
            updateSamples()
        }
    }

    private func updateSamples() {
        if isLoading {
            loadingPhase += 0.35
            samples = samples.indices.map { index in
                let value = (sin(CGFloat(index) * 0.55 + loadingPhase) + 1) / 2
                return 0.16 + value * 0.72
            }
            return
        }

        guard isRecording, !isFrozen else { return }
        let power = recordingService.currentPowerLevel()
        let normalized = CGFloat(max(0, min(1, (power + 60) / 60)))
        samples.append(max(0.12, normalized))
        if samples.count > 32 {
            samples.removeFirst()
        }
    }

    private func barColor(for index: Int) -> Color {
        if isLoading {
            return Color.holoPrimary.opacity(index.isMultiple(of: 2) ? 0.45 : 0.8)
        }
        return Color.holoPrimary.opacity(0.35 + Double(samples[index]) * 0.55)
    }
}
