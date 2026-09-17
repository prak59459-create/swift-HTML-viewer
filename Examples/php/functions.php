<?php
function fib($n) {
    if ($n < 2) return $n;
    return fib($n - 1) + fib($n - 2);
}
function greet($name, $greeting = "Hello") {
    return "$greeting, $name!";
}
function sum(...$numbers) {
    $total = 0;
    foreach ($numbers as $number) $total += $number;
    return $total;
}
for ($i = 0; $i < 10; $i++) echo fib($i), " ";
echo "\n", greet("Alice"), " ", greet("Bob", "Hi"), "\n";
echo sum(1, 2, 3, 4, 5), "\n";
$double = function ($x) { return $x * 2; };
$apply = function ($f, $v) { return $f($v); };
echo $apply($double, 21), "\n";
$factor = 10;
$scale = function ($x) use ($factor) { return $x * $factor; };
echo $scale(5), "\n";
