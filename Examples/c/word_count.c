#include <stdio.h>
#include <ctype.h>
#include <string.h>
struct Count { char word[16]; int times; };
int main(void) {
    char *text = "the cat and the hat and the bat";
    struct Count counts[8];
    int used = 0;
    char word[16];
    int length = 0;
    for (int i = 0; ; i++) {
        char c = text[i];
        if (isalpha((int)c)) {
            if (length < 15) word[length++] = (char)tolower((int)c);
            continue;
        }
        if (length > 0) {
            word[length] = 0;
            int index = -1;
            for (int j = 0; j < used; j++) if (strcmp(counts[j].word, word) == 0) index = j;
            if (index < 0) { index = used++; strcpy(counts[index].word, word); counts[index].times = 0; }
            counts[index].times++;
            length = 0;
        }
        if (c == 0) break;
    }
    for (int i = 0; i < used; i++) printf("%s=%d ", counts[i].word, counts[i].times);
    printf("\n%d\n", used);
    return 0;
}
