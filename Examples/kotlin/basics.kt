data class Point(val x: Int, val y: Int)

enum class Color { RED, GREEN, BLUE }

fun fib(n: Int): Int = if (n < 2) n else fib(n - 1) + fib(n - 2)

fun describe(n: Int): String = when {
    n < 0 -> "negative"
    n == 0 -> "zero"
    n < 10 -> "small"
    else -> "large"
}

class Counter(private var value: Int = 0) {
    fun increment() { value++ }
    fun get(): Int = value
}

fun main() {
    println("Hello, Kotlin!")
    var sum = 0
    for (i in 1..10) sum += i
    println("sum = $sum")
    println(fib(15))

    val xs = listOf(5, 2, 9, 1)
    println(xs.sorted())
    println(xs.map { it * it })
    println(xs.filter { it > 2 })
    println(xs.sum())
    println(xs.maxOrNull())

    val p = Point(3, 4)
    println(p)
    println(p.x + p.y)

    for (c in listOf(Color.RED, Color.GREEN)) println(c)

    println(describe(-1))
    println(describe(0))
    println(describe(5))
    println(describe(50))

    val c = Counter(10)
    c.increment()
    c.increment()
    println(c.get())

    val m = mutableMapOf("a" to 1, "b" to 2)
    m["c"] = 3
    println(m["a"]!! + m["c"]!!)
    println(m.keys.sorted())

    val words = listOf("pear", "apple", "fig")
    println(words.sortedBy { it.length })
    println(words.joinToString(", "))

    val s = "Hello, World"
    println(s.length)
    println(s.uppercase())
    println(s.substring(7))
    println(s.split(", "))

    var i = 0
    while (i < 3) { print("$i "); i++ }
    println()
    println(listOf(1,2,3).fold(0) { acc, v -> acc + v })
}
