// make_icon.m — render the kryoterm app icon (dark squircle, green prompt
// chevron, light cursor). Usage: make_icon <out.png> [size]
//   clang -framework Cocoa make_icon.m -o make_icon && ./make_icon icon.png 1024
#import <Cocoa/Cocoa.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        const char *out = (argc > 1) ? argv[1] : "kryoterm_icon.png";
        CGFloat S = (argc > 2) ? atof(argv[2]) : 1024;

        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:S pixelsHigh:S
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:ctx];

        // rounded "squircle" panel
        CGFloat m = S * 0.085;
        NSRect r = NSMakeRect(m, m, S - 2*m, S - 2*m);
        CGFloat rad = (S - 2*m) * 0.225;
        NSBezierPath *panel = [NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad];
        NSGradient *g = [[NSGradient alloc]
            initWithStartingColor:[NSColor colorWithCalibratedRed:0.17 green:0.18 blue:0.21 alpha:1]
                      endingColor:[NSColor colorWithCalibratedRed:0.07 green:0.08 blue:0.10 alpha:1]];
        [g drawInBezierPath:panel angle:-90];
        [[NSColor colorWithCalibratedWhite:1 alpha:0.07] setStroke];
        panel.lineWidth = S * 0.004; [panel stroke];

        // prompt chevron ❯ (krypton green)
        CGFloat cx = S * 0.39, cy = S * 0.50, w = S * 0.125, h = S * 0.155;
        NSBezierPath *chev = [NSBezierPath bezierPath];
        [chev moveToPoint:NSMakePoint(cx - w, cy + h)];
        [chev lineToPoint:NSMakePoint(cx + w, cy)];
        [chev lineToPoint:NSMakePoint(cx - w, cy - h)];
        chev.lineWidth = S * 0.058;
        chev.lineCapStyle = NSLineCapStyleRound;
        chev.lineJoinStyle = NSLineJoinStyleRound;
        [[NSColor colorWithCalibratedRed:0.24 green:0.83 blue:0.55 alpha:1] setStroke];
        [chev stroke];

        // cursor block (light) to the right
        NSRect cur = NSMakeRect(cx + w * 1.7, cy - h, S * 0.095, h * 2);
        [[NSColor colorWithCalibratedWhite:0.93 alpha:0.95] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:cur xRadius:S*0.012 yRadius:S*0.012] fill];

        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToFile:[NSString stringWithUTF8String:out] atomically:YES];
        fprintf(stderr, "wrote %s (%dx%d)\n", out, (int)S, (int)S);
    }
    return 0;
}
