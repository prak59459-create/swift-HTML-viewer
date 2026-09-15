import Foundation
let text = "the quick brown fox jumps over the lazy dog"
let words = text.split(separator: " ").map { String($0) }
print(words.count, words.first ?? "", words.last ?? "")
var counts: [String: Int] = [:]
for word in words {
    counts[word] = (counts[word] ?? 0) + 1
}
print(counts["the"] ?? 0)
let longest = words.reduce("") { $1.count > $0.count ? $1 : $0 }
print(longest, longest.count)
print(text.uppercased().prefix(9))
print(text.replacingOccurrences(of: " ", with: "-"))
print(text.hasPrefix("the"), text.contains("fox"), text.count)
var reversedWords: [String] = []
for word in words { reversedWords.append(String(word.reversed())) }
print(reversedWords.joined(separator: " "))
let vowels = text.filter { "aeiou".contains($0) }
print(vowels.count)
