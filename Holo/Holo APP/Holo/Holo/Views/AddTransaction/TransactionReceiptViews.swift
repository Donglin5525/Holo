//
//  TransactionReceiptViews.swift
//  Holo
//
//  账票根 UI — 出票槽 / 票根卡 / 堆叠 / 全屏查看 / 选图入口
//  交互定稿：收银机小票出口（2026-09-27 拍板，docs/design/2026-09-27-账票根原型.html 画板①形态B）
//

import SwiftUI
import PhotosUI
import AVFoundation
import CoreData

// MARK: - 显示模型

/// 票根堆叠/全屏共用的显示项（attachment 非空=已落库；nil=新建未保存的待贴图）
struct ReceiptDisplayItem: Identifiable {
    let id: UUID
    var thumb: UIImage?
    let caption: String
    /// 全屏查看用（stored=imageData 原图；pending=选图原始 Data）
    let fullImageData: Data?
    let attachment: TransactionAttachment?
    /// 识图凭证来源（卡片带角标）
    let isReceiptBooking: Bool
}

/// 新建模式下的待贴票根（保存交易时统一落库；原图只留 Data，避免 UIImage 解码驻留内存）
struct PendingReceipt: Identifiable {
    let id: UUID
    let data: Data
    let source: TransactionAttachment.AttachmentSource
    var preview: UIImage?
}

// MARK: - 出票缝

/// 打印机出票口视觉（2026-09-27 空态改版收窄版）：深暖灰细缝，嵌在堆叠舞台顶边
struct ReceiptSlotNotchView: View {
    var body: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.29, green: 0.27, blue: 0.24),
                        Color(red: 0.20, green: 0.19, blue: 0.17)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Capsule()
                    .fill(
                        LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                    )
                    .frame(height: 1.5)
                    .offset(y: -1.5),
                alignment: .top
            )
            .frame(width: 64, height: 5)
    }
}

// MARK: - 票根形状

/// 票根底边锯齿撕边（顶部小圆角）
struct ReceiptSerratedShape: Shape {
    var toothWidth: CGFloat = 7
    var toothHeight: CGFloat = 4
    var topRadius: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: topRadius, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: 0))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: 0),
            tangent2End: CGPoint(x: rect.maxX, y: topRadius),
            radius: topRadius
        )
        var x = rect.maxX
        while x > 0 {
            let next = max(x - toothWidth, 0)
            path.addLine(to: CGPoint(x: (x + next) / 2, y: rect.maxY - toothHeight))
            path.addLine(to: CGPoint(x: next, y: rect.maxY))
            x = next
        }
        path.addLine(to: CGPoint(x: 0, y: topRadius))
        path.addArc(
            tangent1End: CGPoint(x: 0, y: 0),
            tangent2End: CGPoint(x: topRadius, y: 0),
            radius: topRadius
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - 票根卡

/// 单张票根：白相纸底 + 4:3 照片区 + 票头（来源·时间）+ 底边锯齿
struct ReceiptStubCard: View {
    let item: ReceiptDisplayItem

    private static let stubWidth: CGFloat = 132
    private static let photoHeight: CGFloat = 99   // 4:3
    private static let captionHeight: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            photoArea
            Text(item.caption)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.48))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: Self.captionHeight)
        }
        .frame(width: Self.stubWidth)
        .background(Color.white)
        .clipShape(ReceiptSerratedShape())
        .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
    }

    private var photoArea: some View {
        ZStack {
            Color(red: 0.93, green: 0.92, blue: 0.90)
            if let thumb = item.thumb {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundColor(.gray.opacity(0.4))
            }
        }
        .frame(width: Self.stubWidth, height: Self.photoHeight)
        .clipped()
        .overlay(alignment: .topTrailing) {
            if item.isReceiptBooking {
                HStack(spacing: 2) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8))
                    Text(String(localized: "识图"))
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.holoPrimary))
                .padding(4)
            }
        }
    }
}

// MARK: - 堆叠

