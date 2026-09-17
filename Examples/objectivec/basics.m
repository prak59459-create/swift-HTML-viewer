#import <Foundation/Foundation.h>

@interface Point : NSObject
{
    int x;
    int y;
}
- (id)initWithX:(int)ax y:(int)ay;
- (int)norm;
- (NSString *)describe;
@end

@implementation Point
- (id)initWithX:(int)ax y:(int)ay {
    x = ax;
    y = ay;
    return self;
}
- (int)norm {
    return x * x + y * y;
}
- (NSString *)describe {
    return [NSString stringWithFormat:@"Point(%d, %d)", x, y];
}
@end

int fib(int n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

int main(int argc, const char *argv[]) {
    NSLog(@"Hello, Objective-C!");

    int sum = 0;
    for (int i = 1; i <= 10; i++) sum += i;
    NSLog(@"sum = %d", sum);
    NSLog(@"%d", fib(15));

    NSMutableArray *xs = [NSMutableArray array];
    [xs addObject:@"pear"];
    [xs addObject:@"apple"];
    [xs addObject:@"fig"];
    NSLog(@"%d", (int)[xs count]);
    NSLog(@"%@", [xs objectAtIndex:1]);
    NSLog(@"%@", [xs componentsJoinedByString:@", "]);

    for (NSString *s in xs) {
        NSLog(@"- %@", [s uppercaseString]);
    }

    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    [m setObject:@1 forKey:@"a"];
    [m setObject:@2 forKey:@"b"];
    NSLog(@"%d", (int)[m count]);
    NSLog(@"%@", [m objectForKey:@"a"]);

    Point *p = [[Point alloc] initWithX:3 y:4];
    NSLog(@"%d", [p norm]);
    NSLog(@"%@", [p describe]);

    NSString *s = @"Hello, World";
    NSLog(@"%d", (int)[s length]);
    NSLog(@"%@", [s uppercaseString]);
    NSLog(@"%@", [s substringFromIndex:7]);

    printf("%d %s %.2f\n", 42, "ok", 3.14159);
    return 0;
}
