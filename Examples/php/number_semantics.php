<?php
echo 7 / 2, " ", 8 / 2, " ", intdiv(7, 2), " ", 7 % 3, " ", 2 ** 10, "\n";
echo 0.1 + 0.2, " ", 1 / 3, " ", 10 / 4, "\n";
echo (int)"42abc", " ", (float)"3.5x", " ", (string)42, " ", (int)3.99, "\n";
echo "10" + 5, " ", "3.5" + 1, " ", "abc" == 0 ? "t" : "f", " ", "1" == "01" ? "t" : "f", "\n";
echo 1 <=> 2, " ", 2 <=> 2, " ", 3 <=> 2, "\n";
var_dump(0 == "a");
var_dump("1" === 1);
var_dump(null == false);
var_dump([1,2] == [1,2]);
echo PHP_INT_MAX, " ", PHP_EOL;
echo max(3, 7, 2), " ", min([4, 2, 8]), " ", abs(-5), " ", round(2.567, 2), " ", floor(-2.5), " ", ceil(2.1), "\n";
echo sqrt(16), " ", pow(2, 8), " ", number_format(pi(), 5), "\n";