/// 票根堆叠：1-3 张错落叠贴，最新在上；轻点全屏、长按 contextMenu（撕掉/查看大图）
struct TransactionReceiptStack: View {
    let items: [ReceiptDisplayItem]   // 旧→新
    let onTap: (Int) -> Void
    let onDetach: (Int) -> Void

    static func stubLayout(count: Int, index: Int) -> (angle: Double, dx: CGFloat, dy: CGFloat) {
        switch count {
        case 1:
            return (-3, 0, 0)
        case 2:
            return index == 0 ? (-5, -24, 5) : (4, 20, 0)
        default:
            switch index {
            case 0: return (-9, -32, 9)
            case 1: return (3, 26, 4)
            default: return (-4, 0, 0)
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let layout = Self.stubLayout(count: items.count, index: index)
                Button {
                    onTap(index)
                } label: {
                    ReceiptStubCard(item: item)
                        // contentShape 必须在 label 内部（2026-09-17 想法卡片坑：挂外面整体点不中）
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("transaction.receiptStub.\(index)")
                .contextMenu {
                    Button(role: .destructive) {
                        onDetach(index)
                    } label: {
                        Label(String(localized: "撕掉票根"), systemImage: "scissors")
                    }
                    Button {
                        onTap(index)
                    } label: {
                        Label(String(localized: "查看大图"), systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
                .rotationEffect(.degrees(layout.angle))
                .offset(x: layout.dx, y: layout.dy)
                .zIndex(Double(index))
                .transition(Self.receiptTransition)
            }
        }
        .frame(width: 200, height: 152)
        .clipped()
    }

    /// 吐出 = 从槽后向下位移进场；撕掉 = 旋转斜飞离场
    static let receiptTransition: AnyTransition = .asymmetric(
        insertion: .move(edge: .top).combined(with: .opacity),
        removal: .modifier(
            active: TearOffEffect(progress: 1),
            identity: TearOffEffect(progress: 0)
        )
    )
}

/// 撕掉离场效果：斜向位移 + 旋转 + 淡出
struct TearOffEffect: ViewModifier {
    var progress: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(x: 70 * progress, y: 30 * progress)
            .rotationEffect(.degrees(24 * progress))
            .opacity(1 - progress)
    }
}

// MARK: - 选图入口

/// 相册选图（UIImagePickerController 版）：delegate 回调直返原图 Data。
/// 不用 SwiftUI photosPicker——其 selection onChange 在本表单环境（sheet + 多 presentation）
/// 下不送达（iOS 26 模拟器实测）；UIImagePickerController 与 CameraView 同构，回调可靠
struct PhotoLibraryPickerView: UIViewControllerRepresentable {
    let onPicked: (Data) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, onCancel: onCancel)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPicked: (Data) -> Void
        let onCancel: () -> Void

        init(onPicked: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onPicked = onPicked
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.85) {
                onPicked(data)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

/// 票根选图服务 modifier：承载系统相册 picker 与相机全屏页。
/// 来源选择用自定义覆盖弹窗（receiptSourcePopup）——iOS 26 上本表单环境里
/// confirmationDialog 与其他 presentation 并存时不可靠，已在模拟器实测复现
struct ReceiptImagePickerServicesModifier: ViewModifier {
    @Binding var showPhotoPicker: Bool
    @Binding var showCamera: Bool
    let remainingSlots: Int
    let onSelect: (_ data: Data, _ source: TransactionAttachment.AttachmentSource) -> Void

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $showPhotoPicker) {
                PhotoLibraryPickerView(onPicked: { data in
                    showPhotoPicker = false
                    onSelect(data, .photoLibrary)
                }, onCancel: {
                    showPhotoPicker = false
                })
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraView(onCapture: { data in
                    showCamera = false
                    onSelect(data, .camera)
                }, onDismiss: {
                    showCamera = false
                })
            }
    }

}

extension View {
    func receiptImagePickerServices(
        showPhotoPicker: Binding<Bool>,
        showCamera: Binding<Bool>,
        remainingSlots: Int,
        onSelect: @escaping (Data, TransactionAttachment.AttachmentSource) -> Void
    ) -> some View {
        modifier(ReceiptImagePickerServicesModifier(
            showPhotoPicker: showPhotoPicker,
            showCamera: showCamera,
            remainingSlots: remainingSlots,
            onSelect: onSelect
        ))
    }
}

// MARK: - 全屏查看

/// 票根全屏查看：黑底、横滑、双指缩放、下拉关闭（微信朋友圈式），含「撕掉」入口
struct ReceiptGalleryView: View {
    let onDetach: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var liveItems: [ReceiptDisplayItem]
    @State private var startIndex: Int
    @State private var currentIndex: Int
    @State private var images: [UIImage?]
    @State private var showTearConfirm = false

    // 下拉关闭（朋友圈式：跟手下拉、背景渐隐、超阈值关闭、不足回弹）
    @State private var dragOffset: CGFloat = 0
    @State private var isZoomed = false

    init(items: [ReceiptDisplayItem], startIndex: Int, onDetach: @escaping (Int) -> Void) {
        self.onDetach = onDetach
        _liveItems = State(initialValue: items)
        _startIndex = State(initialValue: startIndex)
        _currentIndex = State(initialValue: min(startIndex, max(items.count - 1, 0)))
        _images = State(initialValue: Array(repeating: nil, count: items.count))
    }

    /// 下拉时背景随位移渐隐（最多拖到半透明，不完全消失）
    private var backgroundOpacity: Double {
        max(0.25, 1 - Double(abs(dragOffset) / 420))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(backgroundOpacity).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .opacity(chromeOpacity)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                TabView(selection: $currentIndex) {
                    ForEach(Array(liveItems.enumerated()), id: \.element.id) { index, _ in
                        ZoomableImageView(
                            image: index < images.count ? images[index] : nil,
                            isLoading: index < images.count && images[index] == nil,
                            onSingleTap: { dismiss() },
                            onZoomingChanged: { zoomed in
                                isZoomed = zoomed
                                if zoomed {
                                    // 放大瞬间把拖拽残留复位，避免图片位置与手势打架
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        dragOffset = 0
                                    }
                                }
                            }
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 16) {
                    if currentIndex < liveItems.count {
                        Text(liveItems[currentIndex].caption)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    Spacer()
                    if !liveItems.isEmpty {
                        Button {
                            showTearConfirm = true
                        } label: {
                            Label(String(localized: "撕掉"), systemImage: "scissors")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                        }
                    }
                    Text("\(currentIndex + 1)/\(liveItems.count)")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                .opacity(chromeOpacity)
                .padding(.horizontal, 24)
                .padding(.bottom, 34)
            }
            .offset(y: dragOffset)
        }
        .gesture(dragToDismissGesture)
        // 全屏阅读页：边缘右滑返回（fullScreenCover 无系统返回；与横滑翻页共存）
        .holoEdgeSwipeBack { dismiss() }
        .task {
            loadImages()
        }
        .confirmationDialog(String(localized: "撕掉这张票根？"), isPresented: $showTearConfirm) {
            Button(String(localized: "撕掉票根"), role: .destructive) {
                tearCurrent()
            }
            Button(String(localized: "取消"), role: .cancel) {}
        }
    }

    /// 顶部/底部工具随下拉渐隐
    private var chromeOpacity: Double {
        dragOffset == 0 ? 1 : max(0, 1 - Double(abs(dragOffset) / 220))
    }

    /// 朋友圈式下拉关闭：竖向主导才跟随；缩放状态下让位给图片拖动
    private var dragToDismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isZoomed else { return }
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                // 竖向阻尼：越拉越费劲，接近微信手感
                let raw = value.translation.height
                dragOffset = raw > 0 ? raw * 0.92 : raw * 0.4
            }
            .onEnded { value in
                guard !isZoomed else { return }
                let shouldClose = value.translation.height > 130
                    || value.predictedEndTranslation.height > 420
                if shouldClose {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func loadImages() {
        for (index, item) in liveItems.enumerated() {
            guard let data = item.fullImageData else { continue }
            // 二进制取值须在主线程；解码放后台。
            // 全屏查看直接解码原始 2048px 数据——不做 preparingForDisplay 屏幕降采样，
            // 否则双指放大后超过屏幕尺寸的部分全糊（「不是真正的大图」的根因）
            DispatchQueue.global(qos: .userInitiated).async {
                let image = UIImage(data: data)
                DispatchQueue.main.async {
                    if index < images.count {
                        images[index] = image
                    }
                }
            }
        }
    }

    private func tearCurrent() {
        guard liveItems.indices.contains(currentIndex) else { return }
        let index = currentIndex
        let item = liveItems[index]
        liveItems.remove(at: index)
        images.remove(at: index)
        if liveItems.isEmpty {
            dismiss()
        } else {
            currentIndex = min(currentIndex, liveItems.count - 1)
        }
        onDetach(index)
    }
}

// MARK: - 详情页票根区块

/// 交易详情用的票根区块：装配 + 堆叠 + 全屏查看一体（轻点全屏，撕掉走全屏入口）
struct TransactionReceiptDetailSection: View {
    let transaction: Transaction

    @State private var items: [ReceiptDisplayItem] = []
    @State private var showGallery = false
    @State private var galleryStart = 0

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            Text(String(localized: "票根"))
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

            TransactionReceiptStack(
                items: items,
                onTap: { index in
                    galleryStart = index
                    showGallery = true
                },
                onDetach: detachAt
            )
            .frame(maxWidth: .infinity)
        }
        .opacity(items.isEmpty ? 0 : 1)
        .frame(height: items.isEmpty ? 0 : nil)
        .clipped()
        .task(id: transaction.objectID) {
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .financeDataDidChange)) { _ in
            reload()
        }
        .fullScreenCover(isPresented: $showGallery) {
            ReceiptGalleryView(items: items, startIndex: galleryStart, onDetach: detachAt)
        }
    }

    private func reload() {
        guard !transaction.isDeleted else {
            items = []
            return
        }
        items = transaction.receiptAttachments.map(\.receiptDisplayItem)
        for attachment in transaction.receiptAttachments {
            decodeThumbAsync(attachment)
        }
    }

    private func decodeThumbAsync(_ attachment: TransactionAttachment) {
        guard let data = attachment.thumbnailData else { return }
        let id = attachment.id
        Task.detached(priority: .userInitiated) {
            let image = UIImage(data: data)?.preparingForDisplay() ?? UIImage(data: data)
            await MainActor.run {
                if let index = items.firstIndex(where: { $0.id == id }) {
                    items[index].thumb = image
                }
            }
        }
    }

    private func detachAt(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let attachment = items[index].attachment
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            items.remove(at: index)
        }
        if let attachment {
            try? FinanceRepository.shared.detachReceipt(attachment)
        }
    }
}

