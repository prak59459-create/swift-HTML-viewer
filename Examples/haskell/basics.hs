-- Haskell の基本
module Main where

fib :: Int -> Int
fib 0 = 0
fib 1 = 1
fib n = fib (n - 1) + fib (n - 2)

square :: Int -> Int
square x = x * x

mySum :: [Int] -> Int
mySum [] = 0
mySum (x:xs) = x + mySum xs

classify :: Int -> String
classify n
  | n < 0 = "negative"
  | n == 0 = "zero"
  | n < 10 = "small"
  | otherwise = "large"

data Shape = Circle Double | Rect Double Double

area :: Shape -> Double
area s = case s of
  Circle r -> 3.14159 * r * r
  Rect w h -> w * h

describe :: Shape -> String
describe (Circle r) = "circle of radius " ++ show r
describe (Rect w h) = "rect " ++ show w ++ "x" ++ show h

applyTwice :: (Int -> Int) -> Int -> Int
applyTwice f x = f (f x)

main :: IO ()
main = do
  let fibs = map fib [0..9]
  putStrLn ("fib: " ++ show fibs)

  let nums = [5, 3, 9, 1, 7]
  putStrLn ("sum: " ++ show (mySum nums))
  putStrLn ("sum': " ++ show (sum nums))
  putStrLn ("squares: " ++ show (map square nums))
  putStrLn ("big: " ++ show (filter (> 3) nums))
  putStrLn ("sorted: " ++ show (sort nums))
  putStrLn ("reversed: " ++ show (reverse nums))
  putStrLn ("length: " ++ show (length nums))
  putStrLn ("folded: " ++ show (foldl (+) 0 nums))

  mapM_ (\n -> putStrLn (show n ++ " is " ++ classify n)) [-5, 0, 3, 42]

  putStrLn (describe (Circle 2.0))
  putStrLn (describe (Rect 3.0 4.0))
  putStrLn ("area: " ++ show (area (Circle 2.0)))

  let doubled = [x * 2 | x <- nums, x > 3]
  putStrLn ("comprehension: " ++ show doubled)

  putStrLn ("applyTwice: " ++ show (applyTwice square 3))
  putStrLn ("curried: " ++ show (map (+ 1) nums))

  let (a, b) = (3, 4)
  putStrLn ("tuple: " ++ show a ++ "," ++ show b)

  putStrLn ("upper: " ++ toUpper "hello haskell")
  putStrLn ("words: " ++ show (words "a b c"))
  putStrLn ("17 div 5 = " ++ show (div 17 5))
  putStrLn ("17 mod 5 = " ++ show (mod 17 5))
  putStrLn ("zip: " ++ show (zipWith (+) [1, 2, 3] [10, 20, 30]))
