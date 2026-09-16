struct Point
    x::Int
    y::Int
end

norm(p::Point) = p.x * p.x + p.y * p.y

function fib(n)
    if n < 2
        return n
    end
    return fib(n - 1) + fib(n - 2)
end

function classify(n)
    if n < 0
        "negative"
    elseif n == 0
        "zero"
    elseif n < 10
        "small"
    else
        "large"
    end
end

println("Hello, Julia!")

s = 0
for i in 1:10
    s += i
end
println("sum = ", s)
println(fib(15))

xs = [5, 2, 9, 1]
println(sort(xs))
println(map(x -> x * x, xs))
println(filter(x -> x > 2, xs))
println(sum(xs))
println(join(xs, "-"))

squares = [x^2 for x in 1:5]
println(squares)
evens = [x for x in 1:10 if x % 2 == 0]
println(evens)

p = Point(3, 4)
println(norm(p))
println(p)

d = Dict("a" => 1, "b" => 2)
println(d["a"] + d["b"])
println(haskey(d, "a"))

text = "Hello, World"
println(length(text))
println(uppercase(text))
println(split(text, ", "))

println(classify(-1), " ", classify(0), " ", classify(5), " ", classify(50))

println(7 / 2)
println(7 ÷ 2)
println(7 % 3)
println(2^10)

println(xs[1], " ", xs[end])

for (i, v) in enumerate(["a", "b"])
    println(i, ":", v)
end

name = "Julia"
println("Hello, $name! 1+2=$(1+2)")
