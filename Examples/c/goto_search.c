#include <stdio.h>
int findPair(int *values, int count, int target, int *first, int *second) {
    for (int i = 0; i < count; i++) {
        for (int j = i + 1; j < count; j++) {
            if (values[i] + values[j] == target) {
                *first = i;
                *second = j;
                goto found;
            }
        }
    }
    return 0;
found:
    return 1;
}
int main(void) {
    int values[6] = {2, 7, 11, 15, 1, 8};
    int a = -1, b = -1;
    int ok = findPair(values, 6, 9, &a, &b);
    printf("%d %d %d\n", ok, a, b);
    int i = 0;
    int total = 0;
loop:
    if (i >= 10) goto end;
    if (i % 3 == 0) { i++; goto loop; }
    total += i;
    i++;
    goto loop;
end:
    printf("%d\n", total);
    return 0;
}
