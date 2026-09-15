#include <stdio.h>
int parseHex(char *text) {
    int value = 0;
    for (int i = 0; text[i] != 0; i++) {
        char c = text[i];
        int digit = 0;
        if (c >= '0' && c <= '9') digit = c - '0';
        else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
        else continue;
        value = value * 16 + digit;
    }
    return value;
}
int main(void) {
    printf("%d %d %d\n", parseHex("ff"), parseHex("1A2b"), parseHex("0"));
    unsigned long flags = 0;
    for (int bit = 0; bit < 64; bit += 8) flags |= 1UL << bit;
    printf("%lx\n", flags);
    int shifts[4] = {1, 4, 16, 31};
    for (int i = 0; i < 4; i++) printf("%d ", 1 << shifts[i]);
    printf("\n");
    return 0;
}
