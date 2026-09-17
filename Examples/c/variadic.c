#include <stdio.h>
#include <stdarg.h>
int sumInts(int count, ...) {
    va_list arguments;
    va_start(arguments, count);
    int total = 0;
    for (int i = 0; i < count; i++) total += va_arg(arguments, int);
    va_end(arguments);
    return total;
}
double product(int count, ...) {
    va_list arguments;
    va_start(arguments, count);
    double result = 1.0;
    for (int i = 0; i < count; i++) result *= va_arg(arguments, double);
    va_end(arguments);
    return result;
}
void joinStrings(char *buffer, int count, ...) {
    va_list arguments;
    va_start(arguments, count);
    buffer[0] = 0;
    for (int i = 0; i < count; i++) {
        char *piece = va_arg(arguments, char *);
        int length = 0;
        while (buffer[length] != 0) length++;
        int j = 0;
        while (piece[j] != 0) { buffer[length + j] = piece[j]; j++; }
        buffer[length + j] = 0;
    }
    va_end(arguments);
}
int main(void) {
    printf("%d %d %d\n", sumInts(1, 5), sumInts(3, 1, 2, 3), sumInts(6, 1, 1, 1, 1, 1, 1));
    printf("%.3f\n", product(4, 1.5, 2.0, 0.5, 4.0));
    char buffer[64];
    joinStrings(buffer, 3, "abc", "-", "xyz");
    printf("%s\n", buffer);
    return 0;
}
