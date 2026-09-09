//
//  ChatInputView.swift
//  Holo
//
//  对话输入栏
//  TextField + 图片/语音/发送按钮
//  图片入口：截图识别记账（docs/plans/2026-09-09-screenshot-receipt-billing-plan.md §4）
//

import SwiftUI
import PhotosUI

struct ChatInputView: View {

    @ObservedObject var viewModel: ChatViewModel
    /// 点击输入框代表回到当前对话；由父视图在键盘出现前立即回到最新消息。
    let onInputActivated: () -> Void
    let onVoiceInputTap: () -> Void
    /// 选图完成（已加载原始数据）；附言取发送时的输入框文字
    var onImagePicked: ((Data) -> Void)?
    /// 选图失败（权限/加载），message 为可直接展示的用户文案
    var onImagePickFailed: ((String) -> Void)?

    /// 当前窗口宽度（v2 断点：宽屏输入条收窄居中）
    @Environment(\.holoWindowWidth) private var inputWindowWidth

    @State private var showImageSourceDialog = false
    @State private var showPhotoPicker = false
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var pendingCameraData: Data?
    @State private var isLoadingPick = false

    init(
        viewModel: ChatViewModel,
        onInputActivated: @escaping () -> Void = {},
        onVoiceInputTap: @escaping () -> Void = {},
        onImagePicked: ((Data) -> Void)? = nil,
        onImagePickFailed: ((String) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onInputActivated = onInputActivated
        self.onVoiceInputTap = onVoiceInputTap
        self.onImagePicked = onImagePicked
        self.onImagePickFailed = onImagePickFailed
    }

    var body: some View {
        VStack(spacing: 7) {
            if let draft = viewModel.continuationDraft {
                HStack(spacing: 10) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.holoPrimary)
                        .frame(width: 27, height: 27)
                        .background(Color.holoPrimary.opacity(0.10))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("继续追问这份分析")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.holoPrimary)
                        Text(draft.rootUserQuestion)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        viewModel.clearContinuationDraft()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "取消承接上一份分析"))
                }
                .padding(.leading, 10)
                .padding(.trailing, 5)
                .padding(.vertical, 6)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.holoPrimary.opacity(0.16), lineWidth: 1)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 12) {
                // 输入框
                TextField("输入消息...", text: $viewModel.inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(.holoBody)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.holoCardBackground)
                    .cornerRadius(20)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            onInputActivated()
                        }
                    )
                    .onSubmit {
                        // 流式中发送按钮已切换为停止键；回车不允许并发发送第二条消息
                        guard !viewModel.isStreaming else { return }
                        Task { await viewModel.sendMessage() }
                    }

                // 截图识别入口：拍照或选相册图（小票/支付截图）
                Button {
                    showImageSourceDialog = true
                } label: {
                    if isLoadingPick {
                        ProgressView()
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "photo.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(imageButtonColor)
                    }
                }
                .disabled(viewModel.isStreaming || isLoadingPick)
                .accessibilityLabel(String(localized: "图片识别记账"))

                Button {
                    onVoiceInputTap()
                } label: {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(voiceButtonColor)
                }
                .disabled(viewModel.isStreaming)
                .accessibilityLabel(String(localized: "语音输入"))

                // 发送/停止按钮：停止键在「普通流式进行中」或「存在等待/恢复中的 Agent 消息」
                // 时都要可见——Agent 等待网络/系统资源期间输入框已解锁可发新消息，但用户
                // 必须始终保有停止入口（cancelStreaming 会取消等待任务并定稿消息）。
                if viewModel.isStreaming || viewModel.hasActiveStreamingMessage {
                    Button {
                        viewModel.cancelStreaming()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.holoError)
                    }
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityLabel(String(localized: "停止生成"))
                } else {
                    Button {
                        Task { await viewModel.sendMessage() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(sendButtonColor)
                    }
                    .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    // 外接键盘 Cmd+回车发送。纯回车保留换行（TextField 竖轴默认行为），
                    // 不改 iPhone 软件键盘体验；停止键同样给 Cmd+.（系统标准取消）
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(String(localized: "发送消息"))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.holoBackground)
        // v2：宽屏输入条收窄居中（修复「一条宽带横在大屏中央」的观感）
        .frame(maxWidth: HoloAdaptiveLayout.isExpandedWidth(inputWindowWidth) ? 720 : .infinity)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.18), value: viewModel.continuationDraft != nil)
        .confirmationDialog(
            String(localized: "识别图片记账"),
            isPresented: $showImageSourceDialog,
            titleVisibility: .visible
        ) {
            Button(String(localized: "拍照")) {
                showCamera = true
            }
            Button(String(localized: "从相册选择")) {
                showPhotoPicker = true
            }
            Button(String(localized: "取消"), role: .cancel) {}
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $pickedItems,
            maxSelectionCount: 1,
            matching: .images,
            photoLibrary: .shared()
        )
        .fullScreenCover(
            isPresented: $showCamera,
            onDismiss: {
                // 捕获数据在 dismiss 后处理（任务/想法附件同范式，规避 sheet 竞态）
                guard let data = pendingCameraData else { return }
                pendingCameraData = nil
                onImagePicked?(data)
            }
        ) {
            CameraView(
                onCapture: { data in
                    pendingCameraData = data
                    showCamera = false
                },
                onDismiss: { showCamera = false }
            )
            .ignoresSafeArea()
        }
        .onChange(of: pickedItems) { _, newItems in
            guard let newItem = newItems.last else { return }
            pickedItems = []
            loadAndForward(item: newItem)
        }
    }

    // 相册入口按钮：PhotosPicker 本体（样式与图片按钮一致，叠在 dialog 场景之外直接可点）
    // 说明：confirmationDialog 的「从相册选择」无法命令式拉起 PHPicker，
    // 因此相册走这个独立按钮；dialog 只保留拍照入口与说明。
    private var imageButtonColor: Color {
        (viewModel.isStreaming || isLoadingPick) ? .holoTextSecondary.opacity(0.3) : .holoTextSecondary
    }

    private var voiceButtonColor: Color {
        viewModel.isStreaming ? .holoTextSecondary.opacity(0.3) : .holoTextSecondary
    }

    private var sendButtonColor: Color {
        return viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .holoTextSecondary.opacity(0.3)
            : .holoPrimary
    }

    private func loadAndForward(item: PhotosPickerItem) {
        isLoadingPick = true
        Task {
            let outcome = await PhotoLibraryImageLoader.loadImageData(from: item)
            await MainActor.run {
                isLoadingPick = false
                switch outcome {
                case .data(let data):
                    onImagePicked?(data)
                case .permissionRequired:
                    onImagePickFailed?(
                        String(localized: "需要相册权限才能选图识别。请在系统设置 > Holo > 照片中允许访问。")
                    )
                case .unavailable:
                    onImagePickFailed?(
                        String(localized: "这张图暂时加载不了（可能在 iCloud 里取不到），换一张试试。")
                    )
                }
            }
        }
    }
}
