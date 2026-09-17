enum Direction: String {
    case north = "N"
    case south = "S"
    case east = "E"
    case west = "W"
}
func describe(_ direction: Direction) -> String {
    switch direction {
    case .north: return "up"
    case .south: return "down"
    default: return "sideways"
    }
}
let directions: [Direction] = [.north, .east, .south, .west]
for direction in directions {
    print(direction.rawValue, describe(direction), terminator: " ")
}
print("")
let parsed = Direction(rawValue: "S")
if let parsed = parsed {
    print("parsed:", describe(parsed))
}
let missing = Direction(rawValue: "X")
print(missing == nil)
let score = 85
switch score {
case 90...100: print("A")
case 80..<90: print("B")
case let other where other >= 70: print("C \(other)")
default: print("F")
}
