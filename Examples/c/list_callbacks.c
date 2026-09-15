#include <stdio.h>
#include <stdlib.h>
typedef struct Node Node;
struct Node { int value; Node *next; };
typedef int (*Predicate)(int);
typedef int (*Transform)(int);
Node *prepend(Node *head, int value) {
    Node *node = (Node *)malloc(sizeof(Node));
    node->value = value;
    node->next = head;
    return node;
}
Node *mapList(Node *head, Transform transform) {
    if (head == NULL) return NULL;
    Node *rest = mapList(head->next, transform);
    Node *node = (Node *)malloc(sizeof(Node));
    node->value = transform(head->value);
    node->next = rest;
    return node;
}
int filterCount(Node *head, Predicate predicate) {
    int count = 0;
    for (Node *cursor = head; cursor != NULL; cursor = cursor->next)
        if (predicate(cursor->value)) count++;
    return count;
}
int isEven(int n) { return n % 2 == 0; }
int cube(int n) { return n * n * n; }
int main(void) {
    Node *list = NULL;
    for (int i = 5; i >= 1; i--) list = prepend(list, i);
    Node *cubes = mapList(list, cube);
    for (Node *c = cubes; c != NULL; c = c->next) printf("%d ", c->value);
    printf("\n%d %d\n", filterCount(list, isEven), filterCount(cubes, isEven));
    return 0;
}
