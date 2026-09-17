<?php
function &counter() { static $count = 0; return $count; }
function apply(callable $callback, array $values) {
    $result = [];
    foreach ($values as $value) $result[] = $callback($value);
    return $result;
}
$square = fn($x) => $x * $x;
echo implode(",", apply($square, [1, 2, 3, 4])), "\n";
echo implode(",", apply('strtoupper', ['a', 'b'])), "\n";
$adder = function ($base) {
    return function ($x) use ($base) { return $base + $x; };
};
$add10 = $adder(10);
echo $add10(5), " ", $adder(100)(5), "\n";
$numbers = range(1, 10);
$evens = array_values(array_filter($numbers, fn($n) => $n % 2 === 0));
echo implode(",", $evens), "\n";
echo array_reduce($numbers, fn($carry, $n) => $carry + $n, 0), "\n";
echo implode(",", array_map(null, [1,2,3])), "\n";
echo implode(",", array_map(fn($a, $b) => $a . $b, ['x','y'], ['1','2'])), "\n";
