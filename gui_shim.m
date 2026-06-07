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
static int   gCurRow = 0, gCurCol = 0;   // cursor cell (from each frame's header)
static BOOL  gCursorOn = YES;            // blink phase
static NSFont *gFont;
static CGFloat gCharW = 7.8, gLineH = 15.5;
static const CGFloat kPadX = 6, kPadY = 4;   // text origin inside the view

// Debug log (an agent can't see the window; this is how we diagnose). Tail it:
//   tail -f /tmp/kryoterm-gui.log
static void glog(const char *fmt, ...) {
    static FILE *f = NULL;
    if (!f) f = fopen("/tmp/kryoterm-gui.log", "w");
    if (!f) return;
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f); fflush(f);
}

// ---- theme / config -------------------------------------------------------
// ~/.config/kryoterm/config sets the titlebar + text-area colours, with a
// light-mode and a dark-mode value each (the window follows the system
// appearance live). Auto-created with defaults on first run.
static NSColor *gTbLight, *gTbDark, *gBgLight, *gBgDark, *gCurBg;
static NSWindow *gWin;

static NSColor *hexColor(const char *h, NSColor *fallback) {
    while (*h == '#' || *h == ' ' || *h == '\t') h++;
    unsigned int r = 0, g = 0, b = 0;
    if (sscanf(h, "%2x%2x%2x", &r, &g, &b) != 3) return fallback;
    return [NSColor colorWithCalibratedRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1];
}

static BOOL systemIsDark(void) {
    NSString *s = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleInterfaceStyle"];
    return s && [s caseInsensitiveCompare:@"Dark"] == NSOrderedSame;
}

