#include <stdio.h>
#include <stdlib.h>
int main(void) {
    int rows = 3, columns = 4;
    int **grid = (int **)malloc(sizeof(int *) * rows);
    for (int i = 0; i < rows; i++) {
        grid[i] = (int *)malloc(sizeof(int) * columns);
        for (int j = 0; j < columns; j++) grid[i][j] = i * columns + j;
    }
    int sum = 0;
    for (int i = 0; i < rows; i++)
        for (int j = 0; j < columns; j++) sum += grid[i][j];
    printf("%d %d %d\n", sum, grid[2][3], **grid);
    for (int i = 0; i < rows; i++) free(grid[i]);
    free(grid);
    int *fresh = (int *)malloc(sizeof(int) * 4);
    for (int i = 0; i < 4; i++) fresh[i] = i;
    printf("%d %d\n", fresh[0], fresh[3]);
    free(fresh);
    return 0;
}
