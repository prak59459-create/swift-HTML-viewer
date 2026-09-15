<?php
$matrix = [[1, 2, 3], [4, 5, 6], [7, 8, 9]];
$sum = 0;
foreach ($matrix as $row) {
    foreach ($row as $value) $sum += $value;
}
echo $sum, "\n";
$transposed = [];
for ($i = 0; $i < 3; $i++) {
    for ($j = 0; $j < 3; $j++) {
        $transposed[$j][$i] = $matrix[$i][$j];
    }
}
foreach ($transposed as $row) echo implode(",", $row), " ";
echo "\n";
$counts = [];
foreach (str_split("hello world") as $character) {
    if ($character === " ") continue;
    if (!isset($counts[$character])) $counts[$character] = 0;
    $counts[$character]++;
}
arsort($counts);
$top = array_slice($counts, 0, 3, true);
foreach ($top as $character => $count) echo "$character:$count ";
echo "\n";
$stack = [];
array_push($stack, 1, 2, 3);
echo array_pop($stack), count($stack), "\n";
$queue = [1, 2, 3];
echo array_shift($queue), implode("", $queue), "\n";
array_unshift($queue, 0);
echo implode("", $queue), "\n";
