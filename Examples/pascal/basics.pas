program Demo;

type
  TColor = (Red, Green, Blue);
  TPoint = record
    X, Y: Integer;
  end;

var
  I, Total: Integer;
  Values: array[1..5] of Integer;
  P: TPoint;
  C: TColor;
  S: string;

function Fib(N: Integer): Integer;
begin
  if N < 2 then
    Fib := N
  else
    Fib := Fib(N - 1) + Fib(N - 2);
end;

function Describe(Color: TColor): string;
begin
  case Color of
    Red: Describe := 'red';
    Green: Describe := 'green';
  else
    Describe := 'blue';
  end;
end;

procedure Swap(var A, B: Integer);
var
  T: Integer;
begin
  T := A;
  A := B;
  B := T;
end;

begin
  Write('fib:');
  for I := 0 to 9 do
    Write(' ', Fib(I));
  WriteLn;

  Total := 0;
  for I := 1 to 10 do
    Total := Total + I;
  WriteLn('total = ', Total);

  I := 3;
  Total := 8;
  Swap(I, Total);
  WriteLn('swapped: ', I, ' ', Total);

  P.X := 3;
  P.Y := 4;
  WriteLn('point = (', P.X, ', ', P.Y, ')');

  C := Green;
  WriteLn('color = ', Describe(C));

  S := 'Hello, Pascal';
  WriteLn('upper = ', UpperCase(S));
  WriteLn('length = ', Length(S));
  WriteLn('copy = ', Copy(S, 1, 5));
  WriteLn('pos = ', Pos('Pascal', S));

  I := 0;
  while I < 3 do
  begin
    WriteLn('i = ', I);
    I := I + 1;
  end;

  I := 0;
  repeat
    I := I + 1;
  until I >= 3;
  WriteLn('repeat -> ', I);

  WriteLn('17 div 5 = ', 17 div 5);
  WriteLn('17 mod 5 = ', 17 mod 5);
  WriteLn('avg = ', 17 / 5 : 0 : 3);

  try
    I := StrToInt('abc');
  except
    WriteLn('caught a conversion error');
  end;
end.
