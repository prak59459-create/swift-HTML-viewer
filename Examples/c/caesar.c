#include <stdio.h>
#include <string.h>
char shift(char c, int k) {
    if (c >= 'a' && c <= 'z') return (char)('a' + (c - 'a' + k) % 26);
    if (c >= 'A' && c <= 'Z') return (char)('A' + (c - 'A' + k) % 26);
    return c;
}
int main(void) {
    char text[64] = "Hello, MiniC World!";
    int n = (int)strlen(text);
    for (int i = 0; i < n; i++) text[i] = shift(text[i], 3);
    printf("%s\n", text);
    for (int i = 0; i < n; i++) text[i] = shift(text[i], 23);
    printf("%s\n", text);
    return 0;
}
