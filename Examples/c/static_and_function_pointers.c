#include <stdio.h>
int nextId(void) {
    static int id = 100;
    return id++;
}
int fibonacci(int n) {
    static int calls = 0;
    calls++;
    if (n < 2) { printf("[%d]", calls); return n; }
    return fibonacci(n - 1) + fibonacci(n - 2);
}
int twice(int n) { return n * 2; }
int square(int n) { return n * n; }
int (*chooser(int which))(int) { return which == 0 ? twice : square; }
int main(void) {
    int first = nextId();
    int second = nextId();
    int third = nextId();
    printf("%d %d %d\n", first, second, third);
    printf(" = %d\n", fibonacci(5));
    int (*f)(int) = chooser(0);
    int (*g)(int) = chooser(1);
    printf("%d %d\n", f(7), g(7));
    return 0;
}
