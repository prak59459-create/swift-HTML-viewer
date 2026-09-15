#include <stdio.h>
int main(void) {
    printf("|%5.2f|%-8.3f|%08.2f|\n", 3.14159, 2.5, -1.5);
    printf("|%8s|%-8s|%.2s|\n", "abc", "abc", "abcdef");
    printf("|%3c|%-3c|\n", 'x', 'y');
    printf("|%d%%|\n", 50);
    printf("|%ld|%lu|\n", 1234567890123L, 42UL);
    printf("|%.0f|%.5f|\n", 2.5, 1.0 / 3.0);
    printf("|%*d|\n", 6, 42);
    return 0;
}
