import Foundation

/// Dahili ekran parlaklığını harici monitör parlaklığına çeviren eşleme.
///
/// Neden düz `external = internal` yetmiyor: MacBook Air M2 paneli 500 nit,
/// VP2768a gibi tipik bir IPS monitör 350 nit tepe parlaklık veriyor ve ikisinin
/// slider->nit eğrisi farklı. "%50" iki ekranda aynı görünmüyor. Bu yüzden
/// kullanıcının gözüyle eşitlediği noktaları (anchor) toplayıp aralarını
/// doğrusal interpolasyonla dolduruyoruz.
struct BrightnessCurve: Codable, Equatable {
    struct Anchor: Codable, Equatable, Identifiable {
        var input: Double   // dahili ekran, 0...1
        var output: Double  // harici monitör, 0...1
        var id: Double { input }
    }

    /// input'a göre sıralı tutulur, en az iki eleman.
    private(set) var anchors: [Anchor]

    static let identity = BrightnessCurve(anchors: [
        Anchor(input: 0, output: 0),
        Anchor(input: 1, output: 1),
    ])

    init(anchors: [Anchor]) {
        self.anchors = Self.normalize(anchors)
    }

    private static func normalize(_ raw: [Anchor]) -> [Anchor] {
        var sorted = raw
            .map { Anchor(input: min(max($0.input, 0), 1), output: min(max($0.output, 0), 1)) }
            .sorted { $0.input < $1.input }

        // Aynı input'a iki nokta konursa sonuncusu kazanır.
        var deduped: [Anchor] = []
        for anchor in sorted {
            if let last = deduped.last, abs(last.input - anchor.input) < 0.001 {
                deduped[deduped.count - 1] = anchor
            } else {
                deduped.append(anchor)
            }
        }
        sorted = deduped

        // Uçlar her zaman tanımlı olsun ki ekstrapolasyon yapmak zorunda kalmayalım.
        if sorted.first?.input ?? 1 > 0.001 {
            sorted.insert(Anchor(input: 0, output: sorted.first?.output ?? 0), at: 0)
        }
        if sorted.last?.input ?? 0 < 0.999 {
            sorted.append(Anchor(input: 1, output: sorted.last?.output ?? 1))
        }
        return sorted
    }

    /// Dahili parlaklık -> harici parlaklık.
    func map(_ input: Double) -> Double {
        let x = min(max(input, 0), 1)
        guard let firstIndex = anchors.firstIndex(where: { $0.input >= x }) else {
            return anchors.last?.output ?? x
        }
        guard firstIndex > 0 else { return anchors[0].output }

        let low = anchors[firstIndex - 1]
        let high = anchors[firstIndex]
        let span = high.input - low.input
        guard span > 0.0001 else { return high.output }
        let t = (x - low.input) / span
        return low.output + t * (high.output - low.output)
    }

    /// Ters yön: harici sürgüyü elle oynatınca hangi dahili değere denk geldiğini bulur.
    func inverseMap(_ output: Double) -> Double {
        let y = min(max(output, 0), 1)
        for i in 1..<anchors.count {
            let low = anchors[i - 1], high = anchors[i]
            let lo = min(low.output, high.output), hi = max(low.output, high.output)
            guard y >= lo, y <= hi else { continue }
            let span = high.output - low.output
            guard abs(span) > 0.0001 else { return low.input }
            let t = (y - low.output) / span
            return low.input + t * (high.input - low.input)
        }
        return y
    }

    mutating func addAnchor(input: Double, output: Double) {
        anchors = Self.normalize(anchors + [Anchor(input: input, output: output)])
    }

    mutating func removeAnchor(at input: Double) {
        // Uçları silmeye izin var ama en az iki nokta kalmalı.
        let filtered = anchors.filter { abs($0.input - input) > 0.001 }
        anchors = filtered.count >= 2 ? Self.normalize(filtered) : Self.identity.anchors
    }

    var isIdentity: Bool { self == .identity }
}
