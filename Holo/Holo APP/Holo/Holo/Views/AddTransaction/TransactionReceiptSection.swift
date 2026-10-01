//
//  TransactionReceiptSection.swift
//  Holo
//
//  AddTransactionSheet 票根区 — 出票槽 + 堆叠 + 入口 + 选图/撕掉接线
//  新建模式：选图进内存待贴列表，保存交易时统一落库；编辑模式：贴/撕即时落库
//

import SwiftUI
import CoreData
import AVFoundation
import os

private let logger = Logger(subsystem: "com.holo.app", category: "TransactionReceiptSection")

extension AddTransactionSheet {

    /// 票根区（仅在有票时渲染）：顶部出票缝 + 堆叠舞台。
    /// 空态整块隐藏，唯一入口在信息卡「票根」行（2026-09-27 东林拍板 B 空态 + 保留打印机出票）
    var receiptSlotSection: some View {
        VStack(spacing: 6) {
            ReceiptSlotNotchView()

            TransactionReceiptStack(
                items: receiptItems,
                onTap: openReceiptGallery,
                onDetach: handleReceiptDetach
            )
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// 信息卡「票根」行右侧值：空态=添加（橙）；有票=N 张 · 再贴；满 3 张=禁用提示（灰）
    var receiptRowValue: String {
        let count = receiptItems.count
        if count == 0 { return String(localized: "添加") }
        if count >= Transaction.maxReceiptCount {
            return String(localized: "已贴满 \(Transaction.maxReceiptCount) 张")
        }
        return String(localized: "\(count) 张 · 再贴")
    }

    // MARK: - 来源选择覆盖弹窗

    /// 添加票根来源选择（拍照/从相册）：与账户/日期选择同款覆盖弹窗语言。
    /// 不用 confirmationDialog——iOS 26 本表单多 presentation 环境下不可靠（模拟器实测）
    var receiptSourcePopup: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(HoloAnimation.enter) {
                        showReceiptSourcePicker = false
                    }
                }

            VStack(spacing: 0) {
                Text(String(localized: "添加票根"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .padding(.top, 20)
                    .padding(.bottom, 8)

                Button {
                    withAnimation(HoloAnimation.enter) {
                        showReceiptSourcePicker = false
                    }
                    requestReceiptCameraAccess()
                } label: {
                    popupRow(icon: "camera.fill", iconColor: .holoPrimary, title: String(localized: "拍照"))
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 52)

                Button {
                    withAnimation(HoloAnimation.enter) {
                        showReceiptSourcePicker = false
                    }
                    Task { @MainActor in
                        await PhotoLibraryImageLoader.requestLibraryAccessIfNeeded()
                        showReceiptPhotoPicker = true
                    }
                } label: {
                    popupRow(icon: "photo.on.rectangle.angled", iconColor: .purple, title: String(localized: "从相册选择"))
                }
                .buttonStyle(.plain)

                Divider()

                Button(String(localized: "取消")) {
                    withAnimation(HoloAnimation.enter) {
                        showReceiptSourcePicker = false
                    }
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.holoTextSecondary)
                .padding(.vertical, 14)
            }
            .frame(maxWidth: 320)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
        }
        .transition(.opacity)
    }

    private func popupRow(icon: String, iconColor: Color, title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(iconColor)
                .frame(width: 24)

            Text(title)
                .font(.system(size: 15))
                .foregroundColor(.holoTextPrimary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    /// 相机权限链（被拒不阻断，弹去设置提示）
    func requestReceiptCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showReceiptCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        showReceiptCamera = true
                    }
                }
            }
        default:
            receiptPermissionMessage = String(localized: "请在系统设置中允许 Holo 访问相机")
            showReceiptPermissionAlert = true
        }
    }

    // MARK: - 数据装配

    /// 合成显示项：编辑态读交易附件（旧→新）+ 新建态待贴图；缩略图异步解码回填
    @MainActor
    func reloadReceiptItems() {
        var items: [ReceiptDisplayItem] = []

        if let transaction = editingTransaction, !transaction.isDeleted {
            for attachment in transaction.receiptAttachments {
                items.append(attachment.receiptDisplayItem)
                decodeReceiptThumbAsync(attachment)
            }
        }

        for pending in pendingReceipts {
            items.append(ReceiptDisplayItem(
                id: pending.id,
                thumb: pending.preview,
                caption: pending.source.pendingCaption,
                fullImageData: pending.data,
                attachment: nil,
                isReceiptBooking: pending.source == .receiptBooking
            ))
        }

        receiptItems = items
    }

    private func decodeReceiptThumbAsync(_ attachment: TransactionAttachment) {
        guard let data = attachment.thumbnailData else { return }
        let id = attachment.id
        Task.detached(priority: .userInitiated) {
            let image = UIImage(data: data)?.preparingForDisplay() ?? UIImage(data: data)
            await MainActor.run {
                if let index = receiptItems.firstIndex(where: { $0.id == id }) {
                    receiptItems[index].thumb = image
                }
            }
        }
    }

    // MARK: - 选图回调

    func handleReceiptSelected(_ data: Data, source: TransactionAttachment.AttachmentSource) {
        guard receiptItems.count < Transaction.maxReceiptCount else { return }

        if let transaction = editingTransaction {
            // 编辑态：交易已在，即时落库
            Task {
                do {
                    _ = try await repository.attachReceipt(to: transaction, imageData: data, source: source)
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        reloadReceiptItems()
                    }
                } catch {
                    logger.error("贴票根失败：\(error.localizedDescription)")
                    HoloToastCenter.shared.show(error.localizedDescription, type: .error)
                }
            }
            return
        }

        // 新建态：进待贴列表，保存时落库
        let receipt = PendingReceipt(id: UUID(), data: data, source: source, preview: nil)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            pendingReceipts.append(receipt)
            reloadReceiptItems()
        }
        let receiptId = receipt.id
        Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return }
            let preview = await AttachmentFileManager.previewImageInBackground(image, maxDimension: 600)
            await MainActor.run {
                if let index = pendingReceipts.firstIndex(where: { $0.id == receiptId }) {
                    pendingReceipts[index].preview = preview
                    reloadReceiptItems()
                }
            }
        }
    }

    // MARK: - 撕掉 / 全屏

    func handleReceiptDetach(at index: Int) {
        guard receiptItems.indices.contains(index) else { return }
        let item = receiptItems[index]

        if let attachment = item.attachment {
            do {
                try repository.detachReceipt(attachment)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    reloadReceiptItems()
                }
            } catch {
                logger.error("撕掉票根失败：\(error.localizedDescription)")
                HoloToastCenter.shared.show(String(localized: "撕掉失败，请重试"), type: .error)
            }
            return
        }

        if let pendingIndex = pendingReceipts.firstIndex(where: { $0.id == item.id }) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                pendingReceipts.remove(at: pendingIndex)
                reloadReceiptItems()
            }
        }
    }

    func openReceiptGallery(_ index: Int) {
        receiptGalleryStart = index
        showReceiptGallery = true
    }

    /// 全屏查看器（onDetach 与堆叠共用一条处理链）
    var receiptGalleryCover: some View {
        ReceiptGalleryView(
            items: receiptItems,
            startIndex: receiptGalleryStart,
            onDetach: handleReceiptDetach
        )
    }

    // MARK: - 保存接线

    /// 新建交易保存成功后，把待贴票根统一落库（分期组挂首笔）
    func attachPendingReceipts(to transaction: Transaction?) async {
        guard !pendingReceipts.isEmpty, let transaction else { return }
        for receipt in pendingReceipts {
            do {
                _ = try await repository.attachReceipt(to: transaction, imageData: receipt.data, source: receipt.source)
            } catch {
                // 交易本体已保存成功，票根失败不阻断保存流程，只记日志
                logger.error("票根落库失败（交易 \(transaction.id)）：\(error.localizedDescription)")
            }
        }
        pendingReceipts = []
    }
}
