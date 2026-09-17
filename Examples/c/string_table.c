#include <stdio.h>
#include <string.h>
int main(void) {
    char *names[4] = {"alpha", "be", "gamma!", "d"};
    int longest = 0;
    for (int i = 0; i < 4; i++) {
        printf("%d:%s(%d) ", i, names[i], (int)strlen(names[i]));
        if (strlen(names[i]) > strlen(names[longest])) longest = i;
    }
    printf("\nlongest=%s\n", names[longest]);
    char **cursor = names;
    printf("%s %s\n", *cursor, *(cursor + 2));
    return 0;
}
