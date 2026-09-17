# R の基本
fib <- function(n) {
  if (n < 2) {
    return(n)
  }
  fib(n - 1) + fib(n - 2)
}

fibs <- sapply(0:9, fib)
cat("fib:", fibs, "\n")

x <- c(5, 3, 9, 1, 7)
cat("sum:", sum(x), "\n")
cat("mean:", mean(x), "\n")
cat("sorted:", sort(x), "\n")
cat("rev:", rev(x), "\n")
cat("length:", length(x), "\n")
cat("max/min:", max(x), min(x), "\n")

y <- x * 2
cat("doubled:", y, "\n")
cat("plus one:", x + 1, "\n")
cat("big:", x[x > 3], "\n")

squares <- sapply(1:5, function(v) v^2)
cat("squares:", squares, "\n")

total <- 0
for (i in 1:10) {
  total <- total + i
}
cat("total:", total, "\n")

i <- 0
while (i < 3) {
  cat("i =", i, "\n")
  i <- i + 1
}

greet <- function(name, greeting = "Hello") {
  paste0(greeting, ", ", name, "!")
}
cat(greet("World"), "\n")
cat(greet("R", greeting = "Hi"), "\n")

person <- list(name = "Alice", age = 30)
cat("name:", person$name, "age:", person$age, "\n")

s <- "Hello, R Language"
cat("upper:", toupper(s), "\n")
cat("nchar:", nchar(s), "\n")
cat("substr:", substr(s, 1, 5), "\n")

cat("17 %% 5 =", 17 %% 5, "\n")
cat("17 %/% 5 =", 17 %/% 5, "\n")
cat("3 %in% x:", 3 %in% x, "\n")

print(x)
print(sort(x))
