/*
 * C はブラウザ内で動かせないので、設定で「サーバー実行」を許可すると
 * 実行サービス (Wandbox / 自前の Piston) に送ってコンパイルします。
 */
#include <stdio.h>

int main(void) {
    printf("hello from C\n");
    for (int i = 1; i <= 5; i++) {
        printf("%d の 2 乗は %d\n", i, i * i);
    }
    return 0;
}
