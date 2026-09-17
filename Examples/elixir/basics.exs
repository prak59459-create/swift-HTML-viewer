defmodule Math do
  def fib(0), do: 0
  def fib(1), do: 1
  def fib(n) when n > 1, do: fib(n - 1) + fib(n - 2)

  def square(x), do: x * x

  def sum(list) do
    Enum.reduce(list, 0, fn x, acc -> x + acc end)
  end

  def classify(n) do
    cond do
      n < 0 -> "negative"
      n == 0 -> "zero"
      n < 10 -> "small"
      true -> "large"
    end
  end
end

fibs = Enum.map(0..9, &Math.fib/1)
IO.puts("fib: #{Enum.join(fibs, ", ")}")

nums = [5, 3, 9, 1, 7]
IO.puts("sum: #{Math.sum(nums)}")
IO.puts("squares: #{Enum.join(Enum.map(nums, &Math.square/1), ", ")}")
IO.puts("big: #{Enum.join(Enum.filter(nums, fn x -> x > 3 end), ", ")}")
IO.puts("sorted: #{Enum.join(Enum.sort(nums), ", ")}")
IO.puts("count: #{Enum.count(nums)}")

piped = nums |> Enum.filter(fn x -> x > 3 end) |> Enum.map(fn x -> x * 10 end) |> Enum.sum()
IO.puts("piped: #{piped}")

for n <- [-5, 0, 3, 42] do
  IO.puts("#{n} is #{Math.classify(n)}")
end

point = {3, 4}
{x, y} = point
IO.puts("point: #{x}, #{y}")

person = %{name: "Alice", age: 30}
IO.puts("name: #{person.name}, age: #{Map.get(person, :age)}")
IO.puts("keys: #{Enum.join(Enum.map(Map.keys(person), &to_string/1), ", ")}")

text = "Hello, Elixir"
IO.puts("upper: #{String.upcase(text)}")
IO.puts("length: #{String.length(text)}")
IO.puts("parts: #{Enum.join(String.split(text, ", "), "|")}")

result = case 7 do
  1 -> "one"
  7 -> "seven"
  _ -> "other"
end
IO.puts("case: #{result}")

value = if 3 > 2, do: "yes", else: "no"
IO.puts("if: #{value}")

IO.puts("concat: #{"foo" <> "bar"}")
IO.puts("list: #{Enum.join([1, 2] ++ [3, 4], ",")}")
IO.puts("div: #{div(17, 5)} rem: #{rem(17, 5)}")
IO.inspect(%{a: 1, b: 2})
IO.inspect([1, :two, "three"])
