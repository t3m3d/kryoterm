// gui_shim.m — kryoterm GUI surface (TEMPORARY Obj-C shim).
//
// The kryoterm terminal ENGINE is pure Krypton: the macho backend's native
// pty/fd syscall builtins drive a real shell, and term.k renders an ANSI grid
// (cursor, erase, scroll, fg/bg colour, UTF-8) — including the interactive
// bridge `kryoterm -i` (keystrokes in on stdin, framed grid out on stdout). The
// ONE thing Krypton can't do yet is open a window and draw + capture keys —
// objc_msgSend/AppKit FFI codegen isn't in macho_arm64_self.k. This shim fills
// exactly that gap: it spawns `kryoterm -i` on a pty, draws each form-feed-
// delimited frame (parsing the SGR colour term.k emits), and forwards key
// presses to the pty (→ Krypton stdin → the shell). Delete when objc FFI lands.
//
// Build: ./build_gui.sh        Run: ./gui.sh   (or ./kryoterm-gui ./kryoterm)
//
//   keyboard --> this shim --(pty)--> kryoterm -i --(pty)--> shell
//   window   <-- this shim <--frames-- kryoterm -i <--------- shell

#import <Cocoa/Cocoa.h>
#import <util.h>       // forkpty
#import <termios.h>
#import <unistd.h>
#import <signal.h>
#import <stdarg.h>

static int   gMaster = -1;   // pipe to kryoterm's stdin  (write keystrokes)
static int   gReadFd = -1;   // pipe from kryoterm's stdout (read frames)
static pid_t gChild  = -1;

// Debug log (an agent can't see the window; this is how we diagnose). Tail it:
//   tail -f /tmp/kryoterm-gui.log
static void glog(const char *fmt, ...) {
    static FILE *f = NULL;
    if (!f) f = fopen("/tmp/kryoterm-gui.log", "w");
    if (!f) return;
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f); fflush(f);
}

// SGR foreground code (30-37 / 90-97 / 39) -> NSColor.
static NSColor *fgColor(int code) {
    switch (code) {
        case 30: return [NSColor colorWithCalibratedRed:0.30 green:0.30 blue:0.30 alpha:1];
        case 31: return [NSColor colorWithCalibratedRed:0.91 green:0.30 blue:0.24 alpha:1];
        case 32: return [NSColor colorWithCalibratedRed:0.40 green:0.78 blue:0.31 alpha:1];
        case 33: return [NSColor colorWithCalibratedRed:0.90 green:0.76 blue:0.20 alpha:1];
        case 34: return [NSColor colorWithCalibratedRed:0.36 green:0.55 blue:0.95 alpha:1];
        case 35: return [NSColor colorWithCalibratedRed:0.78 green:0.40 blue:0.85 alpha:1];
        case 36: return [NSColor colorWithCalibratedRed:0.27 green:0.78 blue:0.78 alpha:1];
        case 37: return [NSColor colorWithCalibratedRed:0.85 green:0.85 blue:0.85 alpha:1];
        case 90: return [NSColor colorWithCalibratedRed:0.50 green:0.50 blue:0.50 alpha:1];
        case 91: return [NSColor colorWithCalibratedRed:1.00 green:0.45 blue:0.40 alpha:1];
        case 92: return [NSColor colorWithCalibratedRed:0.55 green:0.95 blue:0.45 alpha:1];
        case 93: return [NSColor colorWithCalibratedRed:1.00 green:0.90 blue:0.40 alpha:1];
        case 94: return [NSColor colorWithCalibratedRed:0.50 green:0.70 blue:1.00 alpha:1];
        case 95: return [NSColor colorWithCalibratedRed:0.90 green:0.55 blue:0.95 alpha:1];
        case 96: return [NSColor colorWithCalibratedRed:0.45 green:0.95 blue:0.95 alpha:1];
        case 97: return [NSColor colorWithCalibratedRed:1.00 green:1.00 blue:1.00 alpha:1];
        default: return [NSColor colorWithCalibratedRed:0.82 green:0.84 blue:0.80 alpha:1]; // 39 default
    }
}

