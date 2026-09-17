# Crystal 基本テスト
def fib(n : Int32) : Int32
  return n if n < 2
  fib(n - 1) + fib(n - 2)
end

class Animal
  getter name : String

  def initialize(@name : String)
  end

  def speak
    "..."
  end

  def to_s
    "#{@name}: #{speak}"
  end
end

class Dog < Animal
  def speak
    "Wan"
  end
end

struct Point
  property x : Int32
  property y : Int32

  def initialize(@x : Int32, @y : Int32)
  end

  def +(other : Point)
    Point.new(@x + other.x, @y + other.y)
  end
end

puts "fib: #{(0..9).map { |i| fib(i) }.join(", ")}"

animals = [Dog.new("Pochi"), Animal.new("Nazo")]
animals.each do |a|
  puts a.to_s
end

xs = [5, 3, 9, 1, 7]
puts xs.sort.inspect
puts xs.select { |v| v > 3 }.inspect
puts xs.map { |v| v * 2 }.inspect
puts xs.reduce(0) { |acc, v| acc + v }

h = {"a" => 1, "b" => 2}
h["c"] = 3
h.each do |k, v|
  puts "#{k}=#{v}"
end
puts h.size

i = 0
while i < 3
  puts "while #{i}"
  i += 1
end

3.times do |n|
  print n
end
puts

case 7
when 1 then puts "one"
when 7 then puts "seven"
else puts "other"
end

begin
  raise "boom"
rescue ex
  puts "caught: #{ex.message}"
end

s = "Hello, Crystal"
puts s.upcase
puts s.size
puts s.split(", ").inspect
