#include <stdio.h>
int table[6] = {1, 2, 3};
double ratios[3] = {0.5, 1.5, 2.5};
char greeting[16] = "hi";
struct Config { int width; int height; char label[8]; };
struct Config config = {640, 480, "vga"};
int counter;
int main(void) {
    printf("%d %d %d %d\n", table[0], table[2], table[5], counter);
    printf("%.1f %.1f\n", ratios[0], ratios[2]);
    printf("%s %d %d %s\n", greeting, config.width, config.height, config.label);
    counter = counter + 7;
    table[5] = counter * 2;
    printf("%d %d\n", counter, table[5]);
    return 0;
}
