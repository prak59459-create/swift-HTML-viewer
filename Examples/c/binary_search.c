#include <stdio.h>
int search(int *values, int low, int high, int target) {
    if (low > high) return -1;
    int mid = (low + high) / 2;
    if (values[mid] == target) return mid;
    if (values[mid] < target) return search(values, mid + 1, high, target);
    return search(values, low, mid - 1, target);
}
int main(void) {
    int values[10];
    for (int i = 0; i < 10; i++) values[i] = i * i;
    for (int t = 0; t < 5; t++) printf("%d -> %d\n", t * t, search(values, 0, 9, t * t));
    printf("%d\n", search(values, 0, 9, 50));
    return 0;
}
