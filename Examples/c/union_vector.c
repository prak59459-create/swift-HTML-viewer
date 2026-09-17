#include <stdio.h>
union Bits { unsigned int value; unsigned char bytes[4]; };
struct Vector { double x; double y; };
struct Vector scale(struct Vector v, double factor) {
    struct Vector result;
    result.x = v.x * factor;
    result.y = v.y * factor;
    return result;
}
struct Vector add(struct Vector a, struct Vector b) {
    struct Vector result;
    result.x = a.x + b.x;
    result.y = a.y + b.y;
    return result;
}
int main(void) {
    union Bits bits;
    bits.value = 0x01020304u;
    printf("%d %d %d %d %d\n", bits.bytes[0], bits.bytes[1], bits.bytes[2], bits.bytes[3],
           (int)sizeof(union Bits));
    struct Vector a;
    a.x = 1.5; a.y = -2.0;
    struct Vector b;
    b.x = 0.5; b.y = 4.0;
    struct Vector sum = add(a, b);
    struct Vector scaled = scale(sum, 3.0);
    printf("%.2f %.2f %.2f %.2f\n", sum.x, sum.y, scaled.x, scaled.y);
    printf("%.2f\n", add(scale(a, 2.0), scale(b, -1.0)).x);
    return 0;
}
