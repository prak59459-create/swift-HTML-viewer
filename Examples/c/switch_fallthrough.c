#include <stdio.h>
int main(void) {
    int total = 0;
    for (int i = 0; i < 6; i++) {
        switch (i % 3) {
        case 0:
            total += 1;
        case 1:
            total += 10;
            break;
        case 2:
            total += 100;
        }
    }
    printf("%d\n", total);
    int n = 0;
    do {
        n += 3;
        if (n == 9) continue;
        total += n;
    } while (n < 12);
    printf("%d %d\n", total, n);
    return 0;
}
