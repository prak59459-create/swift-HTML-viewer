using System;
using System.Collections.Generic;
using System.Linq;

class Point {
    public int X { get; set; }
    public int Y { get; set; }
    public Point(int x, int y) { X = x; Y = y; }
    public override string ToString() { return "(" + X + ", " + Y + ")"; }
    public int Norm() { return X * X + Y * Y; }
}

enum Color { Red, Green, Blue }

class Program {
    static int Fib(int n) {
        if (n < 2) return n;
        return Fib(n - 1) + Fib(n - 2);
    }

    static void Main(string[] args) {
        Console.WriteLine("Hello, C#!");
        int sum = 0;
        for (int i = 1; i <= 10; i++) sum += i;
        Console.WriteLine("sum = " + sum);
        Console.WriteLine(Fib(15));

        List<int> xs = new List<int>();
        for (int i = 5; i > 0; i--) xs.Add(i * i);
        xs.Sort();
        Console.WriteLine(string.Join(", ", xs));

        var evens = xs.Where(x => x % 2 == 0).ToList();
        Console.WriteLine(string.Join(", ", evens));
        Console.WriteLine(xs.Sum());

        Point p = new Point(3, 4);
        Console.WriteLine(p);
        Console.WriteLine(p.Norm());

        foreach (Color c in new Color[] { Color.Red, Color.Blue }) {
            switch (c) {
                case Color.Red: Console.WriteLine("warm"); break;
                default: Console.WriteLine("cool"); break;
            }
        }

        Dictionary<string, int> counts = new Dictionary<string, int>();
        counts["a"] = 1;
        counts["b"] = 2;
        Console.WriteLine(counts["a"] + counts["b"]);

        string s = "Hello, World";
        Console.WriteLine(s.Length);
        Console.WriteLine(s.ToUpper());
        Console.WriteLine(s.Substring(7));
        Console.WriteLine($"name={s.Length} and {sum}");
        Console.WriteLine("{0} + {1} = {2}", 2, 3, 5);
        Console.WriteLine(7 / 2);
        Console.WriteLine(1.0 / 3.0);

        try {
            int z = 0;
            Console.WriteLine(10 / z);
        } catch (DivideByZeroException) {
            Console.WriteLine("caught");
        }
    }
}
