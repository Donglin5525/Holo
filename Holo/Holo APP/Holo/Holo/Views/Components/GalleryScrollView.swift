//
//  GalleryScrollView.swift
//  Holo
//
//  图片浏览共享组件 — 可缩放 UIScrollView + 手势穿透 TabView
//  供 AttachmentGalleryView 和 ThoughtGalleryView 共用
//

import SwiftUI
import UIKit

// MARK: - UIScrollView 包装，支持双指缩放 + 拖动平移

struct ZoomableScrollView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> GalleryScrollView {
        let scrollView = GalleryScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        // 双击缩放
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: GalleryScrollView, context: Context) {
        guard let imageView = scrollView.subviews.first as? UIImageView else { return }
        imageView.image = image
        DispatchQueue.main.async {
            Self.layout(scrollView, imageView)
        }
    }

    /// 将 imageView 按比例居中放置
    private static func layout(_ scrollView: UIScrollView, _ imageView: UIImageView) {
        let boundsSize = scrollView.bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0,
              let imageSize = imageView.image?.size,
              imageSize.width > 0, imageSize.height > 0 else { return }

        let fitScale = min(
            boundsSize.width / imageSize.width,
            boundsSize.height / imageSize.height
        )
        let displaySize = CGSize(
            width: imageSize.width * fitScale,
            height: imageSize.height * fitScale
        )

        imageView.frame = CGRect(
            x: (boundsSize.width - displaySize.width) / 2,
            y: (boundsSize.height - displaySize.height) / 2,
            width: displaySize.width,
            height: displaySize.height
        )
        scrollView.contentSize = displaySize
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.subviews.first
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let imageView = scrollView.subviews.first as? UIImageView else { return }
            let boundsSize = scrollView.bounds.size
            let frameSize = imageView.frame.size

            imageView.frame = CGRect(
                x: max((boundsSize.width - frameSize.width) / 2, 0),
                y: max((boundsSize.height - frameSize.height) / 2, 0),
                width: frameSize.width,
                height: frameSize.height
            )
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view?.superview as? UIScrollView,
                  let imageView = gesture.view as? UIImageView else { return }

            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let location = gesture.location(in: imageView)
                let zoomScale: CGFloat = 2.5
                let zoomRect = CGRect(
                    x: location.x - scrollView.bounds.width / zoomScale / 2,
                    y: location.y - scrollView.bounds.height / zoomScale / 2,
                    width: scrollView.bounds.width / zoomScale,
                    height: scrollView.bounds.height / zoomScale
                )
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }
    }
}

// MARK: - 自定义 ScrollView：未缩放时禁用拖拽手势，允许手势穿透给 TabView 实现左右翻页

class GalleryScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 拖拽手势仅在缩放状态下激活，否则交给 TabView 处理翻页
        if gestureRecognizer == panGestureRecognizer {
            return zoomScale > minimumZoomScale
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
