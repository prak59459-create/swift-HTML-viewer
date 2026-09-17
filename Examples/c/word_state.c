#include <stdio.h>
enum State { START, WORD, SPACE };
int main(void) {
    char *text = "  the quick  brown fox ";
    int words = 0, letters = 0;
    enum State state = START;
    for (int i = 0; text[i] != 0; i++) {
        char c = text[i];
        if (c == ' ') { state = SPACE; continue; }
        letters++;
        if (state != WORD) { words++; state = WORD; }
    }
    printf("%d %d\n", words, letters);
    switch (words) {
        case 0: printf("none\n"); break;
        case 4: printf("four\n"); break;
        default: printf("many\n");
    }
    return 0;
}
