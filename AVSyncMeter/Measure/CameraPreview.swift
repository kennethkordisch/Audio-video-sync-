import AVFoundation
import SwiftUI
import UIKit

/// Live camera preview with an outline around the learned screen region.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Normalized rect in metadata-output coordinates (unrotated frame, origin top-left).
    let screenRect: CGRect?
    let highlight: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.update(screenRect: screenRect, highlight: highlight)
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        private let outline = CAShapeLayer()
        private var screenRect: CGRect?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            outline.fillColor = nil
            outline.lineWidth = 2
            outline.strokeColor = UIColor.systemGreen.cgColor
            layer.addSublayer(outline)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        func update(screenRect: CGRect?, highlight: Bool) {
            self.screenRect = screenRect
            outline.strokeColor = (highlight ? UIColor.systemYellow : UIColor.systemGreen).cgColor
            outline.lineWidth = highlight ? 4 : 2
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            outline.frame = bounds
            if let screenRect {
                let layerRect = previewLayer.layerRectConverted(fromMetadataOutputRect: screenRect)
                outline.path = UIBezierPath(roundedRect: layerRect, cornerRadius: 3).cgPath
            } else {
                outline.path = nil
            }
        }
    }
}
