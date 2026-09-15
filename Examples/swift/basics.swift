let name = "world"
var count = 3
print("hello, \(name)!")
print("count is \(count), doubled is \(count * 2)")
for i in 1...3 {
    print("line \(i)")
}
var total = 0
let values = [3, 1, 4, 1, 5, 9, 2, 6]
for value in values {
    total += value
}
print("total=\(total) count=\(values.count)")
print("abc".uppercased(), "hello".count, String(repeating: "ab", count: 3))
let doubled = values.map { $0 * 2 }
print(doubled)
print(values.filter { $0 > 3 }, values.reduce(0, +))
