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
static int   gCols = 104, gRows = 30;    // current grid size (set on resize)
static int   gScrollOff = 0, gScrollMax = 0;   // scrollback view position
static int   gMatchRow = -1, gMatchCol = 0, gMatchLen = 0;   // find highlight (view-relative)
static int   gMatchNum = 0, gMatchTotal = 0;                 // "N of M" matches
static NSTextField *gSearchField;        // ⌘F search bar
static NSTextField *gSearchCount;        // "N/M" match counter
static NSString *gExecPath, *gKPath;     // for ⌘N (re-launch self)
static int   gSelAR = 0, gSelAC = 0, gSelER = 0, gSelEC = 0;   // selection anchor/end
static BOOL  gHasSel = NO;
static NSFont *gFont;
static CGFloat gCharW = 7.8, gLineH = 15.5;
static CGFloat kPadX = 6, kPadY = 4;     // text origin inside the view (configurable)

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
static int gBlinkMs = 530;               // cursor blink half-period; 0 = steady
static NSTimer *gBlink;
static NSColor *gCursorColor;            // cursor colour
static int gCursorStyle = 0;             // 0 bar | 1 block | 2 underline
static NSString *gFontName = @"JetBrainsMono Nerd Font Mono";
static CGFloat gFontSize = 13;
static CGFloat gOpacity = 1.0;           // window background opacity (text stays opaque)
static BOOL gCopyOnSelect = NO;          // auto-copy a selection on mouse-up
static int gScrollbackLines = 2000;      // scrollback history cap

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
    gCursorColor = hexColor("#d8dad4", nil);  gCursorStyle = 0;
    gFontName = @"JetBrainsMono Nerd Font Mono";  gFontSize = 13;  gOpacity = 1.0;
    kPadX = 6;  kPadY = 4;  gCopyOnSelect = NO;  gScrollbackLines = 2000;
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
           "background_dark  = #000000\n"
           "\n"
           "# Cursor blink half-period in milliseconds (0 = steady, no blink).\n"
           "cursor_blink_ms  = 530\n"
           "cursor_color     = #d8dad4\n"
           "cursor_style     = bar          # bar | block | underline\n"
           "\n"
           "# Font (a Nerd Font keeps the powerline/icon glyphs).\n"
           "font_family      = JetBrainsMono Nerd Font Mono\n"
           "font_size        = 13\n"
           "\n"
           "# Window background opacity (0.2-1.0; text stays opaque).\n"
           "opacity          = 1.0\n"
           "padding          = 6\n"
           "copy_on_select   = false        # auto-copy selection; middle-click pastes\n"
           "scrollback_lines = 2000\n";
        [def writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    for (NSString *raw in [txt componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *v = [[line substringFromIndex:eq.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([k isEqualToString:@"cursor_blink_ms"]) { gBlinkMs = atoi(v.UTF8String); continue; }
        if ([k isEqualToString:@"cursor_style"]) {
            gCursorStyle = [v hasPrefix:@"block"] ? 1 : ([v hasPrefix:@"under"] ? 2 : 0);
            continue;
        }
        if ([k isEqualToString:@"font_family"]) { if (v.length) gFontName = v; continue; }
        if ([k isEqualToString:@"font_size"])   { CGFloat fs = atof(v.UTF8String); if (fs >= 6) gFontSize = fs; continue; }
        if ([k isEqualToString:@"opacity"])     { CGFloat o = atof(v.UTF8String); if (o >= 0.2 && o <= 1.0) gOpacity = o; continue; }
        if ([k isEqualToString:@"padding"])     { CGFloat pd = atof(v.UTF8String); if (pd >= 0 && pd <= 40) { kPadX = pd; kPadY = pd; } continue; }
        if ([k isEqualToString:@"copy_on_select"]) { gCopyOnSelect = ([v hasPrefix:@"t"] || [v hasPrefix:@"1"] || [v hasPrefix:@"y"]); continue; }
        if ([k isEqualToString:@"scrollback_lines"]) { int n = atoi(v.UTF8String); if (n >= 100) gScrollbackLines = n; continue; }
        NSColor *c = hexColor(v.UTF8String, nil);
        if (!c) continue;
        if      ([k isEqualToString:@"cursor_color"])     gCursorColor = c;
        else if ([k isEqualToString:@"titlebar_light"])   gTbLight = c;
        else if ([k isEqualToString:@"titlebar_dark"])    gTbDark  = c;
        else if ([k isEqualToString:@"background_light"]) gBgLight = c;
        else if ([k isEqualToString:@"background_dark"])  gBgDark  = c;
    }
}

// Resolve the configured font and cache its monospace cell metrics.
static void applyFont(void) {
    gFont = [NSFont fontWithName:gFontName size:gFontSize]
         ?: [NSFont fontWithName:@"JetBrainsMono Nerd Font Mono" size:gFontSize]
         ?: [NSFont fontWithName:@"Menlo" size:gFontSize]
         ?: [NSFont userFixedPitchFontOfSize:gFontSize];
    gCharW = gFont.maximumAdvancement.width;
    gLineH = [[NSLayoutManager new] defaultLineHeightForFont:gFont];
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

// Tell kryoterm the grid size for a view's pixel size: RS "cols,rows" RS on the
// keystroke pipe. kryoterm rebuilds its grid + sets the pty size.
static void sendResize(NSView *v) {
    if (gMaster < 0 || gCharW < 1 || gLineH < 1) return;
    int cols = (int)((v.bounds.size.width  - 2 * kPadX) / gCharW);
    int rows = (int)((v.bounds.size.height - 2 * kPadY) / gLineH);
    if (cols < 4) cols = 4;
    if (rows < 2) rows = 2;
    gCols = cols; gRows = rows;
    char buf[64];
    int len = snprintf(buf, sizeof buf, "\036R,%d,%d\036", cols, rows);
    write(gMaster, buf, len);
}
static void sendScrollbackCap(void) {
    if (gMaster < 0) return;
    char buf[32]; int n = snprintf(buf, sizeof buf, "\036L,%d\036", gScrollbackLines);
    write(gMaster, buf, n);
}

@interface KryptonView : NSView <NSTextFieldDelegate>
@property (strong) NSAttributedString *attr;   // the latest frame
@end

@implementation KryptonView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return YES; }              // text origin at top-left
- (void)viewDidEndLiveResize { sendResize(self); }   // reflow grid when drag ends
- (void)scrollWheel:(NSEvent *)e {                   // wheel -> scrollback
    if (gMaster < 0 || gLineH < 1) return;
    static CGFloat acc = 0;
    acc += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * gLineH;
    int lines = (int)(acc / gLineH);
    if (lines == 0) return;
    acc -= lines * gLineH;
    char buf[32];
    if (lines > 0) snprintf(buf, sizeof buf, "\036U,%d\036", lines);    // up into history
    else           snprintf(buf, sizeof buf, "\036D,%d\036", -lines);   // back toward live
    write(gMaster, buf, strlen(buf));
}

// ---- find-in-scrollback ----
- (void)sendFind:(NSString *)cmd query:(NSString *)q {
    if (gMaster < 0) return;
    NSString *msg = [NSString stringWithFormat:@"\036%@,%@\036", cmd, q ?: @""];
    const char *b = [msg UTF8String]; write(gMaster, b, strlen(b));
}
- (void)openSearch {
    gSearchField.hidden = NO;
    gSearchField.stringValue = @"";
    gSearchCount.hidden = NO;
    gSearchCount.stringValue = @"";
    [self.window makeFirstResponder:gSearchField];
}
- (void)closeSearch {
    gSearchField.hidden = YES;
    gSearchCount.hidden = YES;
    if (gMaster >= 0) write(gMaster, "\036X,0\036", 5);
    [self.window makeFirstResponder:self];
}
- (void)newWindow {                                    // ⌘N — independent kryoterm
    if (!gExecPath) return;
    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:gExecPath];
    t.arguments = gKPath ? @[gKPath] : @[];
    [t launchAndReturnError:nil];
}
- (void)controlTextDidChange:(NSNotification *)n {
    [self sendFind:@"F" query:gSearchField.stringValue];   // live search, resets to newest match
}
- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(insertNewline:))   { [self sendFind:@"N" query:gSearchField.stringValue]; return YES; }  // next
    if (sel == @selector(cancelOperation:)) { [self closeSearch]; return YES; }                                    // Esc
    return NO;
}

