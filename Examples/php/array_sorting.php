<?php
$people = [
    ['name' => 'alice', 'age' => 30],
    ['name' => 'bob', 'age' => 25],
    ['name' => 'carol', 'age' => 35],
];
usort($people, function ($a, $b) { return $a['age'] - $b['age']; });
foreach ($people as $person) {
    echo $person['name'], "=", $person['age'], " ";
}
echo "\n";
$ages = array_map(function ($p) { return $p['age']; }, $people);
echo implode(",", $ages), "\n";
$adults = array_filter($ages, function ($age) { return $age >= 30; });
echo count($adults), " ", array_sum($ages), " ", max($ages), " ", min($ages), "\n";
$total = array_reduce($ages, function ($carry, $age) { return $carry + $age; }, 0);
echo $total, "\n";
$map = ['b' => 2, 'a' => 1, 'c' => 3];
ksort($map);
echo implode(",", array_keys($map)), " ", implode(",", array_values($map)), "\n";
arsort($map);
echo implode(",", array_keys($map)), "\n";
