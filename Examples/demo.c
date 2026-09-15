/*
 * このファイルは、アプリに内蔵した C コンパイラ (MiniC) が
 * その場でコンパイルして実行します。ネットワークは使いません。
 * ツールバーの「逆アセンブル」で、生成されたバイトコードも見られます。
 */
#include <stdio.h>

int main(void) {
    printf("hello from C\n");
    for (int i = 1; i <= 5; i++) {
        printf("%d の 2 乗は %d\n", i, i * i);
    }
    return 0;
}
