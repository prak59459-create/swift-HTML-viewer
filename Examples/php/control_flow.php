<?php
function classify($value) {
    switch (true) {
        case $value < 0:
            return "negative";
        case $value === 0:
            return "zero";
        case $value < 10:
            return "small";
        default:
            return "large";
    }
}
foreach ([-5, 0, 3, 42] as $value) echo classify($value), " ";
echo "\n";
$grade = 85;
switch (true) {
    case $grade >= 90: $letter = "A"; break;
    case $grade >= 80: $letter = "B"; break;
    default: $letter = "C";
}
echo $letter, "\n";
$i = 0;
do { echo $i; $i++; } while ($i < 3);
echo "\n";
$n = 10;
while ($n > 0) {
    $n -= 3;
    if ($n === 4) continue;
    if ($n < 0) break;
    echo $n, " ";
}
echo "\n";
for ($i = 0, $j = 10; $i < $j; $i++, $j--) { }
echo "$i $j\n";
$x = null;
echo $x ?? "default", " ", $x ?: "elvis", " ", isset($x) ? "set" : "unset", "\n";
$data = ['a' => 1];
echo $data['b'] ?? "none", " ", empty($data['a']) ? "empty" : "filled", "\n";
