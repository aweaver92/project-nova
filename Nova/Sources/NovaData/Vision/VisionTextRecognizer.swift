import Foundation
import NovaCore
import NovaDomain

#if canImport(Vision) && canImport(UIKit)
import Vision
import UIKit

/// On-device OCR using Apple's Vision framework. Runs entirely on the phone — no
/// image ever leaves the device for text recognition — which is both fast and
/// privacy-preserving.
public struct VisionTextRecognizer: TextRecognizing {
    public init() {}

    public func recognizeText(in imageData: Data) async -> String {
        guard let cg = UIImage(data: imageData)?.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
            let lines = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        } catch {
            NovaLog.vision.error("OCR failed: \(String(describing: error), privacy: .public)")
            return ""
        }
    }
}

#else

/// Fallback when Vision/UIKit isn't available (non-iOS builds).
public struct VisionTextRecognizer: TextRecognizing {
    public init() {}
    public func recognizeText(in imageData: Data) async -> String { "" }
}

#endif
