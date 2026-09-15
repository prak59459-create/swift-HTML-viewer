struct Point {
    var x: Int
    var y: Int
    func distanceSquared() -> Int { return x * x + y * y }
    mutating func move(dx: Int, dy: Int) {
        x += dx
        y += dy
    }
    var description: String { return "(\(x), \(y))" }
}
var point = Point(x: 3, y: 4)
print(point.distanceSquared(), point.description)
point.move(dx: 1, dy: -1)
print(point.x, point.y, point)
let copy = point
point.x = 100
print(copy.x, point.x)

class Counter {
    var value = 0
    let step: Int
    init(step: Int) { self.step = step }
    func increment() { value += step }
}
let counter = Counter(step: 5)
counter.increment()
counter.increment()
let alias = counter
alias.increment()
print(counter.value, alias.value)
