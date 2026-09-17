enum Operation: String {
    case add = "+"
    case subtract = "-"
    case multiply = "*"
    func apply(_ a: Int, _ b: Int) -> Int {
        switch self {
        case .add: return a + b
        case .subtract: return a - b
        case .multiply: return a * b
        }
    }
}
let operations: [Operation] = [.add, .subtract, .multiply]
for operation in operations {
    print("6 \(operation.rawValue) 3 = \(operation.apply(6, 3))")
}

struct Stack {
    private var items: [Int] = []
    var count: Int { return items.count }
    var isEmpty: Bool { return items.isEmpty }
    mutating func push(_ item: Int) { items.append(item) }
    mutating func pop() -> Int? {
        if items.isEmpty { return nil }
        return items.removeLast()
    }
    func peek() -> Int? { return items.last }
}
var stack = Stack()
for value in 1...5 { stack.push(value * value) }
print(stack.count, stack.peek() ?? 0)
var popped: [Int] = []
while let value = stack.pop() { popped.append(value) }
print(popped, stack.isEmpty)
