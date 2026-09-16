interface Shape {
  area(): number;
  name: string;
}

type Pair<T> = { first: T; second: T };

class Circle implements Shape {
  name: string = "circle";
  constructor(private r: number) {}
  area(): number { return 3.14159 * this.r * this.r; }
}

class Rect implements Shape {
  name = "rect";
  constructor(public w: number, public h: number) {}
  area(): number { return this.w * this.h; }
}

enum Color { Red = 1, Green, Blue }

function total<T extends Shape>(shapes: T[]): number {
  return shapes.reduce((sum: number, s: T) => sum + s.area(), 0);
}

const shapes: Shape[] = [new Circle(2), new Rect(3, 4)];
for (const s of shapes) {
  console.log(s.name, s.area().toFixed(3));
}
console.log(total(shapes).toFixed(2));

const p: Pair<number> = { first: 1, second: 2 };
console.log(p.first + p.second);

const names: string[] = ["bob", "alice"];
names.sort();
console.log(names);

let count: number = 0;
const inc = (by: number = 1): number => (count += by);
inc();
inc(5);
console.log(count);

function greet(who: string, greeting?: string): string {
  return `${greeting ?? "Hello"}, ${who}!`;
}
console.log(greet("world"));
console.log(greet("world", "Hi"));

const m: Map<string, number> = new Map();
m.set("a", 1);
console.log(m.get("a"), m.size);

console.log(Color.Red, Color.Green, Color.Blue);
