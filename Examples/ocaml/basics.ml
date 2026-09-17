(* OCaml の基本 *)

let rec fib n =
  if n < 2 then n
  else fib (n - 1) + fib (n - 2)

let square x = x * x

let rec sum lst =
  match lst with
  | [] -> 0
  | h :: t -> h + sum t

type shape =
  | Circle of float
  | Rect of float * float

let area s =
  match s with
  | Circle r -> 3.14159 *. r *. r
  | Rect (w, h) -> w *. h

let classify n =
  if n < 0 then "negative"
  else if n = 0 then "zero"
  else if n < 10 then "small"
  else "large"

let () =
  let fibs = List.map fib [0; 1; 2; 3; 4; 5; 6; 7; 8; 9] in
  print_endline ("fib: " ^ String.concat ", " (List.map string_of_int fibs));

  let nums = [5; 3; 9; 1; 7] in
  Printf.printf "sum: %d\n" (sum nums);
  Printf.printf "fold: %d\n" (List.fold_left (fun a b -> a + b) 0 nums);
  print_endline ("squares: " ^ String.concat ", "
                   (List.map string_of_int (List.map square nums)));
  print_endline ("big: " ^ String.concat ", "
                   (List.map string_of_int (List.filter (fun x -> x > 3) nums)));
  print_endline ("sorted: " ^ String.concat ", "
                   (List.map string_of_int (List.sort compare nums)));
  Printf.printf "length: %d\n" (List.length nums);

  Printf.printf "circle area: %.3f\n" (area (Circle 2.0));
  Printf.printf "rect area: %.3f\n" (area (Rect (3.0, 4.0)));

  List.iter (fun n -> Printf.printf "%d is %s\n" n (classify n)) [-5; 0; 3; 42];

  let point = (3, 4) in
  let (x, y) = point in
  Printf.printf "point: %d, %d\n" x y;

  let add a b = a + b in
  let add5 = add 5 in
  Printf.printf "curried: %d\n" (add5 10);

  let text = "Hello, OCaml" in
  Printf.printf "upper: %s\n" (String.uppercase_ascii text);
  Printf.printf "length: %d\n" (String.length text);
  Printf.printf "sub: %s\n" (String.sub text 0 5);

  Printf.printf "17 mod 5 = %d\n" (17 mod 5);
  Printf.printf "concat: %s\n" (String.concat "-" ["a"; "b"; "c"]);
  print_endline (match 7 with 1 -> "one" | 7 -> "seven" | _ -> "other")
