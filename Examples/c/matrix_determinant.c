#include <stdio.h>
int main(void) {
    double m[3][3] = {{2.0, -1.0, 0.5}, {1.0, 3.0, -2.0}, {0.0, 4.0, 1.0}};
    double det = 0.0;
    for (int i = 0; i < 3; i++) {
        double positive = 1.0, negative = 1.0;
        for (int j = 0; j < 3; j++) {
            positive *= m[j][(i + j) % 3];
            negative *= m[j][(i - j + 3) % 3];
        }
        det += positive - negative;
    }
    printf("%.4f\n", det);
    double trace = 0;
    for (int i = 0; i < 3; i++) trace += m[i][i];
    printf("%.2f\n", trace);
    return 0;
}
