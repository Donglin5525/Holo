import SwiftUI
import Combine
import VisionKit
import AVFoundation
#if canImport(UIKit)

// MARK: - 想法扫描文字（系统实况文本 Live Text / DataScanner）
// 东林 11-04 拍板：多用 iOS 原生能力、可弃原图、识别准确性优先。
// 画面/对焦/高亮/方向/双指缩放全由系统 DataScanner 管理。
// 布局：上半文字区实时显示识别内容，下半相机区原生取景。
// 关键教训（11-04 实机：捏合缩放手势无响应）：SwiftUI 全屏浮层会挡住下层
// DataScanner 的手势——浮层只盖文字区，相机区不放任何遮挡物；
// 「保留」按钮与不可用提示用 UIKit 控件直接挂相机区。

struct ThoughtTextScannerView: View {
    /// 识别文本（不再带原图）
    let onDone: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ThoughtTextScannerControllerView(onDone: onDone, onDismiss: onDismiss)
            .ignoresSafeArea()
    }
}

// MARK: - 识别状态

@MainActor
final class TextScannerState: ObservableObject {
    /// 最近一次的完整识别文本（阅读顺序）
    @Published var recognizedText: String = ""
}

// MARK: - UIViewControllerRepresentable 壳

private struct ThoughtTextScannerControllerView: UIViewControllerRepresentable {
    let onDone: (String) -> Void
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> TextScannerHostViewController {
        let vc = TextScannerHostViewController()
        vc.onDone = onDone
        vc.onDismiss = onDismiss
        return vc
    }

    func updateUIViewController(_ vc: TextScannerHostViewController, context: Context) {}
}

// MARK: - 宿主控制器：DataScanner 子视图 + 顶部文字区浮层 + 相机区原生控件

final class TextScannerHostViewController: UIViewController {
    var onDone: ((String) -> Void)?
    var onDismiss: () -> Void = {}

    private let state = TextScannerState()
    private var dataScanner: DataScannerViewController?
    private var hosting: UIHostingController<TextScannerOverlayView>?
    /// 相机区定位基准（无论 DataScanner 是否可用都存在，供按钮/提示定位）
    private let cameraGuide = UIView()
    private let keepButton = UIButton(type: .system)
    private let unavailableLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        mountCameraGuide()
        mountDataScanner()
        mountOverlay()
        mountCameraControls()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        try? dataScanner?.startScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        dataScanner?.stopScanning()
    }

    // MARK: 相机区基准（下半 45%）

    private func mountCameraGuide() {
        cameraGuide.backgroundColor = .clear
        cameraGuide.isUserInteractionEnabled = false
        view.addSubview(cameraGuide)
        cameraGuide.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cameraGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cameraGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cameraGuide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            cameraGuide.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: ScannerLayout.cameraFraction)
        ])
    }

    // MARK: DataScanner（只占相机区，手势不被遮挡）

    private func mountDataScanner() {
        guard DataScannerViewController.isAvailable else {
            showUnavailableMessage()
            return
        }
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = self
        addChild(scanner)
        cameraGuide.isUserInteractionEnabled = true
        cameraGuide.addSubview(scanner.view)
        scanner.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scanner.view.topAnchor.constraint(equalTo: cameraGuide.topAnchor),
            scanner.view.bottomAnchor.constraint(equalTo: cameraGuide.bottomAnchor),
            scanner.view.leadingAnchor.constraint(equalTo: cameraGuide.leadingAnchor),
            scanner.view.trailingAnchor.constraint(equalTo: cameraGuide.trailingAnchor)
        ])
        scanner.didMove(toParent: self)
        dataScanner = scanner
    }

    private func showUnavailableMessage() {
        unavailableLabel.text = String(localized: "未检测到相机，扫描功能需要摄像头")
        unavailableLabel.font = .preferredFont(forTextStyle: .footnote)
        unavailableLabel.textColor = .white.withAlphaComponent(0.7)
        unavailableLabel.textAlignment = .center
        unavailableLabel.numberOfLines = 0
        cameraGuide.addSubview(unavailableLabel)
        unavailableLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            unavailableLabel.centerXAnchor.constraint(equalTo: cameraGuide.centerXAnchor),
            unavailableLabel.centerYAnchor.constraint(equalTo: cameraGuide.centerYAnchor),
            unavailableLabel.leadingAnchor.constraint(greaterThanOrEqualTo: cameraGuide.leadingAnchor, constant: 24),
            unavailableLabel.trailingAnchor.constraint(lessThanOrEqualTo: cameraGuide.trailingAnchor, constant: -24)
        ])
        keepButton.isHidden = true
    }

    // MARK: 顶部文字区浮层（只盖文字区，不碰相机区）

    private func mountOverlay() {
        let overlay = TextScannerOverlayView(state: state) { [weak self] in
            self?.onDismiss()
        }
        let hosting = UIHostingController(rootView: overlay)
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 1 - ScannerLayout.cameraFraction)
        ])
        hosting.didMove(toParent: self)
        self.hosting = hosting
    }

    // MARK: 相机区原生控件：保留按钮

    private func mountCameraControls() {
        var config = UIButton.Configuration.plain()
        config.title = String(localized: "保留")
        config.background.backgroundColor = .white
        config.background.cornerRadius = 24
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 16, weight: .semibold)
            outgoing.foregroundColor = .black
            return outgoing
        }
        keepButton.configuration = config
        keepButton.accessibilityLabel = String(localized: "保留")
        keepButton.addTarget(self, action: #selector(keepTapped), for: .touchUpInside)
        view.addSubview(keepButton)
        keepButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            keepButton.centerXAnchor.constraint(equalTo: cameraGuide.centerXAnchor),
            keepButton.bottomAnchor.constraint(equalTo: cameraGuide.bottomAnchor, constant: -24),
            keepButton.widthAnchor.constraint(equalToConstant: 120),
            keepButton.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    @objc private func keepTapped() {
        onDone?(state.recognizedText)
    }
}

