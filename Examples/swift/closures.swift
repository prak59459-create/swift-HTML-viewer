func makeCounter() -> () -> Int {
    var count = 0
    return {
        count += 1
        return count
    }
}
let counter = makeCounter()
print(counter(), counter(), counter())

func compose(_ f: @escaping (Int) -> Int, _ g: @escaping (Int) -> Int) -> (Int) -> Int {
    return { x in f(g(x)) }
}
let addOne = { (x: Int) in x + 1 }
let double = { (x: Int) in x * 2 }
print(compose(addOne, double)(5), compose(double, addOne)(5))

let matrix = [[1, 2, 3], [4, 5, 6]]
let flattened = matrix.flatMap { $0 }
print(flattened, flattened.reduce(0, +))
let pairs = zip([1, 2, 3], ["a", "b", "c"])
for (number, letter) in pairs { print(number, letter, terminator: " ") }
print("")
var sum = 0
var i = 0
repeat {
    sum += i
    i += 1
} while i < 5
print(sum)
