<?php
printf("%s has %d items costing %.2f\n", "cart", 3, 9.5);
echo sprintf("[%5d][%-5d][%05.1f][%s]\n", 42, 42, 3.14159, "x");
echo sprintf("%b %o %x %X %c\n", 10, 64, 255, 255, 65);
echo sprintf("%1\$s-%2\$s-%1\$s\n", "a", "b");
echo number_format(1234567.891, 2), " ", number_format(1234567.891), "\n";
echo str_pad("7", 3, "0", STR_PAD_LEFT), " ", str_pad("ab", 6, "-"), "\n";
echo ucfirst("hello"), " ", ucwords("hello wide world"), " ", strrev("abc"), "\n";
echo trim("  padded  "), "|", rtrim("xx--", "-"), "|", ltrim("0012", "0"), "\n";
echo substr("abcdef", 2), " ", substr("abcdef", -2), " ", substr("abcdef", 1, 3), "\n";
echo strpos("hello world", "o"), " ", strrpos("hello world", "o"), " ";
var_dump(strpos("abc", "z"));
echo str_replace(["a", "b"], ["1", "2"], "aabbc"), "\n";
echo implode("-", str_split("abcdef", 2)), "\n";
echo substr_count("hello hello", "llo"), " ", str_contains("haystack", "st") ? "y" : "n", "\n";
