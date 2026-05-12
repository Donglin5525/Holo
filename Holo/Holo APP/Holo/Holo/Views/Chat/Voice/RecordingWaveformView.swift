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

    @State private var samples: [CGFloat] = Array(repeating: 0, count: 36)
    @State private var smoothedAmplitude: CGFloat = 0
    @State private var samplePhase: CGFloat = 0
    @State private var loadingPhase: CGFloat = 0

    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(samples.indices, id: \.self) { index in
                Capsule()
                    .fill(barColor(for: index))
                    .frame(width: 4, height: 3 + samples[index] * 68)
                    .animation(.interpolatingSpring(stiffness: 170, damping: 24), value: samples[index])
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

        guard isRecording, !isFrozen else {
            smoothedAmplitude *= 0.82
            appendSample(smoothedAmplitude)
            return
        }

        let power = recordingService.currentPowerLevel()
        let targetAmplitude = WaveformSampleMapper.normalizedAmplitude(fromPower: power)
        smoothedAmplitude = smoothedAmplitude * 0.68 + targetAmplitude * 0.32
        appendSample(smoothedAmplitude)
    }

    private func barColor(for index: Int) -> Color {
        if isLoading {
            return Color.holoPrimary.opacity(index.isMultiple(of: 2) ? 0.45 : 0.8)
        }
        return Color.holoPrimary.opacity(0.28 + Double(samples[index]) * 0.68)
    }

    private func appendSample(_ amplitude: CGFloat) {
        samplePhase += 0.42
        let shimmer = 0.92 + (sin(samplePhase) + 1) * 0.08
        let nextSample = min(1, max(0, amplitude * shimmer))

        samples.append(nextSample)
        if samples.count > 36 {
            samples.removeFirst()
        }
    }
}

enum WaveformSampleMapper {
    static func normalizedAmplitude(fromPower power: Float) -> CGFloat {
        let clampedPower = max(-60, min(0, power))
        let linear = CGFloat((clampedPower + 60) / 60)
        guard linear > 0.04 else { return 0 }
        return min(1, pow(linear, 0.58) * 1.18)
    }
}
