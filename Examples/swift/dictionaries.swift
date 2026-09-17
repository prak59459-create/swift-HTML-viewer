var scores: [String: Int] = ["alice": 90, "bob": 75]
scores["carol"] = 82
scores["bob"] = 80
print(scores.count, scores["alice"] ?? 0, scores["dave"] ?? -1)
let names = scores.keys.sorted()
for name in names {
    print(name, scores[name]!, terminator: " ")
}
print("")
let high = scores.filter { $0.value >= 82 }
print(high.count)
let total = scores.values.reduce(0, +)
print(total, total / scores.count)
if let removed = scores.removeValue(forKey: "bob") {
    print("removed \(removed), left \(scores.count)")
}
print(scores.keys.sorted().joined(separator: ","))
