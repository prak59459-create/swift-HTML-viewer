func quicksort(_ values: [Int]) -> [Int] {
    guard values.count > 1 else { return values }
    let pivot = values[values.count / 2]
    let less = values.filter { $0 < pivot }
    let equal = values.filter { $0 == pivot }
    let greater = values.filter { $0 > pivot }
    return quicksort(less) + equal + quicksort(greater)
}
let unsorted = [5, 3, 8, 1, 9, 2, 7, 4, 6]
print(quicksort(unsorted))

func binarySearch(_ values: [Int], _ target: Int) -> Int? {
    var low = 0
    var high = values.count - 1
    while low <= high {
        let middle = (low + high) / 2
        if values[middle] == target { return middle }
        if values[middle] < target { low = middle + 1 } else { high = middle - 1 }
    }
    return nil
}
let sorted = quicksort(unsorted)
print(binarySearch(sorted, 7) ?? -1, binarySearch(sorted, 100) ?? -1)

for i in 1...15 {
    if i % 15 == 0 { print("FizzBuzz", terminator: " ") }
    else if i % 3 == 0 { print("Fizz", terminator: " ") }
    else if i % 5 == 0 { print("Buzz", terminator: " ") }
    else { print(i, terminator: " ") }
}
print("")
let primes = (2...30).filter { candidate in
    !(2..<candidate).contains { candidate % $0 == 0 }
}
print(primes)
