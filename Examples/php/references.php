<?php
function addSuffix(array &$items, $suffix) {
    foreach ($items as &$item) {
        $item .= $suffix;
    }
    unset($item);
    $items[] = "extra$suffix";
}
$list = ["a", "b"];
addSuffix($list, "!");
echo implode(",", $list), "\n";
function increment(&$value, $by = 1) { $value += $by; }
$counter = 5;
increment($counter);
increment($counter, 10);
echo $counter, "\n";
$matrix = [[1,2],[3,4]];
foreach ($matrix as &$row) {
    foreach ($row as &$cell) $cell *= 2;
    unset($cell);
}
unset($row);
echo json_encode($matrix), "\n";
$config = ['debug' => false];
$config['level'] = 3;
$config['nested']['deep'] = 'value';
echo json_encode($config), "\n";