// bgColor(code) — SGR background code (40-47 / 100-107) -> NSColor (nil = default).
static NSColor *bgColor(int code) {
    if ((code >= 40 && code <= 47) || (code >= 100 && code <= 107)) return fgColor(code - 10);
    return nil;
}

// append a run with fg + (optional) bg color.
static void appendRun(NSMutableAttributedString *out, const unsigned char *b,
                      NSUInteger start, NSUInteger len, int fg, int bg, NSFont *font) {
    if (len == 0) return;
    NSString *s = [[NSString alloc] initWithBytes:b+start length:len encoding:NSUTF8StringEncoding];
    if (!s) return;
    NSMutableDictionary *attrs = [@{ NSForegroundColorAttributeName: fgColor(fg),
                                     NSFontAttributeName: font } mutableCopy];
    NSColor *bc = bgColor(bg);
    if (bc) attrs[NSBackgroundColorAttributeName] = bc;
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:s attributes:attrs]];
}

// Parse one frame's text (plain text + SGR escapes) into a coloured attributed
// string. term.k already resolved cursor/erase, so only `ESC[..m` appears.
static NSAttributedString *parseFrame(NSData *data) {
    // A Nerd Font so powerline/git/powerlevel10k icon glyphs (private-use
    // codepoints) render instead of missing-glyph boxes. Falls back to Menlo.
    NSFont *font = [NSFont fontWithName:@"JetBrainsMono Nerd Font Mono" size:13]
                ?: [NSFont fontWithName:@"Menlo" size:13]
                ?: [NSFont userFixedPitchFontOfSize:13];
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    const unsigned char *b = data.bytes;
    NSUInteger n = data.length, i = 0, runStart = 0;
    int curFg = 39, curBg = 49;
    while (i < n) {
        if (b[i] == 0x1b && i + 1 < n && b[i+1] == '[') {
            appendRun(out, b, runStart, i - runStart, curFg, curBg, font);
            NSUInteger j = i + 2; int code = 0, have = 0, newFg = curFg, newBg = curBg;
            while (j < n) {
                unsigned char p = b[j];
                if (p >= '0' && p <= '9') { code = code*10 + (p - '0'); have = 1; }
                else if (p == ';' || (p >= 0x40 && p <= 0x7e)) {
                    if (have || p == 'm') {
                        if (code == 0) { newFg = 39; newBg = 49; }
                        else if (code == 39) newFg = 39;
                        else if ((code>=30&&code<=37) || (code>=90&&code<=97)) newFg = code;
                        else if (code == 49) newBg = 49;
                        else if ((code>=40&&code<=47) || (code>=100&&code<=107)) newBg = code;
                    }
                    code = 0; have = 0;
                    if (p >= 0x40 && p <= 0x7e) { if (p == 'm') { curFg = newFg; curBg = newBg; } j++; break; }
                }
                j++;
            }
            i = j; runStart = i;
        } else i++;
    }
    if (1) {
        appendRun(out, b, runStart, i - runStart, curFg, curBg, font);
    }
    return out;
}

@interface KryptonView : NSView
@property (strong) NSAttributedString *attr;   // the latest frame
@end

@implementation KryptonView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return YES; }              // text origin at top-left
- (void)drawRect:(NSRect)dirty {
    [[NSColor colorWithCalibratedRed:0.07 green:0.07 blue:0.08 alpha:1] set];
    NSRectFill(self.bounds);
    if (self.attr) [self.attr drawAtPoint:NSMakePoint(6, 4)];
}
- (void)keyDown:(NSEvent *)e {
    if (gMaster < 0) return;
    // Special keys -> ANSI/VT sequences (arrows for history/completion, etc.).
    // NSEvent.characters returns private-use function-key codepoints for these,
    // which the shell can't use, so map by keyCode instead.
    const char *seq = NULL;
    switch (e.keyCode) {
        case 126: seq = "\x1b[A"; break;   // up    -> history prev
        case 125: seq = "\x1b[B"; break;   // down  -> history next
        case 124: seq = "\x1b[C"; break;   // right -> forward / accept autosuggest
        case 123: seq = "\x1b[D"; break;   // left
        case 115: seq = "\x1b[H"; break;   // home
        case 119: seq = "\x1b[F"; break;   // end
        case 116: seq = "\x1b[5~"; break;  // page up
        case 121: seq = "\x1b[6~"; break;  // page down
        case 117: seq = "\x1b[3~"; break;  // forward delete
    }
    if (seq) { write(gMaster, seq, strlen(seq)); return; }
    NSString *chars = e.characters;
    if (chars.length) {
        const char *bytes = [chars UTF8String];
        write(gMaster, bytes, strlen(bytes));
    }
}
@end

