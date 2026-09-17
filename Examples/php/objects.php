<?php
class Stack {
    private $items = [];
    public function push($item) { $this->items[] = $item; return $this; }
    public function pop() { return array_pop($this->items); }
    public function peek() { return end($this->items) ?: null; }
    public function size() { return count($this->items); }
    public function isEmpty() { return $this->size() === 0; }
}
$stack = new Stack();
$stack->push(1)->push(2)->push(3);
echo $stack->size(), " ", $stack->pop(), " ", $stack->size(), " ", $stack->isEmpty() ? "empty" : "filled", "\n";

class Matrix {
    private $data;
    public function __construct(array $data) { $this->data = $data; }
    public function multiply(Matrix $other) {
        $result = [];
        $otherData = $other->raw();
        foreach ($this->data as $i => $row) {
            foreach ($otherData[0] as $j => $ignored) {
                $sum = 0;
                foreach ($row as $k => $value) $sum += $value * $otherData[$k][$j];
                $result[$i][$j] = $sum;
            }
        }
        return new Matrix($result);
    }
    public function raw() { return $this->data; }
}
$a = new Matrix([[1, 2], [3, 4]]);
$b = new Matrix([[5, 6], [7, 8]]);
echo json_encode($a->multiply($b)->raw()), "\n";
