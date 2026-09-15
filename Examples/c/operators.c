#include <stdio.h>
struct Box { int width; int height; };
int main(void) {
    int a, b, c;
    a = b = c = 5;
    printf("%d %d %d\n", a, b, c);
    int i = 0;
    int values[5] = {0, 0, 0, 0, 0};
    values[i++] = 10;
    values[i++] += 20;
    printf("%d %d %d\n", values[0], values[1], i);
    int x = 3;
    int post = x++;
    int pre = ++x;
    printf("%d %d %d\n", post, pre, x);
    struct Box box = {4, 5};
    box.width *= 3;
    box.height -= 2;
    printf("%d %d\n", box.width, box.height);
    int *pointer = values;
    pointer += 2;
    *pointer = 99;
    printf("%d %d\n", values[2], (int)(pointer - values));
    int comma = (1, 2, 3);
    printf("%d\n", comma);
    return 0;
}
