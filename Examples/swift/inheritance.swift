class Shape {
    var name: String
    init(name: String) { self.name = name }
    func area() -> Double { return 0 }
    func describe() -> String { return "\(name) area=\(area())" }
}
class Rectangle: Shape {
    var width: Double
    var height: Double
    init(width: Double, height: Double) {
        self.width = width
        self.height = height
        super.init(name: "rectangle")
    }
    override func area() -> Double { return width * height }
}
class Square: Rectangle {
    init(side: Double) {
        super.init(width: side, height: side)
        name = "square"
    }
}
let shapes: [Shape] = [Rectangle(width: 3, height: 4), Square(side: 5)]
for shape in shapes { print(shape.describe()) }
print(shapes[1] is Rectangle, shapes[0].area() + shapes[1].area())
