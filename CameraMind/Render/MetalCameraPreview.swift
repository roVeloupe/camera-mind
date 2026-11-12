import SwiftUI
import MetalKit
import CoreImage
import AVFoundation

/// 实时取景 + 实时调色。CIImage 直接渲染到 Metal drawable，30fps。
struct MetalCameraPreview: UIViewRepresentable {
    let controller: CameraController
    let grade: GradeParameters
    let showOriginal: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.autoResizeDrawable = true
        view.delegate = context.coordinator
        context.coordinator.attach(view: view, controller: controller)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.grade = grade
        context.coordinator.showOriginal = showOriginal
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var grade = GradeParameters.identity
        var showOriginal = false

        private var ciContext: CIContext?
        private var commandQueue: MTLCommandQueue?
        private weak var view: MTKView?
        private weak var controller: CameraController?
        private var latest: CVPixelBuffer?
        private var pending = false
        private var startZoom: Double = 1.0
        private let renderer = GradeRenderer()

        func attach(view: MTKView, controller: CameraController) {
            self.view = view
            self.controller = controller
            if let device = view.device {
                ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
                commandQueue = device.makeCommandQueue()
            }
            controller.onFrame = { [weak self] buffer in
                guard let self else { return }
                self.latest = buffer
                self.schedule()
            }

            view.isUserInteractionEnabled = true
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            view.addGestureRecognizer(pinch)
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleTap)
        }

        @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let controller else { return }
            switch g.state {
            case .began:
                startZoom = controller.zoom
            case .changed:
                controller.setZoom(startZoom * Double(g.scale))
            default:
                break
            }
        }

        @objc private func handleDoubleTap() {
            controller?.setZoom(1.0)
        }

        func detach() {
            controller?.onFrame = nil
            latest = nil
        }

        private func schedule() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async {
                self.pending = false
                self.view?.draw()
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.draw()
        }

        func draw(in view: MTKView) {
            guard let buffer = latest,
                  let ctx = ciContext,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer() else { return }

            var image = CIImage(cvPixelBuffer: buffer).oriented(.right)
            image = renderer.render(image, with: grade, showOriginal: showOriginal, fast: true)
            image = image.aspectFill(to: view.drawableSize)

            ctx.render(image,
                       to: drawable.texture,
                       commandBuffer: commandBuffer,
                       bounds: CGRect(origin: .zero, size: view.drawableSize),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

extension CIImage {
    /// 等比填充到目标尺寸（会裁切）
    func aspectFill(to size: CGSize) -> CIImage {
        let w = extent.width, h = extent.height
        guard w > 1, h > 1, size.width > 1, size.height > 1 else { return self }
        let scale = max(size.width / w, size.height / h)
        let dx = (size.width - w * scale) / 2 - extent.minX * scale
        let dy = (size.height - h * scale) / 2 - extent.minY * scale
        return transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }
}
