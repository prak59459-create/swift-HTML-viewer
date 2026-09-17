use strict;
use warnings;

sub fib {
    my ($n) = @_;
    return $n if $n < 2;
    return fib($n - 1) + fib($n - 2);
}

sub greet {
    my ($name, $greeting) = @_;
    return "$greeting, $name!";
}

my @fibs;
for (my $i = 0; $i < 10; $i++) {
    push @fibs, fib($i);
}
print "fib: ", join(", ", @fibs), "\n";

print greet("World", "Hello"), "\n";

my @nums = (5, 3, 9, 1, 7);
my @sorted = sort { $a <=> $b } @nums;
print "sorted: @sorted\n";
print "count: ", scalar(@nums), "\n";

my @doubled = map { $_ * 2 } @nums;
print "doubled: @doubled\n";

my @big = grep { $_ > 3 } @nums;
print "big: @big\n";

my $total = 0;
foreach my $n (@nums) {
    $total += $n;
}
print "total: $total\n";

my %ages = ("alice", 30, "bob", 25);
$ages{"carol"} = 35;
foreach my $name (sort keys %ages) {
    print "$name is $ages{$name}\n";
}

my $text = "Hello, Perl World";
print "upper: ", uc($text), "\n";
print "length: ", length($text), "\n";
print "words: ", join("|", split(/,?\s+/, $text)), "\n";

if ($text =~ /Perl/) {
    print "matched Perl\n";
}

my $copy = $text;
$copy =~ s/World/Hackers/;
print "replaced: $copy\n";

my $i = 0;
while ($i < 3) {
    print "i=$i\n";
    $i++;
}

unless (0) {
    print "unless works\n";
}

printf("pi is about %.3f\n", 22 / 7);
print "17 % 5 = ", 17 % 5, "\n";
print "2 ** 10 = ", 2 ** 10, "\n";
print "concat: " . "a" . "b" . "\n";
print "repeat: ", "-" x 10, "\n";
