#include <stdio.h>
#include <string.h>
int main(void) {
    char text[64] = "one,two,,three";
    char *cursor = text;
    int fields = 0;
    while (1) {
        char *comma = strchr(cursor, ',');
        if (comma == 0) { printf("[%s]", cursor); fields++; break; }
        *comma = 0;
        printf("[%s]", cursor);
        fields++;
        cursor = comma + 1;
    }
    printf("\n%d\n", fields);
    printf("%d %d %d\n", strncmp("abcdef", "abcxyz", 3), strncmp("abc", "abd", 3) < 0, (int)strlen(text));
    return 0;
}
