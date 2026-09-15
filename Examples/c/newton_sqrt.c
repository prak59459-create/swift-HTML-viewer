#include <stdio.h>
#include <math.h>
double mySqrt(double value) {
    double guess = value / 2.0;
    for (int i = 0; i < 40; i++) guess = (guess + value / guess) / 2.0;
    return guess;
}
int main(void) {
    for (int i = 1; i <= 5; i++) printf("%.6f %.6f\n", mySqrt(i), sqrt((double)i));
    printf("%.4f %.4f %.4f\n", pow(1.05, 10.0), log(100.0), exp(1.0));
    return 0;
}
