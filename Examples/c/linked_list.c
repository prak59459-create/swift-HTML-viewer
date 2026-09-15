#include <stdio.h>
#include <stdlib.h>
typedef struct Node Node;
struct Node { int value; Node *next; };
Node *push(Node *head, int value) {
    Node *node = (Node *)malloc(sizeof(Node));
    node->value = value;
    node->next = head;
    return node;
}
Node *reverse(Node *head) {
    Node *previous = 0;
    while (head != 0) {
        Node *next = head->next;
        head->next = previous;
        previous = head;
        head = next;
    }
    return previous;
}
int main(void) {
    Node *list = 0;
    for (int i = 1; i <= 5; i++) list = push(list, i);
    for (Node *c = list; c != 0; c = c->next) printf("%d", c->value);
    printf("\n");
    list = reverse(list);
    for (Node *c = list; c != 0; c = c->next) printf("%d", c->value);
    printf("\n");
    while (list != 0) { Node *next = list->next; free(list); list = next; }
    return 0;
}
