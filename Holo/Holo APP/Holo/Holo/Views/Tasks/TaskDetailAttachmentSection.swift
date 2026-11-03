//
//  TaskDetailAttachmentSection.swift
//  Holo
//
//  任务详情附件区（附件网格 / 添加来源选择 / 相机权限）——
//  2026-10-24 随真机主线程栈溢出排险从 TaskDetailView 拆出（纯搬移，界面/行为零变化）。
//

import SwiftUI
#if canImport(UIKit)
#else
import AppKit
#endif
import CoreData
import AVFoundation
import OSLog

struct TaskDetailAttachmentSection: View {

    @ObservedObject var repository: TodoRepository
    let existingTask: TodoTask?
    @Binding var pendingImages: [UIImage]
    @Binding var showAttachmentGallery: Bool
    @Binding var galleryStartIndex: Int
    @Binding var showAttachmentCamera: Bool
    @Binding var showAttachmentPhotoPicker: Bool
    @Binding var attachmentsRevision: Int

    @State private var showAttachmentSourceChoice = false
    @State private var showCameraPermissionAlert = false

    private static let logger = Logger(subsystem: "com.holo.app", category: "TaskDetailView")

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("附件")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)

                let count = existingTask != nil ? (existingTask?.sortedAttachments.count ?? 0) : pendingImages.count
                if count > 0 {
                    Text("\(count)")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if let task = existingTask {
                existingTaskAttachmentGrid(task)
                    .padding(12)
            } else {
                newTaskAttachmentGrid
                    .padding(12)
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .confirmationDialog("添加附件", isPresented: $showAttachmentSourceChoice) {
            Button("拍照") {
                requestCameraAccess()
            }
            Button("从相册选择") {
                Task { @MainActor in
                    // 相册读取权限前置申请：iCloud 原图自动下载的前提；被拒不阻断选图
                    await PhotoLibraryImageLoader.requestLibraryAccessIfNeeded()
                    showAttachmentPhotoPicker = true
                }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("无法访问", isPresented: $showCameraPermissionAlert) {
            Button("取消", role: .cancel) {}
            Button("去设置") {
                #if canImport(UIKit)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                #else
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
                #endif
            }
        } message: {
            Text(String(localized: "请在系统设置中允许 Holo 访问相机"))
        }
    }

    @ViewBuilder
    private func existingTaskAttachmentGrid(_ task: TodoTask) -> some View {
        let _ = attachmentsRevision
        let attachments = task.sortedAttachments
        let attachmentItems = attachments.map {
            TaskAttachmentGridItem(id: $0.id, objectID: $0.objectID, thumbnailFileName: $0.thumbnailFileName, thumbnailData: $0.thumbnailData)
        }

        TaskAttachmentGrid(
            attachments: attachmentItems,
            taskId: task.id,
            maxCount: 9,
            onAdd: { showAttachmentSourceChoice = true },
            onDelete: { attachmentID in
                do {
                    try repository.deleteAttachment(with: attachmentID)
                    attachmentsRevision += 1
                } catch {
                    Self.logger.error("删除附件失败：\(error.localizedDescription)")
                }
            },
            onTap: { index in
                galleryStartIndex = index
                showAttachmentGallery = true
            }
        )
    }

    private var newTaskAttachmentGrid: some View {
        VStack(spacing: 8) {
            if !pendingImages.isEmpty {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ], spacing: 8) {
                    ForEach(Array(pendingImages.enumerated()), id: \.offset) { index, image in
                        #if canImport(UIKit)
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    pendingImages.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(.white)
                                        .shadow(color: .black.opacity(0.3), radius: 2)
                                }
                                .padding(4)
                            }
                        #else
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    pendingImages.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(.white)
                                        .shadow(color: .black.opacity(0.3), radius: 2)
                                }
                                .padding(4)
                            }
                        #endif
                    }

                    if pendingImages.count < 9 {
                        addAttachmentButton
                    }
                }
            } else {
                addAttachmentButton
            }
        }
    }

    private var addAttachmentButton: some View {
        Button {
            showAttachmentSourceChoice = true
        } label: {
            HStack {
                Image(systemName: "paperclip")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)

                Text("添加附件")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPlaceholder)

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showAttachmentCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        showAttachmentCamera = true
                    }
                }
            }
        default:
            showCameraPermissionAlert = true
        }
    }
}
