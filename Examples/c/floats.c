#include <stdio.h>
#include <math.h>
int main(void) {
    double values[5] = {-2.5, -0.5, 0.0, 0.5, 2.5};
    for (int i = 0; i < 5; i++)
        printf("%.1f %.1f %.1f %.1f\n", values[i], floor(values[i]), ceil(values[i]), fabs(values[i]));
    printf("%.4f %.4f\n", fmod(7.5, 2.0), fmod(-7.5, 2.0));
    double sum = 0;
    for (int i = 1; i <= 100; i++) sum += 1.0 / i;
    printf("%.6f\n", sum);
    printf("%d %d %d\n", 0.1 + 0.2 == 0.3, fabs(0.1 + 0.2 - 0.3) < 0.000001, (int)(2.999999));
    return 0;
}
