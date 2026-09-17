#include <iostream>
#include <vector>
#include <string>
#include <map>
#include <algorithm>
using namespace std;

struct Point {
    int x;
    int y;
};

class Counter {
private:
    int value;
public:
    Counter(int start) { value = start; }
    void increment() { value++; }
    int get() const { return value; }
};

int fib(int n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

int main() {
    cout << "Hello, C++!" << endl;

    int sum = 0;
    for (int i = 1; i <= 10; i++) sum += i;
    cout << "sum = " << sum << endl;
    cout << fib(15) << endl;

    vector<int> v;
    for (int i = 5; i > 0; i--) v.push_back(i * i);
    sort(v.begin(), v.end());
    for (int x : v) cout << x << " ";
    cout << endl;

    string s = "hello world";
    cout << s.size() << " " << s.substr(6) << endl;

    map<string, int> counts;
    counts["a"] = 1;
    counts["b"] = 2;
    cout << counts["a"] + counts["b"] << endl;

    Counter c(10);
    c.increment();
    c.increment();
    cout << c.get() << endl;

    double d = 1.0 / 3.0;
    cout << d << endl;
    cout << 7 / 2 << " " << 7 % 3 << endl;

    int arr[5] = {3, 1, 4, 1, 5};
    int total = 0;
    for (int i = 0; i < 5; i++) total += arr[i];
    cout << total << endl;

    auto square = [](int n) { return n * n; };
    cout << square(7) << endl;

    printf("%d %s %.2f\n", 42, "ok", 3.14159);
    return 0;
}
