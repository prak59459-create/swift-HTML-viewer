#include <stdio.h>
int gcd(int a, int b) { return b == 0 ? a : gcd(b, a % b); }
int main(void) {
    printf("%d %d %d\n", gcd(48, 18), gcd(17, 5), 48 / gcd(48, 18) * 18);
    int n = 360;
    printf("%d =", n);
    for (int d = 2; d * d <= n; d++) {
        while (n % d == 0) { printf(" %d", d); n /= d; }
    }
    if (n > 1) printf(" %d", n);
    printf("\n");
    return 0;
}
