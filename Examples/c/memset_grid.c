#include <stdio.h>
#include <string.h>
int sumRegion(int *grid, int rows, int columns) {
    int total = 0;
    for (int r = 0; r < rows; r++)
        for (int c = 0; c < columns; c++) total += grid[r * columns + c];
    return total;
}
int main(void) {
    int grid[4][5];
    memset(grid, 0, sizeof(grid));
    for (int r = 0; r < 4; r++)
        for (int c = 0; c < 5; c++) grid[r][c] = r * 5 + c;
    printf("%d %d\n", sumRegion(&grid[0][0], 4, 5), grid[3][4]);
    int zeros[10];
    memset(zeros, 0, sizeof(zeros));
    int total = 0;
    for (int i = 0; i < 10; i++) total += zeros[i];
    printf("%d %d\n", total, (int)sizeof(grid));
    return 0;
}