// MARK: - 票头文案

extension TransactionAttachment {

    /// 落库附件 → 显示项（thumb 占位，异步解码后回填）
    var receiptDisplayItem: ReceiptDisplayItem {
        ReceiptDisplayItem(
            id: id,
            thumb: nil,
            caption: receiptCaption,
            fullImageData: imageData,
            attachment: self,
            isReceiptBooking: source == .receiptBooking
        )
    }

    /// 票头小字「来源 · 时间」；识图凭证不带时间（归档时刻≠拍照时刻，避免误导）
    var receiptCaption: String {
        switch source {
        case .receiptBooking:
            return String(localized: "识图凭证")
        case .camera:
            return String(localized: "拍照 · \(createdAt.receiptTimeString)")
        case .photoLibrary:
            return String(localized: "相册 · \(createdAt.receiptTimeString)")
        }
    }
}

extension TransactionAttachment.AttachmentSource {
    var pendingCaption: String {
        switch self {
        case .receiptBooking:
            return String(localized: "识图凭证")
        case .camera:
            return String(localized: "拍照")
        case .photoLibrary:
            return String(localized: "相册")
        }
    }
}

extension Date {
    /// 票头时间：今天「今天 HH:mm」，否则「M月d日」
    var receiptTimeString: String {
        if Calendar.current.isDateInToday(self) {
            let time = DateFormatter.localizedString(from: self, dateStyle: .none, timeStyle: .short)
            return String(localized: "今天 \(time)")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter.string(from: self)
    }
}