static void loadConfig(void) {
    gTbLight = hexColor("#2b2b2b", nil);  gTbDark = hexColor("#000000", nil);
    gBgLight = hexColor("#2b2b2b", nil);  gBgDark = hexColor("#000000", nil);
    NSString *dir  = [NSHomeDirectory() stringByAppendingPathComponent:@".config/kryoterm"];
    NSString *path = [dir stringByAppendingPathComponent:@"config"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *def =
          @"# kryoterm config — colours as #RRGGBB.\n"
           "# Titlebar and text area, with a light-mode and dark-mode value each;\n"
           "# the window switches automatically with the system appearance.\n"
           "titlebar_light   = #2b2b2b\n"
           "titlebar_dark    = #000000\n"
           "background_light = #2b2b2b\n"
           "background_dark  = #000000\n";
        [def writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    for (NSString *raw in [txt componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSColor *c = hexColor([[line substringFromIndex:eq.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].UTF8String, nil);
        if (!c) continue;
        if      ([k isEqualToString:@"titlebar_light"])   gTbLight = c;
        else if ([k isEqualToString:@"titlebar_dark"])    gTbDark  = c;
        else if ([k isEqualToString:@"background_light"]) gBgLight = c;
        else if ([k isEqualToString:@"background_dark"])  gBgDark  = c;
    }
}

// xterm256(n) — the xterm 256-colour palette index -> NSColor. term.k re-emits
// every colour as 38;5;N / 48;5;N, mapping basic codes to indices 0-15.
static NSColor *xterm256(int n) {
    static const unsigned char base[16][3] = {
        {0,0,0},{205,49,49},{13,188,121},{229,229,16},{36,114,200},{188,63,188},{17,168,205},{204,204,204},
        {102,102,102},{241,76,76},{35,209,139},{245,245,67},{59,142,234},{214,112,214},{41,184,219},{255,255,255}
    };
    if (n < 0) n = 7;
    if (n < 16)
        return [NSColor colorWithCalibratedRed:base[n][0]/255.0 green:base[n][1]/255.0 blue:base[n][2]/255.0 alpha:1];
    if (n < 232) {
        int m = n - 16, lv[6] = {0,95,135,175,215,255};
        return [NSColor colorWithCalibratedRed:lv[m/36]/255.0 green:lv[(m/6)%6]/255.0 blue:lv[m%6]/255.0 alpha:1];
    }
    int v = 8 + (n - 232) * 10;
    return [NSColor colorWithCalibratedRed:v/255.0 green:v/255.0 blue:v/255.0 alpha:1];
}
static NSColor *defaultFg(void) { return [NSColor colorWithCalibratedRed:0.82 green:0.84 blue:0.80 alpha:1]; }

// append a run with fg + (optional) bg colour. fg/bg = -1 default, else palette index.
static void appendRun(NSMutableAttributedString *out, const unsigned char *b,
                      NSUInteger start, NSUInteger len, int fg, int bg, NSFont *font) {
    if (len == 0) return;
    NSString *s = [[NSString alloc] initWithBytes:b+start length:len encoding:NSUTF8StringEncoding];
    if (!s) return;
    NSMutableDictionary *attrs = [@{ NSForegroundColorAttributeName: (fg < 0 ? defaultFg() : xterm256(fg)),
                                     NSFontAttributeName: font } mutableCopy];
    if (bg >= 0) attrs[NSBackgroundColorAttributeName] = xterm256(bg);
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:s attributes:attrs]];
}

// Parse one frame's text (plain text + SGR escapes) into a coloured attributed
// string. term.k already resolved cursor/erase, so only `ESC[..m` appears.
static NSAttributedString *parseFrame(NSData *data) {
    NSFont *font = gFont;
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    const unsigned char *b = data.bytes;
    NSUInteger n = data.length, i = 0, runStart = 0;
    int curFg = -1, curBg = -1;          // -1 = default; else palette index 0-255
    while (i < n) {
        if (b[i] == 0x1b && i + 1 < n && b[i+1] == '[') {
            appendRun(out, b, runStart, i - runStart, curFg, curBg, font);
            NSUInteger j = i + 2; int code = 0, have = 0, newFg = curFg, newBg = curBg, stage = 0;
            while (j < n) {
                unsigned char p = b[j];
                if (p >= '0' && p <= '9') { code = code*10 + (p - '0'); have = 1; }
                else if (p == ';' || (p >= 0x40 && p <= 0x7e)) {
                    if (have || p == 'm') {
                        if (stage == 2) { newFg = code; stage = 0; }       // 38;5;N
                        else if (stage == 4) { newBg = code; stage = 0; }  // 48;5;N
                        else if (stage == 1) { stage = (code == 5) ? 2 : 0; }
                        else if (stage == 3) { stage = (code == 5) ? 4 : 0; }
                        else if (code == 0) { newFg = -1; newBg = -1; }
                        else if (code == 38) stage = 1;
                        else if (code == 48) stage = 3;
                        else if (code == 39) newFg = -1;
                        else if (code == 49) newBg = -1;
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
    [(gCurBg ?: [NSColor blackColor]) set];
    NSRectFill(self.bounds);
    if (self.attr) [self.attr drawAtPoint:NSMakePoint(kPadX, kPadY)];
    // thin vertical-bar cursor at the shell's cursor cell (focused + blink-on)
    if (self.window.isKeyWindow && gCursorOn) {
        [[NSColor colorWithCalibratedRed:0.85 green:0.87 blue:0.83 alpha:0.95] set];
        NSRectFill(NSMakeRect(kPadX + gCurCol * gCharW, kPadY + gCurRow * gLineH, 2.0, gLineH));
    }
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

// Pick titlebar + text-area colours for the current system appearance and apply.
static void applyColors(void) {
    BOOL dark = systemIsDark();
    gCurBg = dark ? gBgDark : gBgLight;
    if (gWin) gWin.backgroundColor = (dark ? gTbDark : gTbLight);
    if (gView) [gView setNeedsDisplay:YES];
}

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
                dispatch_async(dispatch_get_main_queue(), ^{
                    // Strip the SOH-delimited cursor header (SOH "row,col" SOH ...).
                    NSData *body = snapshot;
                    const unsigned char *p = snapshot.bytes;
                    NSUInteger len = snapshot.length;
                    if (len > 0 && p[0] == 1) {
                        NSUInteger k = 1;
                        while (k < len && p[k] != 1) k++;
                        if (k < len) {
                            int cr = 0, cc = 0, sawComma = 0;
                            for (NSUInteger m = 1; m < k; m++) {
                                if (p[m] == ',') sawComma = 1;
                                else if (p[m] >= '0' && p[m] <= '9')
                                    { if (sawComma) cc = cc*10 + (p[m]-'0'); else cr = cr*10 + (p[m]-'0'); }
                            }
                            gCurRow = cr; gCurCol = cc;
                            body = [snapshot subdataWithRange:NSMakeRange(k+1, len-(k+1))];
                        }
                    }
                    gView.attr = parseFrame(body);
                    gCursorOn = YES;            // solid right after output/typing
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
        loadConfig();
        // A Nerd Font so powerline/git icon glyphs render; cache its cell metrics
        // for cursor placement (monospace advance + default line height).
        gFont = [NSFont fontWithName:@"JetBrainsMono Nerd Font Mono" size:13]
             ?: [NSFont fontWithName:@"Menlo" size:13]
             ?: [NSFont userFixedPitchFontOfSize:13];
        gCharW = gFont.maximumAdvancement.width;
        gLineH = [[NSLayoutManager new] defaultLineHeightForFont:gFont];

        NSRect frame = NSMakeRect(0, 0, 830, 500);   // ~104x30 at Menlo 13
        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered defer:NO];
        [win setTitle:@"kryoterm — pure-Krypton terminal"];
        gWin = win;
        // Dark-styled titlebar (light text, correct traffic lights) tinted by our
        // configured colour; the title bar takes the window background colour.
        win.titlebarAppearsTransparent = YES;
        win.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        applyColors();
        // Live-update when the user toggles light/dark mode.
        [[NSDistributedNotificationCenter defaultCenter]
            addObserverForName:@"AppleInterfaceThemeChangedNotification" object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *_n){ applyColors(); }];

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

        // Cursor blink (~530ms, classic terminal cadence).
        [NSTimer scheduledTimerWithTimeInterval:0.53 repeats:YES block:^(NSTimer *_t){
            gCursorOn = !gCursorOn;
            [gView setNeedsDisplay:YES];
        }];

        Reader *r = [[Reader alloc] init];
        [NSThread detachNewThreadSelector:@selector(readLoop) toTarget:r withObject:nil];

        [NSApp run];
        if (gChild > 0) kill(gChild, SIGTERM);
    }
    return 0;
}
