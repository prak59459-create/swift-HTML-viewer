#include <stdio.h>
int main(void) {
    printf("%d %d %d %d\n", -7 / 2, -7 % 2, 7 / -2, 7 % -2);
    printf("%d %d\n", -8 >> 1, -1 >> 3);
    char small = 200;
    char other = (char)-56;
    printf("%d %d %d\n", small, other, small == other);
    int wide = small;
    printf("%d %c\n", wide, 'A' + 2);
    printf("%d %d\n", (int)'z' - (int)'a', 'a' < 'b');
    double d = -2.7;
    printf("%d %d %.1f\n", (int)d, (int)(d * 10), d);
    return 0;
}
