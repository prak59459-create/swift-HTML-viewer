import java.util.*;

interface Shape {
    double area();
    default String describe() { return "shape with area " + area(); }
}

abstract class Base implements Shape {
    protected String name;
    Base(String name) { this.name = name; }
    public String getName() { return name; }
    @Override
    public String toString() { return name + "(" + area() + ")"; }
}

class Circle extends Base {
    private double r;
    Circle(double r) { super("circle"); this.r = r; }
    public double area() { return 3.14159 * r * r; }
}

class Rect extends Base {
    private double w, h;
    Rect(double w, double h) { super("rect"); this.w = w; this.h = h; }
    public double area() { return w * h; }
}

enum Color { RED, GREEN, BLUE }

public class T2 {
    static int counter = 0;

    static int divide(int a, int b) {
        try {
            return a / b;
        } catch (ArithmeticException e) {
            System.out.println("caught: division");
            return -1;
        } finally {
            counter++;
        }
    }

    static <T> void show(List<T> items) {
        for (T item : items) System.out.println("- " + item);
    }

    public static void main(String[] args) {
        List<Shape> shapes = new ArrayList<>();
        shapes.add(new Circle(2.0));
        shapes.add(new Rect(3.0, 4.0));
        for (Shape s : shapes) {
            System.out.println(s + " -> " + s.describe());
        }

        System.out.println(divide(10, 2));
        System.out.println(divide(10, 0));
        System.out.println("counter=" + counter);

        for (Color c : new Color[]{Color.RED, Color.GREEN, Color.BLUE}) {
            switch (c) {
                case RED: System.out.println("warm"); break;
                case GREEN: System.out.println("nature"); break;
                default: System.out.println("cool");
            }
        }

        int[][] grid = new int[3][];
        for (int i = 0; i < 3; i++) {
            grid[i] = new int[3];
            for (int j = 0; j < 3; j++) grid[i][j] = i * 3 + j;
        }
        for (int[] row : grid) System.out.println(Arrays.toString(row));

        List<String> words = new ArrayList<>(Arrays.asList("pear", "apple", "fig"));
        words.sort((a, b) -> a.length() - b.length());
        show(words);

        Map<String, List<Integer>> groups = new HashMap<>();
        int[] nums = {1, 2, 3, 4, 5, 6};
        for (int n : nums) {
            String key = n % 2 == 0 ? "even" : "odd";
            groups.computeIfAbsent(key, k -> new ArrayList<>()).add(n);
        }
        System.out.println(groups.get("even"));
        System.out.println(groups.get("odd"));

        String text = "the quick brown fox";
        String[] parts = text.split(" ");
        StringBuilder sb = new StringBuilder();
        for (int i = parts.length - 1; i >= 0; i--) {
            sb.append(parts[i]);
            if (i > 0) sb.append(" ");
        }
        System.out.println(sb);

        long big = 1L;
        for (int i = 1; i <= 20; i++) big *= i;
        System.out.println(big);

        System.out.println(Integer.MAX_VALUE);
        System.out.println(String.format("%5d|%-5s|%08.3f", 42, "hi", 3.5));
        System.out.println(Math.max(3, 7) + Math.abs(-2));
    }
}
