import java.util.*;

public class Main {
    static int fib(int n) {
        if (n < 2) return n;
        return fib(n - 1) + fib(n - 2);
    }

    public static void main(String[] args) {
        System.out.println("Hello, world!");
        int sum = 0;
        for (int i = 1; i <= 10; i++) sum += i;
        System.out.println("sum = " + sum);
        System.out.println(fib(15));

        int[] a = {5, 3, 9, 1, 7};
        Arrays.sort(a);
        System.out.println(Arrays.toString(a));

        List<String> names = new ArrayList<>();
        names.add("bob");
        names.add("alice");
        names.add("carol");
        Collections.sort(names);
        for (String n : names) System.out.println(n.toUpperCase());

        Map<String, Integer> counts = new HashMap<>();
        counts.put("x", 1);
        counts.put("y", 2);
        System.out.println(counts.get("x") + counts.get("y"));

        double d = 1.0 / 3.0;
        System.out.println(d);
        System.out.println(7 / 2);
        System.out.println(7 % 3);
        System.out.printf("%d %s %.2f%n", 42, "ok", 3.14159);

        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 3; i++) sb.append(i).append(",");
        System.out.println(sb.toString());

        String s = "Hello, World";
        System.out.println(s.substring(7));
        System.out.println(s.indexOf("World"));
        System.out.println(s.replace("l", "L"));
    }
}
