#include <stdio.h>
int main(void) {
    int counts[4] = {0, 0, 0, 0};
    int c;
    while ((c = getchar()) != -1) {
        if (c >= '0' && c <= '9') counts[0]++;
        else if (c == ' ' || c == '\n') counts[1]++;
        else if (c >= 'a' && c <= 'z') counts[2]++;
        else counts[3]++;
    }
    printf("%d %d %d %d\n", counts[0], counts[1], counts[2], counts[3]);
    return 0;
}
