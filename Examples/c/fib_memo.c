#include <stdio.h>
long memo[60];
long fib(int n) {
    if (n < 2) return n;
    if (memo[n] != 0) return memo[n];
    memo[n] = fib(n - 1) + fib(n - 2);
    return memo[n];
}
int main(void) {
    for (int i = 0; i < 60; i++) memo[i] = 0;
    printf("%ld %ld %ld\n", fib(30), fib(50), fib(59));
    long big = 1;
    for (int i = 0; i < 40; i++) big *= 2;
    printf("%ld\n", big);
    return 0;
}
