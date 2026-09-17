#include <stdio.h>
int position;
char *input;
int parseExpression(void);
int parseNumber(void) {
    int value = 0;
    while (input[position] == ' ') position++;
    if (input[position] == '(') {
        position++;
        value = parseExpression();
        if (input[position] == ')') position++;
        return value;
    }
    int negative = 0;
    if (input[position] == '-') { negative = 1; position++; }
    while (input[position] >= '0' && input[position] <= '9') {
        value = value * 10 + (input[position] - '0');
        position++;
    }
    return negative ? -value : value;
}
int parseTerm(void) {
    int value = parseNumber();
    while (1) {
        while (input[position] == ' ') position++;
        char op = input[position];
        if (op != '*' && op != '/') return value;
        position++;
        int right = parseNumber();
        if (op == '*') value *= right; else value /= right;
    }
}
int parseExpression(void) {
    int value = parseTerm();
    while (1) {
        while (input[position] == ' ') position++;
        char op = input[position];
        if (op != '+' && op != '-') return value;
        position++;
        int right = parseTerm();
        if (op == '+') value += right; else value -= right;
    }
}
int main(void) {
    char *programs[4] = {"1 + 2 * 3", "(1 + 2) * 3", "100 / 7 - 4", "2 * (3 + 4) * (5 - 1)"};
    for (int i = 0; i < 4; i++) {
        input = programs[i];
        position = 0;
        printf("%s = %d\n", programs[i], parseExpression());
    }
    return 0;
}
