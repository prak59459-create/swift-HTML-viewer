#include <stdio.h>
typedef struct { int row; int column; } Cell;
typedef struct { Cell cells[2][3]; int total; } Grid;
Grid buildGrid(void) {
    Grid grid;
    grid.total = 0;
    for (int r = 0; r < 2; r++)
        for (int c = 0; c < 3; c++) {
            grid.cells[r][c].row = r;
            grid.cells[r][c].column = c;
            grid.total += r * 3 + c;
        }
    return grid;
}
int main(void) {
    Grid grid = buildGrid();
    for (int r = 0; r < 2; r++)
        for (int c = 0; c < 3; c++) printf("%d%d ", grid.cells[r][c].row, grid.cells[r][c].column);
    printf("\n%d %d %d\n", grid.total, (int)sizeof(Cell), (int)sizeof(Grid));
    printf("%d\n", buildGrid().cells[1][2].column);
    return 0;
}