// ---- mouse selection ----
- (void)pointToCell:(NSEvent *)e row:(int *)row col:(int *)col {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    int c = (int)((p.x - kPadX) / gCharW);
    int r = (int)((p.y - kPadY) / gLineH);
    if (c < 0) c = 0;  if (c > gCols) c = gCols;
    if (r < 0) r = 0;  if (r >= gRows) r = gRows - 1;
    *row = r; *col = c;
}
- (void)selectWordRow:(int)r col:(int)c {
    NSArray<NSString *> *lines = [self.attr.string componentsSeparatedByString:@"\n"];
    if (r >= (int)lines.count) { gHasSel = NO; return; }
    NSString *ln = lines[r]; int L = (int)ln.length;
    if (L == 0) { gHasSel = NO; return; }
    if (c >= L) c = L - 1;
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    int a = c, b = c;
    while (a > 0 && ![ws characterIsMember:[ln characterAtIndex:a-1]]) a--;
    while (b < L && ![ws characterIsMember:[ln characterAtIndex:b]]) b++;
    gSelAR = r; gSelAC = a; gSelER = r; gSelEC = b; gHasSel = (b > a);
}
- (void)selectLineRow:(int)r {
    NSArray<NSString *> *lines = [self.attr.string componentsSeparatedByString:@"\n"];
    int L = (r < (int)lines.count) ? (int)[lines[r] length] : 0;
    gSelAR = r; gSelAC = 0; gSelER = r; gSelEC = L; gHasSel = (L > 0);
}
- (void)openUrlAtRow:(int)r col:(int)c {
    NSArray<NSString *> *lines = [self.attr.string componentsSeparatedByString:@"\n"];
    if (r < 0 || r >= (int)lines.count) return;
    NSString *ln = lines[r]; int L = (int)ln.length;
    if (c >= L) return;
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    int a = c, b = c;
    while (a > 0 && ![ws characterIsMember:[ln characterAtIndex:a-1]]) a--;
    while (b < L && ![ws characterIsMember:[ln characterAtIndex:b]]) b++;
    NSString *tok = [ln substringWithRange:NSMakeRange(a, b-a)];
    NSCharacterSet *trail = [NSCharacterSet characterSetWithCharactersInString:@".,;:)]}>\"'"];
    while (tok.length && [trail characterIsMember:[tok characterAtIndex:tok.length-1]]) tok = [tok substringToIndex:tok.length-1];
    NSString *url = nil;
    if ([tok hasPrefix:@"http://"] || [tok hasPrefix:@"https://"] || [tok hasPrefix:@"file://"]) url = tok;
    else if ([tok hasPrefix:@"www."]) url = [@"https://" stringByAppendingString:tok];
    if (url) { NSURL *u = [NSURL URLWithString:url]; if (u) [[NSWorkspace sharedWorkspace] openURL:u]; }
}
- (void)mouseDown:(NSEvent *)e {
    int r, c; [self pointToCell:e row:&r col:&c];
    if (e.modifierFlags & NSEventModifierFlagCommand) { [self openUrlAtRow:r col:c]; return; }  // ⌘-click opens URLs
    if (e.modifierFlags & NSEventModifierFlagShift) {           // shift-click extends from the anchor
        gSelER = r; gSelEC = c; gHasSel = (gSelER != gSelAR || gSelEC != gSelAC);
        [self setNeedsDisplay:YES]; return;
    }
    if (e.clickCount == 2)      [self selectWordRow:r col:c];   // word
    else if (e.clickCount == 3) [self selectLineRow:r];         // line
    else { gSelAR = r; gSelAC = c; gSelER = r; gSelEC = c; gHasSel = NO; }
    [self setNeedsDisplay:YES];
}
- (void)mouseDragged:(NSEvent *)e {
    [self pointToCell:e row:&gSelER col:&gSelEC];
    gHasSel = (gSelER != gSelAR || gSelEC != gSelAC);
    [self setNeedsDisplay:YES];
}
- (void)mouseUp:(NSEvent *)e {
    if (gCopyOnSelect && gHasSel) [self copySelection];
}
- (void)otherMouseDown:(NSEvent *)e {       // middle-click pastes
    if (e.buttonNumber == 2) [self pasteClipboard];
}
- (NSString *)selectedText {
    if (!gHasSel || !self.attr) return nil;
    NSArray<NSString *> *lines = [self.attr.string componentsSeparatedByString:@"\n"];
    int r1 = gSelAR, c1 = gSelAC, r2 = gSelER, c2 = gSelEC;
    if (r2 < r1 || (r2 == r1 && c2 < c1)) { int tr=r1,tc=c1; r1=r2;c1=c2;r2=tr;c2=tc; }
    NSMutableString *out = [NSMutableString string];
    for (int r = r1; r <= r2 && r < (int)lines.count; r++) {
        NSString *ln = lines[r]; int L = (int)ln.length;
        int a = (r==r1)? c1 : 0, b = (r==r2)? c2 : L;
        if (a > L) a = L;  if (b > L) b = L;  if (b < a) b = a;
        [out appendString:[ln substringWithRange:NSMakeRange(a, b-a)]];
        if (r < r2) [out appendString:@"\n"];
    }
    return out;
}
- (void)copySelection {
    NSString *t = [self selectedText];
    if (t.length) {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:t forType:NSPasteboardTypeString];
    }
}
- (void)pasteClipboard {
    NSString *t = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
    if (t.length && gMaster >= 0) {
        const char *b = [t UTF8String];
        write(gMaster, "\033[200~", 6);    // bracketed paste: shell buffers, doesn't run each line
        write(gMaster, b, strlen(b));
        write(gMaster, "\033[201~", 6);
    }
}
- (void)drawRect:(NSRect)dirty {
    [[(gCurBg ?: [NSColor blackColor]) colorWithAlphaComponent:gOpacity] set];
    NSRectFill(self.bounds);
    if (self.attr) [self.attr drawAtPoint:NSMakePoint(kPadX, kPadY)];
    // cursor: filled (per style, blinks) when focused; hollow outline when not.
    if (gCurRow < gRows) {
        NSColor *cc = gCursorColor ?: [NSColor whiteColor];
        CGFloat x = kPadX + gCurCol * gCharW, y = kPadY + gCurRow * gLineH;
        if (!self.window.isKeyWindow) {                          // unfocused -> hollow cell
            [cc set];
            NSFrameRect(NSMakeRect(x, y, gCharW, gLineH));
        } else if (gCursorOn) {
            NSRect r;
            if (gCursorStyle == 1)      { r = NSMakeRect(x, y, gCharW, gLineH);            // block
                                          cc = [cc colorWithAlphaComponent:0.45]; }        // (glyph shows through)
            else if (gCursorStyle == 2) { r = NSMakeRect(x, y + gLineH - 2, gCharW, 2); }  // underline
            else                        { r = NSMakeRect(x, y, 2.0, gLineH); }             // bar
            [cc set];
            NSRectFill(r);
        }
    }
    // selection highlight (translucent overlay)
    if (gHasSel) {
        int r1=gSelAR,c1=gSelAC,r2=gSelER,c2=gSelEC;
        if (r2<r1 || (r2==r1 && c2<c1)) { int tr=r1,tc=c1; r1=r2;c1=c2;r2=tr;c2=tc; }
        [[NSColor colorWithCalibratedRed:0.30 green:0.48 blue:0.85 alpha:0.30] set];
        for (int r = r1; r <= r2; r++) {
            int a = (r==r1)? c1 : 0, b = (r==r2)? c2 : gCols;
            NSRectFill(NSMakeRect(kPadX + a*gCharW, kPadY + r*gLineH, (b-a)*gCharW, gLineH));
        }
    }
    // find: faint highlight on every visible occurrence (shim has the query + text)
    if (!gSearchField.hidden && gSearchField.stringValue.length && self.attr) {
        NSString *q = gSearchField.stringValue;
        NSArray<NSString *> *lines = [self.attr.string componentsSeparatedByString:@"\n"];
        [[NSColor colorWithCalibratedRed:0.96 green:0.80 blue:0.25 alpha:0.20] set];
        for (int r = 0; r < (int)lines.count && r < gRows; r++) {
            NSString *ln = lines[r];
            NSRange sr = NSMakeRange(0, ln.length);
            while (sr.length) {
                NSRange m = [ln rangeOfString:q options:0 range:sr];   // case-sensitive, matches the bridge
                if (m.location == NSNotFound) break;
                NSRectFill(NSMakeRect(kPadX + m.location*gCharW, kPadY + r*gLineH, m.length*gCharW, gLineH));
                NSUInteger nx = m.location + m.length;
                sr = NSMakeRange(nx, ln.length - nx);
            }
        }
    }
    // current match — bright (position from the bridge)
    if (gMatchRow >= 0 && gMatchLen > 0) {
        [[NSColor colorWithCalibratedRed:0.96 green:0.80 blue:0.25 alpha:0.55] set];
        NSRectFill(NSMakeRect(kPadX + gMatchCol*gCharW, kPadY + gMatchRow*gLineH, gMatchLen*gCharW, gLineH));
    }
    // scroll-position thumb on the right edge (only while viewing history)
    if (gScrollOff > 0 && gScrollMax > 0) {
        CGFloat H = self.bounds.size.height, total = gScrollMax + gRows;
        CGFloat thumbH = (gRows / total) * H;
        if (thumbH < 24) thumbH = 24;
        CGFloat y = ((CGFloat)(gScrollMax - gScrollOff) / total) * H;
        if (y + thumbH > H) y = H - thumbH;
        if (y < 0) y = 0;
        [[NSColor colorWithCalibratedRed:0.72 green:0.74 blue:0.70 alpha:0.5] set];
        NSRectFill(NSMakeRect(self.bounds.size.width - 5, y, 3, thumbH));
    }
}
- (void)keyDown:(NSEvent *)e {
    if (gMaster < 0) return;
    if (e.modifierFlags & NSEventModifierFlagCommand) {   // ⌘C copy / ⌘V paste
        NSString *ch = e.charactersIgnoringModifiers;
        if ([ch isEqualToString:@"c"]) { [self copySelection]; return; }
        if ([ch isEqualToString:@"v"]) { [self pasteClipboard]; return; }
        if ([ch isEqualToString:@"k"]) { write(gMaster, "\036C,0\036", 5); return; }  // clear
        if ([ch isEqualToString:@"f"]) { [self openSearch]; return; }                  // find
        if ([ch isEqualToString:@"n"]) { [self newWindow]; return; }                   // new window
        if ([ch isEqualToString:@"g"]) { write(gMaster, "\036N,\036", 4); return; }    // ⌘G  next match
        if ([ch isEqualToString:@"G"]) { write(gMaster, "\036P,\036", 4); return; }    // ⌘⇧G prev match
        if ([ch isEqualToString:@"="] || [ch isEqualToString:@"+"]) {                  // zoom in
            gFontSize += 1; applyFont(); sendResize(self); [self setNeedsDisplay:YES]; return;
        }
        if ([ch isEqualToString:@"-"]) {                                               // zoom out
            if (gFontSize > 7) gFontSize -= 1; applyFont(); sendResize(self); [self setNeedsDisplay:YES]; return;
        }
        if ([ch isEqualToString:@"0"]) {                                               // reset zoom
            loadConfig(); applyFont(); sendResize(self); [self setNeedsDisplay:YES]; return;
        }
        // scrollback nav: ⌘↑/⌘↓ page, ⌘Home/⌘End top/bottom
        int page = gRows > 2 ? gRows - 2 : 1;
        char nb[24];
        if (e.keyCode == 126) { snprintf(nb,sizeof nb,"\036U,%d\036",page);  write(gMaster,nb,strlen(nb)); return; }  // ⌘↑
        if (e.keyCode == 125) { snprintf(nb,sizeof nb,"\036D,%d\036",page);  write(gMaster,nb,strlen(nb)); return; }  // ⌘↓
        if (e.keyCode == 115) { write(gMaster, "\036U,99999\036", 9); return; }   // ⌘Home -> top of history
        if (e.keyCode == 119) { write(gMaster, "\036D,99999\036", 9); return; }   // ⌘End  -> back to live
    }
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
    if (gWin) {
        gWin.opaque = (gOpacity >= 0.999);
        gWin.backgroundColor = [(dark ? gTbDark : gTbLight) colorWithAlphaComponent:gOpacity];
    }
    if (gView) [gView setNeedsDisplay:YES];
}

