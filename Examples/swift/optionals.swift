func findFirst(_ values: [Int], where predicate: (Int) -> Bool) -> Int? {
    for value in values where predicate(value) {
        return value
    }
    return nil
}
let numbers = [3, 8, 15, 4, 23]
if let firstBig = findFirst(numbers, where: { $0 > 10 }) {
    print("found \(firstBig)")
}
let missing = findFirst(numbers, where: { $0 > 100 })
print(missing == nil, missing ?? -1)

func describe(_ value: Int?) -> String {
    guard let value = value else { return "none" }
    return "value \(value)"
}
print(describe(5), describe(nil))

var optionalName: String? = "swift"
print(optionalName!.uppercased())
optionalName = nil
print(optionalName?.count ?? 0)
let lengths = ["a", "bb", "ccc"].map { $0.count }
print(lengths, lengths.max() ?? 0, lengths.min() ?? 0)
