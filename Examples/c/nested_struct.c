#include <stdio.h>
struct Inner { int value; double weight; };
struct Outer { struct Inner items[3]; int count; };
int totalValue(struct Outer outer) {
    int sum = 0;
    for (int i = 0; i < outer.count; i++) sum += outer.items[i].value;
    outer.count = 0;
    return sum;
}
int main(void) {
    struct Outer outer;
    outer.count = 3;
    for (int i = 0; i < 3; i++) {
        outer.items[i].value = (i + 1) * 10;
        outer.items[i].weight = (i + 1) / 4.0;
    }
    printf("%d %d\n", totalValue(outer), outer.count);
    struct Inner *cursor = outer.items;
    for (int i = 0; i < 3; i++) printf("%d:%.2f ", cursor[i].value, cursor[i].weight);
    printf("\n%d\n", (int)sizeof(struct Outer));
    return 0;
}
