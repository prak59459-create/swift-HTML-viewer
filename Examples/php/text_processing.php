<?php
$text = "The quick brown fox jumps over the lazy dog";
$words = explode(" ", $text);
$lengths = [];
foreach ($words as $word) {
    $key = strtolower($word);
    $lengths[$key] = strlen($word);
}
ksort($lengths);
foreach ($lengths as $word => $length) echo "$word($length) ";
echo "\n";
$longest = "";
foreach ($words as $word) if (strlen($word) > strlen($longest)) $longest = $word;
echo $longest, " ", str_word_count($text), " ", ucwords(strtolower($text)), "\n";
echo wordwrap($text, 15, "|"), "\n";
$vowels = 0;
foreach (str_split(strtolower($text)) as $character) {
    if (strpos("aeiou", $character) !== false) $vowels++;
}
echo "vowels=$vowels\n";
echo str_replace(" ", "_", $text), "\n";
echo strtr_like($text), "\n";
function strtr_like($text) { return strrev(strtoupper(substr($text, 0, 9))); }
