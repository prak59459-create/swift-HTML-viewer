# GitHub Viewer で「実行」を押すと、Pyodide (WebAssembly 版 CPython) が
# 端末の中で動きます。サーバーにコードは送られません。
import sys
import math

print("Python", sys.version.split()[0], "が iPad の中で動いています")

for n in range(1, 6):
    print(f"{n}! = {math.factorial(n)}")

primes = [n for n in range(2, 50) if all(n % d for d in range(2, int(n ** 0.5) + 1))]
print("50 未満の素数:", primes)
