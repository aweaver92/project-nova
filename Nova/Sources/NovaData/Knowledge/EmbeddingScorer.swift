import Foundation
import NovaCore

#if canImport(NaturalLanguage)
import NaturalLanguage

/// On-device semantic similarity using Apple's `NLEmbedding` word vectors. A
/// sentence is represented as the mean of its word vectors; similarity is cosine
/// distance mapped to [0, 1]. Returns `nil`-yielding scores when the embedding
/// model isn't available so callers can fall back to keyword ranking.
///
/// Not `Sendable`: it wraps a reference-type `NLEmbedding`. Build and use it
/// locally within a call rather than storing it across concurrency domains.
public struct EmbeddingScorer {
    private let embedding: NLEmbedding?

    public init(language: NLLanguage = .english) {
        self.embedding = NLEmbedding.wordEmbedding(for: language)
    }

    public var isAvailable: Bool { embedding != nil }

    /// Cosine similarity in [0, 1] between two strings, or `nil` if unavailable.
    public func similarity(_ a: String, _ b: String) -> Double? {
        guard let embedding,
              let va = vector(for: a, embedding: embedding),
              let vb = vector(for: b, embedding: embedding) else { return nil }
        return Self.cosine(va, vb)
    }

    private func vector(for text: String, embedding: NLEmbedding) -> [Double]? {
        let tokens = text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map { String($0) }
            .filter { $0.count > 1 }
        var sum: [Double] = []
        var count = 0
        for token in tokens {
            guard let v = embedding.vector(for: token) else { continue }
            if sum.isEmpty {
                sum = v
            } else {
                for i in 0..<min(sum.count, v.count) { sum[i] += v[i] }
            }
            count += 1
        }
        guard count > 0 else { return nil }
        return sum.map { $0 / Double(count) }
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        let cos = dot / (na.squareRoot() * nb.squareRoot())
        return max(0, min(1, (cos + 1) / 2))
    }
}
#else
public struct EmbeddingScorer {
    public init() {}
    public var isAvailable: Bool { false }
    public func similarity(_ a: String, _ b: String) -> Double? { nil }
}
#endif
