func minMax(_ values: [Int]) -> (min: Int, max: Int) {
    var smallest = values[0]
    var largest = values[0]
    for value in values {
        if value < smallest { smallest = value }
        if value > largest { largest = value }
    }
    return (min: smallest, max: largest)
}
let bounds = minMax([3, 9, 1, 7])
print(bounds.min, bounds.max, bounds)

func swapValues(_ a: inout Int, _ b: inout Int) {
    let temporary = a
    a = b
    b = temporary
}
var x = 1
var y = 2
swapValues(&x, &y)
print(x, y)

func power(base: Int, exponent: Int) -> Int {
    var result = 1
    for _ in 0..<exponent { result *= base }
    return result
}
print(power(base: 2, exponent: 10), power(base: 3, exponent: 3))

let pairs = [(1, "one"), (2, "two"), (3, "three")]
for (number, word) in pairs {
    print("\(number)=\(word)", terminator: " ")
}
print("")
var index = 0
while index < 10 {
    index += 3
    guard index % 2 == 0 else { continue }
    print(index, terminator: " ")
}
print("")
