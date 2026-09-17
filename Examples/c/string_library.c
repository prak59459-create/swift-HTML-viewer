#include <stdio.h>
#include <string.h>
#include <stdlib.h>
int main(void) {
    char buffer[64];
    strcpy(buffer, "hello");
    strncat(buffer, ", world!!!", 7);
    printf("%s %d\n", buffer, (int)strlen(buffer));
    char *copy = strdup(buffer);
    printf("%s %d\n", copy, memcmp(copy, buffer, strlen(buffer)));
    free(copy);
    char haystack[32] = "the quick brown fox";
    char *found = strstr(haystack, "brown");
    printf("%s %d\n", found, (int)(found - haystack));
    char path[16] = "a/b/c";
    printf("%d %d\n", strstr(haystack, "zzz") == NULL, (int)(strrchr(path, '/') - path));
    printf("%ld %ld\n", strtol("1234abc", NULL, 10), strtol("ff", NULL, 16));
    printf("%.2f %d\n", strtod("3.25xyz", NULL), atoi("42abc"));
    return 0;
}
