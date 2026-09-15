#include <stdio.h>
int combine(int a, int b, int c, int d, int e, int f, int g, int h) {
    return a * 1 + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8;
}
int ackermann(int m, int n) {
    if (m == 0) return n + 1;
    if (n == 0) return ackermann(m - 1, 1);
    return ackermann(m - 1, ackermann(m, n - 1));
}
struct Item { int id; double price; };
int main(void) {
    printf("%d\n", combine(1, 2, 3, 4, 5, 6, 7, 8));
    printf("%d %d %d\n", ackermann(1, 3), ackermann(2, 3), ackermann(3, 3));
    struct Item items[3] = {{1, 1.5}, {2, 2.25}, {3, 3.75}};
    struct Item *cursor = items;
    double total = 0;
    for (int i = 0; i < 3; i++) { total += cursor->price; cursor++; }
    printf("%.2f %d\n", total, (int)(cursor - items));
    return 0;
}
