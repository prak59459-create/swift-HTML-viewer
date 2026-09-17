#include <stdio.h>
unsigned long hash(char *text) {
    unsigned long value = 5381;
    for (int i = 0; text[i] != 0; i++) value = value * 33 + (unsigned long)text[i];
    return value;
}
int main(void) {
    printf("%lu %lu\n", hash("hello"), hash("world"));
    unsigned int small = 10;
    unsigned int wrapped = small - 20;
    printf("%u %u\n", wrapped, small / 3);
    unsigned long mask = 0;
    mask = ~mask;
    printf("%lu\n", mask);
    printf("%lu %lu\n", mask >> 60, mask / 3);
    unsigned int a = 4000000000u;
    printf("%u %u %d\n", a, a / 2, a > 5);
    return 0;
}
