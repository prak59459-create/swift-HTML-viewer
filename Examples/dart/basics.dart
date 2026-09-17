import 'dart:math' as math;

class Point {
  final int x;
  final int y;
  Point(this.x, this.y);
  int norm() => x * x + y * y;
  @override
  String toString() => 'Point($x, $y)';
}

class Point3 extends Point {
  final int z;
  Point3(int x, int y, this.z) : super(x, y);
  @override
  int norm() => super.norm() + z * z;
}

enum Color { red, green, blue }

int fib(int n) {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}

void main() {
  print('Hello, Dart!');
  var sum = 0;
  for (var i = 1; i <= 10; i++) sum += i;
  print('sum = $sum');
  print(fib(15));

  var xs = [5, 2, 9, 1];
  xs.sort();
  print(xs);
  print(xs.map((x) => x * x).toList());
  print(xs.where((x) => x > 2).toList());
  print(xs.fold(0, (a, b) => a + b));
  print(xs.join('-'));

  var p = Point(3, 4);
  print(p);
  print(p.norm());
  var q = Point3(1, 2, 2);
  print(q.norm());

  var m = {'a': 1, 'b': 2};
  m['c'] = 3;
  print(m['a']! + m['c']!);
  print(m);

  for (var c in Color.values) {
    print(c);
  }

  var s = 'Hello, World';
  print(s.length);
  print(s.toUpperCase());
  print(s.substring(7));
  print(s.split(', '));

  print(7 / 2);
  print(7 ~/ 2);
  print(7 % 3);
  print(3.14159.toStringAsFixed(2));

  var buffer = StringBuffer();
  for (var i = 0; i < 3; i++) buffer.write('$i,');
  print(buffer.toString());

  try {
    throw Exception('boom');
  } catch (e) {
    print('caught');
  }
}
