#!/bin/bash
# シェルの基本

fib() {
    local n=$1
    if [ "$n" -lt 2 ]; then
        echo "$n"
    else
        local a=$(fib $((n - 1)))
        local b=$(fib $((n - 2)))
        echo $((a + b))
    fi
}

out=""
for i in 0 1 2 3 4 5 6 7 8 9; do
    out="$out $(fib $i)"
done
echo "fib:$out"

name="World"
greeting="Hello"
echo "$greeting, $name!"

nums="5 3 9 1 7"
total=0
for n in $nums; do
    total=$((total + n))
done
echo "total: $total"

echo "sorted: $(echo "$nums" | tr ' ' '\n' | sort -n | tr '\n' ' ')"

i=0
while [ $i -lt 3 ]; do
    echo "i = $i"
    i=$((i + 1))
done

count=0
until [ $count -ge 2 ]; do
    echo "count = $count"
    count=$((count + 1))
done

for ((j = 0; j < 3; j++)); do
    echo "j = $j"
done

check() {
    if [ "$1" -gt 10 ]; then
        echo "$1 is large"
    elif [ "$1" -eq 0 ]; then
        echo "$1 is zero"
    else
        echo "$1 is small"
    fi
}

check 42
check 0
check 3

case "banana" in
    apple) echo "it is an apple" ;;
    banana|cherry) echo "banana or cherry" ;;
    *) echo "something else" ;;
esac

text="Hello, Shell"
echo "length: ${#text}"
echo "default: ${missing:-fallback}"
echo "upper: $(echo "$text" | tr 'a-z' 'A-Z')"

if [ -z "" ]; then
    echo "empty string detected"
fi

true && echo "and works"
false || echo "or works"

printf "%s has %d chars\n" "$text" "${#text}"
echo "arith: $((17 / 5)) remainder $((17 % 5))"
echo "lines: $(seq 1 5 | wc -l)"
