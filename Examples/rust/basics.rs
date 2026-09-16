use std::collections::HashMap;

#[derive(Debug, Clone)]
struct Point {
    x: i32,
    y: i32,
}

impl Point {
    fn new(x: i32, y: i32) -> Point {
        Point { x, y }
    }
    fn norm(&self) -> i32 {
        self.x * self.x + self.y * self.y
    }
}

#[derive(Debug)]
enum Shape {
    Circle(f64),
    Rect(f64, f64),
}

fn area(s: &Shape) -> f64 {
    match s {
        Shape::Circle(r) => 3.14159 * r * r,
        Shape::Rect(w, h) => w * h,
    }
}

fn fib(n: u32) -> u64 {
    if n < 2 { n as u64 } else { fib(n - 1) + fib(n - 2) }
}

fn divide(a: i32, b: i32) -> Option<i32> {
    if b == 0 { None } else { Some(a / b) }
}

fn main() {
    println!("Hello, Rust!");

    let mut sum = 0;
    for i in 1..=10 {
        sum += i;
    }
    println!("sum = {}", sum);
    println!("{}", fib(20));

    let mut v = vec![5, 2, 9, 1];
    v.sort();
    println!("{:?}", v);

    let squares: Vec<i32> = v.iter().map(|x| x * x).collect();
    println!("{:?}", squares);
    let total: i32 = squares.iter().sum();
    println!("{}", total);

    let p = Point::new(3, 4);
    println!("{} {:?}", p.norm(), p);

    let shapes = vec![Shape::Circle(2.0), Shape::Rect(3.0, 4.0)];
    for s in &shapes {
        println!("{:.3}", area(s));
    }

    match divide(10, 2) {
        Some(n) => println!("ok {}", n),
        None => println!("none"),
    }
    println!("{:?}", divide(1, 0));

    let mut counts: HashMap<String, i32> = HashMap::new();
    for word in "a b a c b a".split_whitespace() {
        *counts.entry(word.to_string()).or_insert(0) += 1;
    }
    let mut keys: Vec<&String> = counts.keys().collect();
    keys.sort();
    for k in keys {
        println!("{}={}", k, counts[k]);
    }

    let s = String::from("hello");
    println!("{} {} {}", s.len(), s.to_uppercase(), s.contains("ell"));
    println!("{:>8}|{:<8}|{:^8}|", "r", "l", "c");
    println!("{:05}|{:.2}", 42, 3.14159);
}