// (Re)start the blink timer for the current gBlinkMs (0 = steady, no timer).
static void restartBlink(void) {
    [gBlink invalidate]; gBlink = nil;
    gCursorOn = YES;
    if (gBlinkMs > 0) {
        gBlink = [NSTimer scheduledTimerWithTimeInterval:gBlinkMs/1000.0 repeats:YES block:^(NSTimer *_t){
            gCursorOn = !gCursorOn;
            [gView setNeedsDisplay:YES];
        }];
    }
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
    while ((got = read(gReadFd, buf, sizeof(buf))) > 0) {
        for (ssize_t i = 0; i < got; i++) {
            if (buf[i] == 0x0c) {                       // form feed -> frame boundary
                NSData *snapshot = [frame copy];
                dispatch_async(dispatch_get_main_queue(), ^{
                    // Strip the SOH-delimited header: SOH "row,col,title" SOH ...
                    NSData *body = snapshot;
                    const unsigned char *p = snapshot.bytes;
                    NSUInteger len = snapshot.length;
                    if (len > 0 && p[0] == 1) {
                        NSUInteger k = 1;
                        while (k < len && p[k] != 1) k++;
                        if (k < len) {
                            // header = row,col,scrollOff,scrollMax,matchRow,matchCol,matchLen,matchNum,matchTotal,title
                            int fv[9] = {0,0,0,0,0,0,0,0,0}; int neg[9] = {0,0,0,0,0,0,0,0,0};
                            int field = 0; NSUInteger titleStart = 0;
                            for (NSUInteger m = 1; m < k; m++) {
                                if (p[m] == ',') { field++; if (field == 9) { titleStart = m+1; break; } }
                                else if (field < 9) {
                                    if (p[m] == '-') neg[field] = 1;
                                    else if (p[m] >= '0' && p[m] <= '9') fv[field] = fv[field]*10 + (p[m]-'0');
                                }
                            }
                            for (int q = 0; q < 9; q++) if (neg[q]) fv[q] = -fv[q];
                            gCurRow = fv[0]; gCurCol = fv[1]; gScrollOff = fv[2]; gScrollMax = fv[3];
                            gMatchRow = fv[4]; gMatchCol = fv[5]; gMatchLen = fv[6];
                            gMatchNum = fv[7]; gMatchTotal = fv[8];
                            if (!gSearchField.hidden)
                                gSearchCount.stringValue = gMatchTotal > 0
                                    ? [NSString stringWithFormat:@"%d/%d", gMatchNum, gMatchTotal] : @"0/0";
                            if (titleStart && titleStart < k) {
                                NSString *t = [[NSString alloc] initWithBytes:p+titleStart length:k-titleStart encoding:NSUTF8StringEncoding];
                                if (t.length) [gWin setTitle:t];
                            }
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

        // Identify as kryoterm (not the host terminal that launched us) — the
        // shell inherits this env, so kryofetch & co. report kryoterm. Also pin a
        // sane TERM (the host may set xterm-ghostty etc. with no local terminfo).
        setenv("TERM_PROGRAM", "kryoterm", 1);
        setenv("TERM_PROGRAM_VERSION", "1.0", 1);
        setenv("TERM", "xterm-256color", 1);

        // Absolute paths so ⌘N can re-launch another window.
        NSString *(^abspath)(const char *) = ^NSString *(const char *p) {
            NSString *s = [NSString stringWithUTF8String:p];
            return [s hasPrefix:@"/"] ? s : [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:s];
        };
        gExecPath = abspath(argv[0]);
        gKPath = abspath(kpath);

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
        applyFont();   // resolve the configured font + cache cell metrics

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

        // ⌘F search bar — top-right, hidden until opened, sticks to the corner.
        gSearchField = [[NSTextField alloc] initWithFrame:NSMakeRect(frame.size.width-230, 4, 220, 24)];
        gSearchField.delegate = gView;
        gSearchField.hidden = YES;
        gSearchField.bezeled = YES;
        gSearchField.font = [NSFont systemFontOfSize:12];
        [gSearchField.cell setPlaceholderString:@"find in scrollback…"];
        [gSearchField setAutoresizingMask:(NSViewMinXMargin | NSViewMaxYMargin)];
        [gView addSubview:gSearchField];

        gSearchCount = [[NSTextField alloc] initWithFrame:NSMakeRect(frame.size.width-230-62, 6, 56, 20)];
        gSearchCount.editable = NO; gSearchCount.bezeled = NO; gSearchCount.drawsBackground = NO;
        gSearchCount.hidden = YES;
        gSearchCount.alignment = NSTextAlignmentRight;
        gSearchCount.font = [NSFont systemFontOfSize:11];
        gSearchCount.textColor = [NSColor secondaryLabelColor];
        [gSearchCount setAutoresizingMask:(NSViewMinXMargin | NSViewMaxYMargin)];
        [gView addSubview:gSearchCount];
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
            sendResize(gView);   // sync kryoterm's grid to the actual window size
            sendScrollbackCap();
            glog("post-runloop: isKey=%d frIsView=%d", (int)[win isKeyWindow],
                 (int)([win firstResponder] == gView));
        });

        restartBlink();   // cursor blink from config (cursor_blink_ms; 0 = steady)

        // Hot-reload config whenever the window regains focus.
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowDidBecomeKeyNotification object:win
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *_n){
                        loadConfig(); applyFont(); applyColors(); restartBlink(); sendResize(gView); sendScrollbackCap();
                    }];

        Reader *r = [[Reader alloc] init];
        [NSThread detachNewThreadSelector:@selector(readLoop) toTarget:r withObject:nil];

        [NSApp run];
        if (gChild > 0) kill(gChild, SIGTERM);
    }
    return 0;
}
