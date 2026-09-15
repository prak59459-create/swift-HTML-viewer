<?php
$data = ['name' => 'widget', 'price' => 9.99, 'tags' => ['a', 'b'], 'stock' => 5, 'ok' => true];
var_dump($data['price']);
var_dump($data['stock']);
var_dump($data['ok']);
var_dump($data['tags']);
var_dump(null);
var_dump(1.0);
var_dump(0.1 + 0.2);
var_dump("multi\nline");
echo json_encode($data), "\n";
echo json_encode([1, 2, 3]), "\n";
echo json_encode(['nested' => ['x' => 1]]), "\n";
print_r($data);
print_r([1, [2, 3]]);
