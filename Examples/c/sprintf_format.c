#include <stdio.h>
#include <string.h>
int main(void) {
    char line[128];
    int written = sprintf(line, "%-6s|%6.2f|%04d|%c", "name", 3.14159, 42, 'x');
    printf("%s (%d)\n", line, written);
    char small[8];
    int needed = snprintf(small, sizeof(small), "%s-%s", "abcdef", "ghijkl");
    printf("[%s] %d %d\n", small, needed, (int)strlen(small));
    char joined[64] = "";
    for (int i = 1; i <= 4; i++) {
        char piece[16];
        sprintf(piece, "%d,", i * i);
        strcat(joined, piece);
    }
    printf("%s\n", joined);
    return 0;
}
