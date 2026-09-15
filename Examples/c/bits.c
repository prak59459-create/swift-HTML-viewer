#include <stdio.h>
int popcount(unsigned int value) {
    int count = 0;
    while (value) { count += value & 1; value >>= 1; }
    return count;
}
int main(void) {
    for (int i = 0; i < 8; i++) printf("%d%s", popcount(i), i == 7 ? "\n" : " ");
    printf("%x %X %o\n", 3735928559u, 48879, 511);
    int mask = 0;
    for (int bit = 0; bit < 5; bit++) mask |= 1 << bit;
    printf("%d %d %d\n", mask, mask ^ 0xF, ~mask & 0xFF);
    return 0;
}
