import strutils, tables

proc fib(n: int): int =
  if n < 2:
    return n
  return fib(n - 1) + fib(n - 2)

proc sum(xs: seq[int]): int =
  for x in xs:
    result = result + x

type
  Color = enum
    Red, Green, Blue
  Point = object
    x, y: int
  Shape = ref object of RootObj
    name: string
  Circle = ref object of Shape
    r: float

method area(s: Shape): float =
  0.0

method area(c: Circle): float =
  3.14159 * c.r * c.r

proc `$`(p: Point): string =
  "(" & $p.x & ", " & $p.y & ")"

var results: seq[int] = @[]
for i in 0..9:
  results.add(fib(i))
echo "fib: ", results

let xs = @[5, 3, 9, 1, 7]
echo "sum = ", sum(xs)
echo "len = ", xs.len
echo "max = ", max(xs)

var p = Point(x: 3, y: 4)
echo "point: ", $p
echo "shifted: ", p.x + 1

let c = Circle(name: "c1", r: 2.0)
echo "area = ", c.area()

var counts = initTable[string, int]()
for word in "a b a c b a".split(" "):
  if counts.hasKey(word):
    counts[word] = counts[word] + 1
  else:
    counts[word] = 1
echo "a=", counts["a"], " b=", counts["b"], " c=", counts["c"]

var i = 0
while i < 3:
  echo "i=", i
  i = i + 1

case 7
of 1:
  echo "one"
of 7:
  echo "seven"
else:
  echo "other"

let color = Green
case color
of Red:
  echo "red"
of Green:
  echo "green"
else:
  echo "blue"

try:
  discard parseInt("abc")
except ValueError as e:
  echo "caught: ", e.msg

echo "10 div 3 = ", 10 div 3
echo "10 mod 3 = ", 10 mod 3
echo "upper: ", toUpperAscii("hello")
echo "joined: ", @["a", "b", "c"].join("-")
