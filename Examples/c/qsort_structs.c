#include <stdio.h>
#include <stdlib.h>
#include <string.h>
struct Person { char name[12]; int age; };
int byAge(const void *a, const void *b) {
    const struct Person *left = (const struct Person *)a;
    const struct Person *right = (const struct Person *)b;
    return left->age - right->age;
}
int byName(const void *a, const void *b) {
    return strcmp(((const struct Person *)a)->name, ((const struct Person *)b)->name);
}
int compareInt(const void *a, const void *b) { return *(const int *)a - *(const int *)b; }
int main(void) {
    struct Person people[4];
    strcpy(people[0].name, "dana"); people[0].age = 31;
    strcpy(people[1].name, "alice"); people[1].age = 45;
    strcpy(people[2].name, "carol"); people[2].age = 22;
    strcpy(people[3].name, "bob"); people[3].age = 38;
    qsort(people, 4, sizeof(struct Person), byAge);
    for (int i = 0; i < 4; i++) printf("%s:%d ", people[i].name, people[i].age);
    printf("\n");
    qsort(people, 4, sizeof(struct Person), byName);
    for (int i = 0; i < 4; i++) printf("%s ", people[i].name);
    printf("\n");
    int numbers[7] = {9, 3, 7, 1, 8, 2, 5};
    qsort(numbers, 7, sizeof(int), compareInt);
    for (int i = 0; i < 7; i++) printf("%d", numbers[i]);
    int key = 7;
    int *found = (int *)bsearch(&key, numbers, 7, sizeof(int), compareInt);
    printf(" found=%d\n", found != NULL ? *found : -1);
    return 0;
}
