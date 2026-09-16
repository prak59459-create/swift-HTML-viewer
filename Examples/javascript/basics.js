class Point {
  constructor(x, y) { this.x = x; this.y = y; }
  norm() { return this.x * this.x + this.y * this.y; }
  toString() { return `(${this.x}, ${this.y})`; }
}

class Point3 extends Point {
  constructor(x, y, z) { super(x, y); this.z = z; }
  norm() { return super.norm() + this.z * this.z; }
}

function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

console.log("Hello, JavaScript!");
let sum = 0;
for (let i = 1; i <= 10; i++) sum += i;
console.log("sum =", sum);
console.log(fib(20));

const xs = [5, 2, 9, 1];
console.log(xs.map(x => x * x));
console.log(xs.filter(x => x > 2));
console.log(xs.reduce((a, b) => a + b, 0));
console.log([...xs].sort((a, b) => a - b));
console.log(xs.join("-"));

const p = new Point(3, 4);
console.log(p.norm(), String(p));
const q = new Point3(1, 2, 2);
console.log(q.norm());

const obj = { a: 1, b: "two", c: [3, 4], d: { e: 5 } };
console.log(obj);
console.log(Object.keys(obj));
console.log(JSON.stringify(obj));
console.log(JSON.parse('{"x":1,"y":[2,3]}'));

const m = new Map([["a", 1], ["b", 2]]);
m.set("c", 3);
console.log(m.get("a") + m.get("c"), m.size);

const { a, b } = obj;
console.log(a, b);
const [first, ...rest] = xs;
console.log(first, rest);

console.log(typeof 1, typeof "s", typeof true, typeof undefined, typeof {});
console.log(1 == "1", 1 === "1", null == undefined, null === undefined);
console.log(7 / 2, 7 % 3, 2 ** 10);
console.log(0.1 + 0.2);
console.log("abc".toUpperCase(), "a,b,c".split(","), "  x ".trim());
console.log([1, [2, [3]]].flat());

try {
  throw new Error("boom");
} catch (e) {
  console.log("caught:", e.message);
} finally {
  console.log("done");
}

const counts = {};
for (const w of "a b a c b a".split(" ")) {
  counts[w] = (counts[w] || 0) + 1;
}
console.log(counts);

function* nothing() {}
const add = (x, y = 10) => x + y;
console.log(add(1), add(1, 2));
