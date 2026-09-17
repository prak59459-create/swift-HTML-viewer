import Foundation

/// 内蔵処理系が使う乱数。
///
/// 種を決めておくと毎回同じ並びになるので、結果を比べたいときに便利。
/// 種を決めない場合は本物の乱数を使う。
public final class MLRandom: RandomNumberGenerator {
    private var state: UInt64
    /// 種を決めてあるか。
    public let isSeeded: Bool

    public init(seed: UInt64? = nil) {
        if let seed {
            // 0 は splitmix64 の周期に悪いので、混ぜてから使う。
            self.state = seed &+ 0x9E37_79B9_7F4A_7C15
            self.isSeeded = true
        } else {
            self.state = UInt64.random(in: UInt64.min...UInt64.max)
            self.isSeeded = false
        }
    }

    /// splitmix64。短くて速く、質も十分。
    public func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 以上 1 未満。
    public func double() -> Double {
        // 上位 53 ビットを使う (Double の仮数部に合わせる)。
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// `low` 以上 `high` 以下。
    public func int(in range: ClosedRange<Int64>) -> Int64 {
        guard range.lowerBound < range.upperBound else { return range.lowerBound }
        let span = UInt64(bitPattern: range.upperBound &- range.lowerBound) &+ 1
        if span == 0 { return Int64(bitPattern: next()) }   // 全域。
        return range.lowerBound &+ Int64(bitPattern: next() % span)
    }

    /// `low` 以上 `high` 未満。
    public func double(in range: Range<Double>) -> Double {
        guard range.lowerBound < range.upperBound else { return range.lowerBound }
        return range.lowerBound + double() * (range.upperBound - range.lowerBound)
    }

    public func bool() -> Bool { next() & 1 == 1 }

    /// 並べ替え。
    public func shuffled<T>(_ items: [T]) -> [T] {
        var copy = items
        guard copy.count > 1 else { return copy }
        for index in stride(from: copy.count - 1, to: 0, by: -1) {
            let other = Int(next() % UInt64(index + 1))
            copy.swapAt(index, other)
        }
        return copy
    }

    /// 1 つ選ぶ。
    public func element<T>(of items: [T]) -> T? {
        guard !items.isEmpty else { return nil }
        return items[Int(next() % UInt64(items.count))]
    }
}
