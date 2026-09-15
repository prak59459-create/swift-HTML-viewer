<?php
$name = "world";
$count = 3;
echo "hello, $name!\n";
echo 'single $name', "\n";
for ($i = 1; $i <= $count; $i++) {
    echo "line $i\n";
}
$total = 0;
$values = [3, 1, 4, 1, 5, 9, 2, 6];
foreach ($values as $value) {
    $total += $value;
}
echo "total=$total count=" . count($values) . "\n";
echo strtoupper("abc"), " ", strlen("hello"), " ", str_repeat("ab", 3), "\n";
