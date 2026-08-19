//
//  FeedbackSheet.swift
//  Holo
//
//  用户反馈面板（设置页「反馈给开发者」）
//  类型三选一 + 描述 + 截图（最多3张）+ 联系方式（微信/QQ/邮箱/手机）
//  → 提交到后端 POST /v1/feedback。
//  设计稿：docs/design-mockups/user-feedback-channel.html
//

import SwiftUI
import PhotosUI

/// 已选截图：展示用 image，提交用压缩后的 data。
private struct FeedbackShot: Identifiable {
    let id = UUID()
    let image: UIImage
    let data: Data
}

struct FeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let service: HoloFeedbackService

    @State private var category: FeedbackCategory = .suggestion
    @State private var content: String = ""
    @State private var contactKind: FeedbackContactKind = .wechat
    @State private var contactValue: String = ""
    @State private var shots: [FeedbackShot] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isProcessingImages = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didSucceed = false

    private let maxContentLength = 500
    private let maxShotCount = 3

    @MainActor
    init(service: HoloFeedbackService? = nil) {
        self.service = service ?? .shared
    }

    private var canSubmit: Bool {
        !isSubmitting
            && !isProcessingImages
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if didSucceed {
                successView
            } else {
                header
                ScrollView {
                    formView
                }
            }
        }
        .background(Color.holoBackground)
        .interactiveDismissDisabled(isSubmitting)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            Text("反馈给开发者")
                .font(.headline)
                .foregroundColor(.holoTextPrimary)
            Text("每一条反馈我们都会认真读")
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.holoTextSecondary)
            }
            .disabled(isSubmitting)
            .padding(.trailing, 20)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Form

    private var formView: some View {
        VStack(alignment: .leading, spacing: 18) {
            categorySection
            contentSection
            shotsSection
            contactSection
            diagnosticsBar

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundColor(.holoError)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            submitButton
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    // MARK: 类型

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("反馈类型", required: true)

            HStack(spacing: 9) {
                ForEach(FeedbackCategory.allCases) { item in
                    categoryCard(item)
                }
            }
        }
    }

    private func categoryCard(_ item: FeedbackCategory) -> some View {
        let isSelected = category == item
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                category = item
            }
        } label: {
            VStack(spacing: 6) {
                Text(item.emoji)
                    .font(.system(size: 24))
                    .scaleEffect(isSelected ? 1.15 : 1)
                Text(item.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.holoPrimary.opacity(0.07) : Color.holoCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.holoPrimary : Color.holoDivider, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 描述

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("详细描述", required: true)

            VStack(alignment: .trailing, spacing: 4) {
                TextEditor(text: $content)
                    .font(.system(size: 14))
                    .frame(height: 110)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .scrollContentBackground(.hidden)
                    .onChange(of: content) { _, newValue in
                        if newValue.count > maxContentLength {
                            content = String(newValue.prefix(maxContentLength))
                        }
                    }

                Text("\(content.count) / \(maxContentLength)")
                    .font(.system(size: 10.5))
                    .foregroundColor(.holoTextPlaceholder)
                    .padding(.trailing, 12)
                    .padding(.bottom, 8)
                    .monospacedDigit()
            }
            .background(Color.holoCardBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.holoDivider, lineWidth: 1)
            )
        }
    }

    // MARK: 截图

    private var shotsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("截图")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                Text("选填 · 最多 \(maxShotCount) 张")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.holoTextPlaceholder)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.holoDivider.opacity(0.4)))
            }

            HStack(spacing: 10) {
                ForEach(shots) { shot in
                    shotThumbnail(shot)
                }
                if shots.count < maxShotCount {
                    addShotButton
                }
                if isProcessingImages {
                    ProgressView()
                        .frame(width: 66, height: 88)
                }
            }

            Text("遇到问题时，一张截图最能说明情况；图片会自动去除位置信息")
                .font(.system(size: 10.5))
                .foregroundColor(.holoTextPlaceholder)
        }
    }

    private func shotThumbnail(_ shot: FeedbackShot) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: shot.image)
                .resizable()
                .scaledToFill()
                .frame(width: 66, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.holoDivider, lineWidth: 1)
                )

            Button {
                shots.removeAll { $0.id == shot.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.holoTextPrimary)
                    .background(Circle().fill(Color.white))
            }
            .offset(x: 6, y: -6)
        }
    }

    private var addShotButton: some View {
        PhotosPicker(
            selection: $pickerItems,
            maxSelectionCount: maxShotCount - shots.count,
            matching: .images
        ) {
            VStack(spacing: 4) {
                if isProcessingImages {
                    ProgressView()
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .light))
                        .foregroundColor(.holoTextPlaceholder)
                    Text("截图")
                        .font(.system(size: 10))
                        .foregroundColor(.holoTextPlaceholder)
                }
            }
            .frame(width: 66, height: 88)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.holoDivider, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            )
        }
        .onChange(of: pickerItems) { _, items in
            loadShots(items)
        }
    }

    private func loadShots(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isProcessingImages = true
        let remaining = maxShotCount - shots.count
        Task {
            var loaded: [FeedbackShot] = []
            for item in items.prefix(remaining) {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let jpeg = FeedbackImageCompressor.compress(data),
                      let image = UIImage(data: jpeg) else { continue }
                loaded.append(FeedbackShot(image: image, data: jpeg))
            }
            shots.append(contentsOf: loaded)
            pickerItems = []
            isProcessingImages = false
        }
    }

    // MARK: 联系方式

    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("联系方式")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                Text("选填")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.holoTextPlaceholder)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.holoDivider.opacity(0.4)))
            }

            HStack(spacing: 9) {
                Menu {
                    Picker("联系方式类型", selection: $contactKind) {
                        ForEach(FeedbackContactKind.allCases) { kind in
                            Text("\(kind.emoji) \(kind.label)").tag(kind)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(contactKind.emoji)
                        Text(contactKind.label)
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.holoDivider.opacity(0.4)))
                    .foregroundColor(.holoTextPrimary)
                }

                Rectangle()
                    .fill(Color.holoDivider)
                    .frame(width: 1, height: 22)

                TextField(contactKind.placeholder, text: $contactValue)
                    .font(.system(size: 14))
                    .foregroundColor(.holoTextPrimary)
                    .keyboardType(contactKind.isNumeric ? .numberPad : .default)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.holoCardBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.holoDivider, lineWidth: 1)
            )

            Text("留下联系方式，你的建议被采纳、或问题修复时，我们能第一时间找到你")
                .font(.system(size: 10.5))
                .foregroundColor(.holoTextSecondary)
        }
        .onChange(of: contactKind) { _, _ in
            contactValue = ""
        }
    }

    // MARK: 诊断信息

    private var diagnosticsBar: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundColor(.holoInfo)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                Text("将自动附带以下信息，仅用于定位问题")
                    .font(.system(size: 10.5))
                    .foregroundColor(.holoTextSecondary)

                HStack(spacing: 6) {
                    diagnosticChip("App \(appVersionText)")
                    diagnosticChip(osVersionText)
                    diagnosticChip("设备 \(maskedDeviceId)")
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.holoInfo.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.holoInfo.opacity(0.15), lineWidth: 1)
        )
    }

    private func diagnosticChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(.holoInfo)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.holoInfo.opacity(0.1)))
            .monospacedDigit()
    }

    private var appVersionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    private var osVersionText: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(version.majorVersion).\(version.minorVersion)"
    }

    private var maskedDeviceId: String {
        let raw = HoloBackendDeviceIdentity.shared.deviceId.replacingOccurrences(of: "-", with: "")
        guard raw.count > 6 else { return raw }
        return "\(raw.prefix(3))…\(raw.suffix(3))"
    }

    // MARK: 提交

    private var submitButton: some View {
        Button {
            submit()
        } label: {
            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView()
                        .tint(.white)
                }
                Text(isSubmitting ? "提交中…" : "提交反馈")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
        }
        .buttonStyle(.plain)
        .background(canSubmit ? Color.holoPrimary : Color.holoDivider.opacity(0.5))
        .foregroundColor(.white)
        .cornerRadius(14)
        .disabled(!canSubmit)
    }

    private func fieldLabel(_ text: String, required: Bool) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.holoTextSecondary)
            if required {
                Text("必填")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.holoPrimary.opacity(0.1)))
            }
        }
    }

    // MARK: - Success

    private var successView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.holoPrimary)

            Text("已收到你的反馈")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.holoTextPrimary)

            Text("我们会认真阅读每一条反馈\n如需进一步沟通，会通过你留下的联系方式与你联系")
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            HStack(spacing: 4) {
                Text("急事也可邮件")
                    .foregroundColor(.holoTextSecondary)
                Button {
                    if let url = HoloSupportContact.mailtoURL {
                        openURL(url)
                    }
                } label: {
                    Text(HoloSupportContact.email)
                        .underline()
                        .foregroundColor(.holoInfo)
                }
            }
            .font(.system(size: 12))

            Button {
                dismiss()
            } label: {
                Text("好 的")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .buttonStyle(.plain)
            .background(Color.holoPrimary)
            .foregroundColor(.white)
            .cornerRadius(14)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    // MARK: - Actions

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil

        Task {
            do {
                try await service.submit(
                    category: category,
                    content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                    contactKind: contactKind,
                    contactValue: contactValue,
                    images: shots.map(\.data),
                    appVersion: appVersionText,
                    osVersion: osVersionText
                )
                didSucceed = true
            } catch {
                errorMessage = "提交失败：\(error.localizedDescription)"
            }
            isSubmitting = false
        }
    }
}

#Preview {
    FeedbackSheet()
        .preferredColorScheme(.light)
}
