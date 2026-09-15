func fib(_ n: Int) -> Int {
    if n < 2 { return n }
    return fib(n - 1) + fib(n - 2)
}
func greet(_ name: String, greeting: String = "Hello") -> String {
    return "\(greeting), \(name)!"
}
func sum(_ numbers: Int...) -> Int {
    var total = 0
    for number in numbers { total += number }
    return total
}
for i in 0..<10 { print(fib(i), terminator: " ") }
print("")
print(greet("Alice"), greet("Bob", greeting: "Hi"))
print(sum(1, 2, 3, 4, 5))
let double = { (x: Int) -> Int in x * 2 }
print(double(21))
let factor = 10
let scale = { (x: Int) in x * factor }
print(scale(5))
func apply(_ f: (Int) -> Int, _ v: Int) -> Int { return f(v) }
print(apply({ $0 + 1 }, 41))