// MARK: - 识别文本累积（DataScanner 回调，坐标由系统给出，直接可用）

extension TextScannerHostViewController: DataScannerViewControllerDelegate {
    func dataScannerDidBecomeAvailable(_ dataScanner: DataScannerViewController) {
        try? dataScanner.startScanning()
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
        pushTranscript(allItems)
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updated: [RecognizedItem], allItems: [RecognizedItem]) {
        pushTranscript(allItems)
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didRemove removed: [RecognizedItem], allItems: [RecognizedItem]) {
        pushTranscript(allItems)
    }

    private func pushTranscript(_ items: [RecognizedItem]) {
        // Bounds 只给四角点，求外接矩形；坐标是 DataScanner 视图坐标（系统已处理好方向）
        let texts: [(String, CGRect)] = items.compactMap { item in
            guard case .text(let text) = item else { return nil }
            let b = text.bounds
            let xs = [b.topLeft.x, b.topRight.x, b.bottomRight.x, b.bottomLeft.x]
            let ys = [b.topLeft.y, b.topRight.y, b.bottomRight.y, b.bottomLeft.y]
            let rect = CGRect(
                x: xs.min() ?? 0, y: ys.min() ?? 0,
                width: (xs.max() ?? 0) - (xs.min() ?? 0),
                height: (ys.max() ?? 0) - (ys.min() ?? 0)
            )
            return (text.transcript, rect)
        }
        // 阅读顺序：先按行聚类（行高一半为界）、行内按 x
        let sorted = texts.sorted { a, b in
            let rowThreshold = min(a.1.height, b.1.height) * 0.5
            if abs(a.1.minY - b.1.minY) > rowThreshold { return a.1.minY < b.1.minY }
            return a.1.minX < b.1.minX
        }
        let text = sorted.map(\.0).joined(separator: "\n")
        DispatchQueue.main.async { [weak self] in
            self?.state.recognizedText = text
        }
    }
}

// MARK: - 布局常量

/// 原生实况文本式分区：上半文字区、下半相机区。
/// SwiftUI 文字区浮层与 DataScanner/相机基准共用同一比例。
enum ScannerLayout {
    static let cameraFraction: CGFloat = 0.45
}

// MARK: - SwiftUI 文字区浮层（只盖上半，高度由宿主约束决定）

private struct TextScannerOverlayView: View {
    @ObservedObject var state: TextScannerState
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
            RecognizedTextPanel(text: state.recognizedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground).ignoresSafeArea(edges: .top))
    }

    private var topBar: some View {
        HStack {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color(.systemGray5)))
            }
            .accessibilityLabel(String(localized: "取消"))
            Spacer()
            if !state.recognizedText.isEmpty {
                Text(String(localized: "已识别 \(state.recognizedText.count) 字"))
                    .font(ThoughtLayout.metadata)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(.systemGray6)))
            }
        }
    }
}

// MARK: - 识别文字实时区

private struct RecognizedTextPanel: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if text.isEmpty {
                        Text(String(localized: "对准文字，识别内容会实时出现在这里"))
                            .foregroundColor(Color(.placeholderText))
                    } else {
                        Text(text)
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                    }
                }
                .font(ThoughtLayout.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .id("scanTextBottom")
            }
            .onChange(of: text) { _, _ in
                // 新内容追加在底部，跟随滚动到底
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("scanTextBottom", anchor: .bottom)
                }
            }
        }
    }
}
#endif
