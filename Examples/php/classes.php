<?php
class Animal {
    public $name;
    protected $sound = "...";
    public function __construct($name) {
        $this->name = $name;
    }
    public function speak() {
        return "{$this->name} says {$this->sound}";
    }
}
class Dog extends Animal {
    protected $sound = "Woof";
    public function __construct($name, $tricks = []) {
        parent::__construct($name);
        $this->tricks = $tricks;
    }
    public function speak() {
        return parent::speak() . "!";
    }
    public function trickCount() {
        return count($this->tricks);
    }
}
$animals = [new Animal("Generic"), new Dog("Rex", ["sit", "roll"])];
foreach ($animals as $animal) {
    echo $animal->speak(), "\n";
}
$dog = $animals[1];
echo $dog->trickCount(), " ", get_class($dog), " ", ($dog instanceof Animal ? "yes" : "no"), "\n";
