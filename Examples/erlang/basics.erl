-module(demo).
-export([main/0]).

fib(0) -> 0;
fib(1) -> 1;
fib(N) when N > 1 -> fib(N - 1) + fib(N - 2).

square(X) -> X * X.

classify(N) when N < 0 -> negative;
classify(0) -> zero;
classify(N) when N < 10 -> small;
classify(_) -> large.

describe({point, X, Y}) -> io:format("point ~p,~p~n", [X, Y]);
describe({circle, R}) -> io:format("circle r=~p~n", [R]);
describe(_) -> io:format("unknown~n", []).

sum([]) -> 0;
sum([H|T]) -> H + sum(T).

main() ->
    Fibs = lists:map(fun fib/1, lists:seq(0, 9)),
    io:format("fib: ~p~n", [Fibs]),

    Nums = [5, 3, 9, 1, 7],
    io:format("sum: ~p~n", [sum(Nums)]),
    io:format("lists:sum: ~p~n", [lists:sum(Nums)]),
    io:format("squares: ~p~n", [lists:map(fun square/1, Nums)]),
    io:format("big: ~p~n", [lists:filter(fun(X) -> X > 3 end, Nums)]),
    io:format("sorted: ~p~n", [lists:sort(Nums)]),
    io:format("reversed: ~p~n", [lists:reverse(Nums)]),
    io:format("length: ~p~n", [length(Nums)]),
    io:format("folded: ~p~n", [lists:foldl(fun(X, Acc) -> X + Acc end, 0, Nums)]),

    lists:map(fun(N) -> io:format("~p is ~p~n", [N, classify(N)]) end, [-5, 0, 3, 42]),

    describe({point, 3, 4}),
    describe({circle, 2}),
    describe(other),

    Point = {3, 4},
    {X, Y} = Point,
    io:format("x=~p y=~p~n", [X, Y]),

    Person = #{name => "Alice", age => 30},
    io:format("name: ~s age: ~p~n", [maps:get(name, Person), maps:get(age, Person)]),

    Result = case 7 of
        1 -> one;
        7 -> seven;
        _ -> other
    end,
    io:format("case: ~p~n", [Result]),

    Value = if
        3 > 2 -> yes;
        true -> no
    end,
    io:format("if: ~p~n", [Value]),

    io:format("concat: ~p~n", [[1, 2] ++ [3, 4]]),
    io:format("div: ~p rem: ~p~n", [17 div 5, 17 rem 5]),
    io:format("upper: ~s~n", [string:to_upper("hello erlang")]),
    io:format("joined: ~s~n", [string:join(["a", "b", "c"], "-")]).
