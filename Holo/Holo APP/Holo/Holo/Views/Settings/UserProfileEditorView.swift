//
//  UserProfileEditorView.swift
//  Holo
//
//  用户头像与昵称的统一编辑入口。
//

import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

struct UserProfileEditorView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var avatarRepository = UserAvatarRepository.shared
    @AppStorage(UserDisplayNameSettings.displayNameKey)
    private var displayName = UserDisplayNameSettings.fallbackDisplayName

    @State private var nicknameDraft = ""
    @State private var didInitializeNickname = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showImageSourceMenu = false
    @State private var showRemoveConfirmation = false
    @State private var preparedCropData: Data?
    @State private var showCropEditor = false
    @State private var isProcessing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.xl) {
                    avatarEditor
                    nicknameEditor
                    privacyNote
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.xl)
                .holoContentColumn(paintsBackground: false)
            }
            .background(Color.holoBackground)
            .navigationTitle("个人资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onAppear {
            guard !didInitializeNickname else { return }
            nicknameDraft = UserDisplayNameSettings.isDisplayNameSet(displayName) ? displayName : ""
            didInitializeNickname = true
        }
        .confirmationDialog("更换头像", isPresented: $showImageSourceMenu, titleVisibility: .visible) {
            Button("从相册选择") { showPhotoPicker = true }
            Button("拍照") { requestCamera() }
            if avatarRepository.hasCustomAvatar {
                Button("移除当前头像", role: .destructive) { showRemoveConfirmation = true }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("照片会先让你调整圆形裁剪范围，再保存到 Holo。")
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItem,
            matching: .images
        )
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task { await loadSelectedPhoto(item) }
        }
        .sheet(isPresented: $showCamera) {
            CameraView(
                onCapture: { data in
                    showCamera = false
                    Task { await prepareImage(data) }
                },
                onDismiss: { showCamera = false }
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showCropEditor) {
            if let preparedCropData {
                UserAvatarCropView(
                    preparedData: preparedCropData,
                    isProcessing: isProcessing,
                    onCancel: {
                        showCropEditor = false
                        self.preparedCropData = nil
                    },
                    onConfirm: { selection in
                        Task { await saveCroppedAvatar(selection) }
                    }
                )
            }
        }
        .alert("移除头像？", isPresented: $showRemoveConfirmation) {
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) { removeAvatar() }
        } message: {
            Text("移除会同步到你的其他设备，之后仍可重新上传。")
        }
        .alert("无法完成", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "请稍后重试")
        }
        .overlay {
            if isProcessing {
                ZStack {
                    Color.black.opacity(0.16).ignoresSafeArea()
                    ProgressView("正在处理头像…")
                        .padding(.horizontal, HoloSpacing.xl)
                        .padding(.vertical, HoloSpacing.lg)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: HoloRadius.lg))
                }
            }
        }
        .interactiveDismissDisabled(isProcessing)
    }

    private var avatarEditor: some View {
        VStack(spacing: HoloSpacing.md) {
            Button {
                showImageSourceMenu = true
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    UserAvatarView(size: 112)

                    Image(systemName: "camera.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.holoPrimary, in: Circle())
                        .overlay(Circle().stroke(Color.holoBackground, lineWidth: 3))
                }
            }
            .buttonStyle(.plain)
            .disabled(isProcessing)
            .accessibilityLabel(avatarRepository.hasCustomAvatar ? "更换头像" : "上传头像")

            Text(avatarRepository.hasCustomAvatar ? "轻点更换头像" : "添加一张头像")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
    }

    private var nicknameEditor: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("昵称")
                .font(.holoBody)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)

            HStack(spacing: HoloSpacing.sm) {
                TextField("怎么称呼你", text: $nicknameDraft)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit(saveNickname)

                Button("保存", action: saveNickname)
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .disabled(UserDisplayNameSettings.normalizedDisplayName(nicknameDraft) == nil)
            }
            .padding(.horizontal, HoloSpacing.md)
            .frame(minHeight: 50)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))

            Text("昵称和头像会随你的私人 iCloud 同步。")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
    }

    private var privacyNote: some View {
        Label {
            Text("Holo 只保存裁剪后的头像，不保存原图，也不会把头像发送给 AI 或 Holo 后端。")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        } icon: {
            Image(systemName: "lock.shield.fill")
                .foregroundColor(.holoPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
    }

    private func saveNickname() {
        guard let normalized = UserDisplayNameSettings.normalizedDisplayName(nicknameDraft) else { return }
        UserPreferenceRepository.shared.setDisplayName(normalized)
        nicknameDraft = normalized
        HapticManager.light()
    }

    private func loadSelectedPhoto(_ item: PhotosPickerItem) async {
        selectedPhotoItem = nil
        isProcessing = true
        let outcome = await PhotoLibraryImageLoader.loadImageData(from: item)
        switch outcome {
        case .data(let data):
            await prepareImage(data, managesLoadingState: false)
        case .permissionRequired:
            errorMessage = "需要允许 Holo 读取相册，才能下载并使用这张照片。"
        case .limitedAccess:
            errorMessage = "这张照片不在 Holo 可访问的范围内，请在系统设置中允许访问或换一张照片。"
        case .cloudDownloadFailed:
            errorMessage = "无法从 iCloud 下载原图，请检查网络后重试。"
        case .unavailable:
            errorMessage = "无法读取这张照片，请换一张试试。"
        }
        isProcessing = false
    }

    private func prepareImage(_ data: Data, managesLoadingState: Bool = true) async {
        if managesLoadingState { isProcessing = true }
        defer { if managesLoadingState { isProcessing = false } }
        do {
            preparedCropData = try await UserAvatarImageProcessor.prepareForCropping(data)
            showCropEditor = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveCroppedAvatar(_ selection: UserAvatarCropSelection) async {
        guard let preparedCropData else { return }
        isProcessing = true
        defer { isProcessing = false }
        do {
            let data = try await UserAvatarImageProcessor.renderAvatar(
                preparedData: preparedCropData,
                selection: selection
            )
            try avatarRepository.saveAvatarData(data)
            showCropEditor = false
            self.preparedCropData = nil
            HapticManager.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeAvatar() {
        do {
            try avatarRepository.removeAvatar()
            HapticManager.light()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func requestCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "当前设备没有可用的相机。"
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if granted {
                    showCamera = true
                } else {
                    errorMessage = "需要允许 Holo 使用相机，才能拍摄头像。"
                }
            }
        default:
            errorMessage = "相机权限未开启，请在系统设置中允许 Holo 使用相机。"
        }
    }
}
