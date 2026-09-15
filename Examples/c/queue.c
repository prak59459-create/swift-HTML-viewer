#include <stdio.h>
#include <stdlib.h>
struct Queue { int *data; int head; int tail; int capacity; };
void push(struct Queue *queue, int value) { queue->data[queue->tail++] = value; }
int pop(struct Queue *queue) { return queue->data[queue->head++]; }
int empty(struct Queue *queue) { return queue->head == queue->tail; }
int main(void) {
    struct Queue queue;
    queue.capacity = 16;
    queue.data = (int *)malloc(sizeof(int) * queue.capacity);
    queue.head = 0;
    queue.tail = 0;
    for (int i = 1; i <= 5; i++) push(&queue, i * 3);
    int sum = 0;
    while (!empty(&queue)) { int v = pop(&queue); sum += v; printf("%d ", v); }
    printf("| %d\n", sum);
    free(queue.data);
    return 0;
}