static KryptonView *gView;

@interface Reader : NSObject
@end
@implementation Reader
// Read kryoterm's stdout (pty master). Frames are form-feed (0x0c) delimited;
// on each \f, render the frame accumulated so far and replace the view.
- (void)readLoop {
    NSMutableData *frame = [NSMutableData data];
    unsigned char buf[8192];
    ssize_t got;
    int nframes = 0;
    while ((got = read(gReadFd, buf, sizeof(buf))) > 0) {
        for (ssize_t i = 0; i < got; i++) {
            if (buf[i] == 0x0c) {                       // form feed -> frame boundary
                NSData *snapshot = [frame copy];
                nframes++;
                glog("frame #%d (%lu bytes)", nframes, (unsigned long)snapshot.length);
                dispatch_async(dispatch_get_main_queue(), ^{
                    gView.attr = parseFrame(snapshot);
                    [gView setNeedsDisplay:YES];
                });
                [frame setLength:0];
            } else {
                [frame appendBytes:&buf[i] length:1];
            }
        }
    }
    // kryoterm exited -> close the app
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        const char *kpath = (argc > 1) ? argv[1] : "./kryoterm";

        // Spawn `kryoterm -i` over TWO pipes (not one shared pty): keys go down
        // inpipe to its stdin, frames come up outpipe from its stdout. Separate
        // open-file-descriptions = independent O_NONBLOCK — kryoterm can make its
        // stdin non-blocking without that flag bleeding onto stdout (which would
        // cause partial/EAGAIN writes that truncate frames). The shell still gets
        // a real pty from kryoterm itself; these are just byte conduits.
        int inpipe[2], outpipe[2];
        if (pipe(inpipe) || pipe(outpipe)) { perror("pipe"); return 1; }
        gChild = fork();
        if (gChild < 0) { perror("fork"); return 1; }
        if (gChild == 0) {
            dup2(inpipe[0], 0);
            dup2(outpipe[1], 1);
            dup2(outpipe[1], 2);
            close(inpipe[0]); close(inpipe[1]); close(outpipe[0]); close(outpipe[1]);
            execl(kpath, kpath, "-i", (char *)NULL);
            _exit(127);
        }
        close(inpipe[0]); close(outpipe[1]);
        gMaster = inpipe[1];        // write keystrokes here -> kryoterm stdin
        gReadFd = outpipe[0];       // read frames here <- kryoterm stdout

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSRect frame = NSMakeRect(0, 0, 830, 500);   // ~104x30 at Menlo 13
        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered defer:NO];
        [win setTitle:@"kryoterm — pure-Krypton terminal"];

        gView = [[KryptonView alloc] initWithFrame:frame];
        [gView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
        [win setContentView:gView];
        [win setInitialFirstResponder:gView];
        [win center];
        [win makeKeyAndOrderFront:nil];
        [win orderFrontRegardless];
        [NSApp activateIgnoringOtherApps:YES];
        glog("started: gMaster=%d child=%d isKey=%d frIsView=%d", gMaster, gChild,
             (int)[win isKeyWindow], (int)([win firstResponder] == gView));

        // Re-assert activation + key window AFTER the run loop is up — a bundle-
        // less CLI binary often can't take key focus until then.
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp activateIgnoringOtherApps:YES];
            [win makeKeyAndOrderFront:nil];
            [win makeFirstResponder:gView];
            glog("post-runloop: isKey=%d frIsView=%d", (int)[win isKeyWindow],
                 (int)([win firstResponder] == gView));
        });

        Reader *r = [[Reader alloc] init];
        [NSThread detachNewThreadSelector:@selector(readLoop) toTarget:r withObject:nil];

        [NSApp run];
        if (gChild > 0) kill(gChild, SIGTERM);
    }
    return 0;
}
