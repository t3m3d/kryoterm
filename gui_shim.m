// gui_shim.m — kryoterm GUI surface (TEMPORARY Obj-C shim).
//
// The kryoterm terminal ENGINE is pure Krypton: the macho backend's native
// pty/fd syscall builtins drive a real shell, and term.k renders an ANSI grid
// (cursor, erase, scroll, fg/bg colour, UTF-8 multi-byte). The ONE thing Krypton
// can't do yet is open a window and draw — `objc_msgSend`/AppKit FFI codegen
// isn't in macho_arm64_self.k. This shim fills exactly that gap and nothing
// more: it reads kryoterm's already-rendered output on stdin, parses just the
// SGR colour escapes term.k emits (positioning is already resolved), and paints
// it in a Cocoa NSTextView. Delete this file the day objc FFI lands.
//
// Build: ./build_gui.sh   Run: ./kryoterm | ./kryoterm-gui
//
// Pipeline:  Krypton (pty + grid engine)  --stdout-->  this shim --> window
//
// NOTE: phase 1 is display-only (one-directional). Keystroke input (window ->
// Krypton stdin -> shell) is phase 2.

#import <Cocoa/Cocoa.h>
#import <unistd.h>

static NSTextView *gTextView;

// SGR foreground code (30-37 / 90-97 / 39) -> NSColor. Terminal-ish palette.
static NSColor *fgColor(int code) {
    switch (code) {
        case 30: return [NSColor colorWithCalibratedRed:0.20 green:0.20 blue:0.20 alpha:1];
        case 31: return [NSColor colorWithCalibratedRed:0.91 green:0.30 blue:0.24 alpha:1];
        case 32: return [NSColor colorWithCalibratedRed:0.40 green:0.78 blue:0.31 alpha:1];
        case 33: return [NSColor colorWithCalibratedRed:0.90 green:0.76 blue:0.20 alpha:1];
        case 34: return [NSColor colorWithCalibratedRed:0.36 green:0.55 blue:0.95 alpha:1];
        case 35: return [NSColor colorWithCalibratedRed:0.78 green:0.40 blue:0.85 alpha:1];
        case 36: return [NSColor colorWithCalibratedRed:0.27 green:0.78 blue:0.78 alpha:1];
        case 37: return [NSColor colorWithCalibratedRed:0.85 green:0.85 blue:0.85 alpha:1];
        case 90: return [NSColor colorWithCalibratedRed:0.45 green:0.45 blue:0.45 alpha:1];
        case 91: return [NSColor colorWithCalibratedRed:1.00 green:0.45 blue:0.40 alpha:1];
        case 92: return [NSColor colorWithCalibratedRed:0.55 green:0.95 blue:0.45 alpha:1];
        case 93: return [NSColor colorWithCalibratedRed:1.00 green:0.90 blue:0.40 alpha:1];
        case 94: return [NSColor colorWithCalibratedRed:0.50 green:0.70 blue:1.00 alpha:1];
        case 95: return [NSColor colorWithCalibratedRed:0.90 green:0.55 blue:0.95 alpha:1];
        case 96: return [NSColor colorWithCalibratedRed:0.45 green:0.95 blue:0.95 alpha:1];
        case 97: return [NSColor colorWithCalibratedRed:1.00 green:1.00 blue:1.00 alpha:1];
        default: return [NSColor colorWithCalibratedRed:0.80 green:0.82 blue:0.78 alpha:1]; // 39 default
    }
}

// Append a colour-attributed run to the text view (on the main thread).
static void appendRun(NSString *text, int fg) {
    if (text.length == 0) return;
    NSColor *col = fgColor(fg);
    NSFont *font = [NSFont fontWithName:@"Menlo" size:13] ?: [NSFont userFixedPitchFontOfSize:13];
    NSDictionary *attrs = @{ NSForegroundColorAttributeName: col, NSFontAttributeName: font };
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    dispatch_async(dispatch_get_main_queue(), ^{
        [gTextView.textStorage appendAttributedString:as];
        [gTextView scrollRangeToVisible:NSMakeRange(gTextView.string.length, 0)];
    });
}

@interface Reader : NSObject
@end

@implementation Reader
// Read stdin forever, split on SGR escapes, push coloured runs to the view.
- (void)readLoop {
    int curFg = 39;
    NSMutableData *pending = [NSMutableData data];   // bytes of the current run
    unsigned char buf[4096];
    ssize_t got;
    while ((got = read(STDIN_FILENO, buf, sizeof(buf))) > 0) {
        for (ssize_t i = 0; i < got; i++) {
            unsigned char c = buf[i];
            if (c == 0x1b) {                          // ESC — flush run, parse CSI
                if (pending.length) {
                    NSString *s = [[NSString alloc] initWithData:pending encoding:NSUTF8StringEncoding];
                    if (s) appendRun(s, curFg);
                    [pending setLength:0];
                }
                // need '[' then params then a final letter; bytes may be split
                // across reads, but term.k emits whole escapes, so scan inline.
                if (i + 1 < got && buf[i+1] == '[') {
                    int code = 0; int haveCode = 0; int newFg = curFg; int sawReset = 0;
                    ssize_t j = i + 2;
                    while (j < got) {
                        unsigned char p = buf[j];
                        if (p >= '0' && p <= '9') { code = code*10 + (p - '0'); haveCode = 1; }
                        else if (p == ';' || (p >= 0x40 && p <= 0x7e)) {  // separator or final
                            if (haveCode || p == 'm') {
                                if (code == 0) { newFg = 39; sawReset = 1; }
                                else if (code == 39) newFg = 39;
                                else if ((code >= 30 && code <= 37) || (code >= 90 && code <= 97)) newFg = code;
                            }
                            code = 0; haveCode = 0;
                            if (p >= 0x40 && p <= 0x7e) {  // final byte ends the CSI
                                if (p == 'm') curFg = newFg; else (void)sawReset;
                                j++; break;
                            }
                        }
                        j++;
                    }
                    i = j - 1;  // for-loop ++ advances past the final byte
                } // else lone ESC — drop it
            } else {
                [pending appendBytes:&c length:1];
            }
        }
        // flush whatever's left as the current run
        if (pending.length) {
            NSString *s = [[NSString alloc] initWithData:pending encoding:NSUTF8StringEncoding];
            if (s) appendRun(s, curFg);
            [pending setLength:0];
        }
    }
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSRect frame = NSMakeRect(0, 0, 920, 560);
        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        [win setTitle:@"kryoterm — pure-Krypton terminal"];

        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:frame];
        [scroll setHasVerticalScroller:YES];
        [scroll setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

        gTextView = [[NSTextView alloc] initWithFrame:frame];
        [gTextView setEditable:NO];
        [gTextView setRichText:YES];
        [gTextView setBackgroundColor:[NSColor colorWithCalibratedRed:0.07 green:0.07 blue:0.08 alpha:1]];
        [gTextView setTextColor:[NSColor colorWithCalibratedRed:0.80 green:0.82 blue:0.78 alpha:1]];
        [gTextView setFont:([NSFont fontWithName:@"Menlo" size:13] ?: [NSFont userFixedPitchFontOfSize:13])];
        [scroll setDocumentView:gTextView];
        [win setContentView:scroll];
        [win center];
        [win makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        Reader *r = [[Reader alloc] init];
        [NSThread detachNewThreadSelector:@selector(readLoop) toTarget:r withObject:nil];

        [NSApp run];
    }
    return 0;
}
