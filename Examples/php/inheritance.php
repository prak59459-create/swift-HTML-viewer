<?php
class Shape {
    const SIDES = 0;
    public static $created = 0;
    protected $name;
    public function __construct($name) { $this->name = $name; }
    public function describe() { return "{$this->name} with " . static::SIDES . " sides"; }
    public function getName() { return $this->name; }
}
class Square extends Shape {
    const SIDES = 4;
    private $length;
    public function __construct($length) {
        parent::__construct("square");
        $this->length = $length;
    }
    public function area() { return $this->length ** 2; }
    public function describe() { return parent::describe() . ", area " . $this->area(); }
}
class Circle extends Shape {
    private $radius;
    public function __construct($radius) { parent::__construct("circle"); $this->radius = $radius; }
    public function area() { return round(M_PI * $this->radius ** 2, 2); }
}
$shapes = [new Square(3), new Circle(2)];
foreach ($shapes as $shape) {
    echo get_class($shape), ": ", $shape->getName(), " area=", $shape->area(), "\n";
}
echo (new Square(5))->describe(), "\n";
echo Shape::SIDES, " ", Square::SIDES, "\n";
echo method_exists($shapes[0], 'area') ? "has area" : "no area", "\n";
