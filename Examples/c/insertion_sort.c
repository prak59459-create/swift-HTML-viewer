#include <stdio.h>
#include <string.h>
struct Record { char key[8]; int value; };
int main(void) {
    struct Record records[5];
    int values[5] = {40, 10, 30, 50, 20};
    for (int i = 0; i < 5; i++) {
        records[i].value = values[i];
        records[i].key[0] = (char)('A' + i);
        records[i].key[1] = 0;
    }
    for (int i = 1; i < 5; i++) {
        struct Record current = records[i];
        int j = i - 1;
        while (j >= 0 && records[j].value > current.value) {
            records[j + 1] = records[j];
            j--;
        }
        records[j + 1] = current;
    }
    for (int i = 0; i < 5; i++) printf("%s=%d ", records[i].key, records[i].value);
    printf("\n");
    struct Record copy;
    memcpy(&copy, &records[0], sizeof(struct Record));
    printf("%s %d %d\n", copy.key, copy.value, (int)sizeof(struct Record));
    return 0;
}
