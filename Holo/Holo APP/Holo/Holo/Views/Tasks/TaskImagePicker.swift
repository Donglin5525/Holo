//
//  TaskImagePicker.swift
//  Holo
//
//  图片选择器 — confirmationDialog 选择来源，独立呈现拍照/相册
//

import SwiftUI
import PhotosUI
import AVFoundation

struct TaskImagePicker: View {
    let remainingSlots: Int
    let onSelectImages: ([UIImage]) -> Void

    @State private var showSourceChoice = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showPermissionAlert = false
    @State private var permissionMessage = ""

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .confirmationDialog("添加附件", isPresented: $showSourceChoice) {
                Button("拍照") {
                    requestCameraAccess()
                }
                Button("从相册选择") {
                    showPhotoPicker = true
                }
                Button("取消", role: .cancel) {}
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $selectedPhotos,
                maxSelectionCount: remainingSlots,
                matching: .images
            )
            .onChange(of: selectedPhotos) { _, newItems in
                loadSelectedPhotos(newItems)
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraView(onCapture: { imageData in
                    if let image = UIImage(data: imageData) {
                        onSelectImages([image])
                    }
                    showCamera = false
                }, onDismiss: {
                    showCamera = false
                })
            }
            .alert("无法访问", isPresented: $showPermissionAlert) {
                Button("去设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(permissionMessage)
            }
    }

    /// 外部调用，弹出来源选择
    func present() {
        showSourceChoice = true
    }

    // MARK: - 相机权限

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        showCamera = true
                    }
                }
            }
        default:
            permissionMessage = "请在系统设置中允许 Holo 访问相机"
            showPermissionAlert = true
        }
    }

    // MARK: - 加载选中图片

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }

        Task {
            var images: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    images.append(image)
                }
            }
            selectedPhotos = []
            if !images.isEmpty {
                onSelectImages(images)
            }
        }
    }
}

// MARK: - Camera View (UIImagePickerController Wrapper)

struct CameraView: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onDismiss: onDismiss)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data) -> Void
        let onDismiss: () -> Void

        init(onCapture: @escaping (Data) -> Void, onDismiss: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onDismiss = onDismiss
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.85) {
                onCapture(data)
            } else {
                onDismiss()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onDismiss()
        }
    }
}
