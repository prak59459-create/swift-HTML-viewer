import Foundation
let a = 7
let b = 2
print(a / b, a % b, Double(a) / Double(b))
print(Int(3.99), Double(3), 10 / 4, 10.0 / 4.0)
print(0.1 + 0.2, 1.0 / 3.0, (2.0).squareRoot())
let values = [1.5, 2.25, 3.0]
print(values, values.reduce(0.0, +))
print(Int("42") ?? 0, Int("abc") ?? -1, Double("2.5") ?? 0)
print(abs(-7), max(3, 9), min(3, 9), max(1, 2, 3))
let big = 1_000_000
print(big, big * 2)
print(String(42), String(3.5), String(true))
let truncated = Int(7.9)
print(truncated, 7.9.rounded(), (-2.5).rounded())
print(5.isMultiple(of: 5), 7.isMultiple(of: 2))
