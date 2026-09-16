class Point {
    int x
    int y
    Point(int x, int y) { this.x = x; this.y = y }
    int norm() { return x * x + y * y }
    String toString() { return "Point($x, $y)" }
}

def fib(n) {
    if (n < 2) return n
    return fib(n - 1) + fib(n - 2)
}

println "Hello, Groovy!"
def sum = 0
for (i in 1..10) sum += i
println "sum = $sum"
println fib(15)

def xs = [5, 2, 9, 1]
println xs.sort()
println xs.collect { it * it }
println xs.findAll { it > 2 }
println xs.inject(0) { a, b -> a + b }
println xs.join("-")

def p = new Point(3, 4)
println p
println p.norm()

def m = [a: 1, b: 2]
m["c"] = 3
println m
println m.a + m.c

def s = "Hello, World"
println s.length()
println s.toUpperCase()
println s.substring(7)
println s.split(", ")

println 7 / 2
println 7.intdiv(2)
println 7 % 3

3.times { print "$it " }
println()

def sb = new StringBuilder()
[1, 2, 3].each { sb.append(it) }
println sb.toString()
