package main

import (
	"fmt"
	"sort"
	"strings"
)

type Point struct {
	X int
	Y int
}

func (p Point) Norm() int {
	return p.X*p.X + p.Y*p.Y
}

func divmod(a, b int) (int, int) {
	return a / b, a % b
}

func main() {
	fmt.Println("Hello, Go!")

	sum := 0
	for i := 1; i <= 10; i++ {
		sum += i
	}
	fmt.Println("sum =", sum)

	xs := []int{5, 2, 9, 1}
	sort.Ints(xs)
	fmt.Println(xs)

	for i, v := range xs {
		fmt.Printf("%d:%d ", i, v)
	}
	fmt.Println()

	m := map[string]int{"a": 1, "b": 2}
	fmt.Println(m["a"] + m["b"])
	fmt.Println(m)

	p := Point{X: 3, Y: 4}
	fmt.Println(p.Norm())
	fmt.Println(p)

	q, r := divmod(17, 5)
	fmt.Println(q, r)

	s := strings.Join([]string{"a", "b", "c"}, "-")
	fmt.Println(s, strings.ToUpper(s), len(s))

	fmt.Printf("%s|%5d|%.3f|%v\n", "x", 42, 3.14159, true)

	nums := []int{}
	for i := 0; i < 5; i++ {
		nums = append(nums, i*i)
	}
	fmt.Println(nums)

	switch n := 7; {
	case n < 5:
		fmt.Println("small")
	case n < 10:
		fmt.Println("medium")
	default:
		fmt.Println("large")
	}
}
