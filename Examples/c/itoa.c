#include <stdio.h>
#include <string.h>
void reverse(char *text, int length) {
    for (int i = 0; i < length / 2; i++) {
        char t = text[i];
        text[i] = text[length - 1 - i];
        text[length - 1 - i] = t;
    }
}
int toText(int value, char *buffer) {
    int negative = value < 0;
    if (negative) value = -value;
    int length = 0;
    if (value == 0) buffer[length++] = '0';
    while (value > 0) {
        buffer[length++] = (char)('0' + value % 10);
        value /= 10;
    }
    if (negative) buffer[length++] = '-';
    buffer[length] = 0;
    reverse(buffer, length);
    return length;
}
int main(void) {
    char buffer[32];
    int lengths = 0;
    int values[5] = {0, 7, -42, 1234, -987654};
    for (int i = 0; i < 5; i++) {
        lengths += toText(values[i], buffer);
        printf("[%s]", buffer);
    }
    printf("\n%d\n", lengths);
    return 0;
}
