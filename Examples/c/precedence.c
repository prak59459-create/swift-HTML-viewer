#include <stdio.h>
enum Size { SMALL = 1, MEDIUM = SMALL * 4, LARGE = MEDIUM + 6 };
int main(void) {
    printf("%d %d %d\n", SMALL, MEDIUM, LARGE);
    int a = 2, b = 3, c = 4;
    printf("%d %d %d\n", a + b * c, (a + b) * c, a * b % c);
    printf("%d %d\n", a < b == 1, a & b | c);
    printf("%d\n", a > b ? a > c ? a : c : b > c ? b : c);
    int values[3] = {1, 2, 3};
    printf("%d %d %d\n", (int)sizeof values, (int)sizeof values[0], (int)(sizeof values / sizeof values[0]));
    printf("%d %d\n", !!a, -(-a));
    unsigned int u = 4294967295u;
    printf("%u\n", u);
    return 0;
}
