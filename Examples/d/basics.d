import std.stdio;
import std.algorithm;
import std.array;

struct Point {
    int x;
    int y;
    int norm() { return x * x + y * y; }
}

class Counter {
    private int value;
    this(int start) { value = start; }
    void increment() { value++; }
    int get() { return value; }
}

int fib(int n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

void main() {
    writeln("Hello, D!");

    int sum = 0;
    for (int i = 1; i <= 10; i++) sum += i;
    writeln("sum = ", sum);
    writeln(fib(15));

    int[] xs = [5, 2, 9, 1];
    sort(xs);
    writeln(xs);

    foreach (x; xs) write(x, " ");
    writeln();

    foreach (i, x; xs) write(i, ":", x, " ");
    writeln();

    foreach (i; 0 .. 5) write(i * i, " ");
    writeln();

    string s = "Hello, World";
    writeln(s.length);
    writeln(s.toUpper());
    writeln(s[7 .. $ - 0]);

    int[string] counts;
    counts["a"] = 1;
    counts["b"] = 2;
    writeln(counts["a"] + counts["b"]);
    writeln(counts);

    Point p = Point(3, 4);
    writeln(p.norm());

    auto c = new Counter(10);
    c.increment();
    writeln(c.get());

    writeln(7 / 2, " ", 7 % 3);
    writefln("%d %s %.2f", 42, "ok", 3.14159);

    auto joined = "a" ~ "b" ~ "c";
    writeln(joined);
    writeln([1, 2] ~ [3]);
}
