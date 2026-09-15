#include <stdio.h>
typedef struct { char name[8]; int score; double ratio; } Player;
int main(void) {
    Player players[4];
    int scores[4] = {70, 95, 60, 88};
    for (int i = 0; i < 4; i++) {
        players[i].score = scores[i];
        players[i].ratio = scores[i] / 100.0;
    }
    for (int i = 0; i < 4; i++)
        for (int j = i + 1; j < 4; j++)
            if (players[j].score > players[i].score) {
                Player temp = players[i];
                players[i] = players[j];
                players[j] = temp;
            }
    for (int i = 0; i < 4; i++) printf("%2d: %3d %.2f\n", i, players[i].score, players[i].ratio);
    return 0;
}
