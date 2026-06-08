// gui_shim.m — kryoterm GUI surface (TEMPORARY Obj-C shim), multi-pane edition.
//
// The kryoterm ENGINE is pure Krypton (term.k grid + `kryoterm -i` pty bridge,
// driven by macho syscall builtins). This shim is the ONE non-Krypton piece: it
// opens windows, draws the framed grid term.k emits, and forwards keys — the bit
// the macho backend can't do yet (no objc_msgSend FFI). Delete when that lands.
//
// Architecture: one process -> N windows (native macOS tabs share a
// tabbingIdentifier) -> each window is a tree of NSSplitView panes -> each pane
// (KryptonView) owns its own `kryoterm -i` engine on two pipes, its own reader
// thread, and its own per-pane state. AppKit's first-responder routes keys to the
// focused pane. Config + font + colours are process-shared.
//
// Build: ./build_gui.sh

#import <Cocoa/Cocoa.h>
#import <Contacts/Contacts.h>
#import <ContactsUI/ContactsUI.h>
#import <util.h>
#import <termios.h>
#import <unistd.h>
#import <signal.h>
#import <stdarg.h>

// ---- shared config / window-level state -----------------------------------
static NSColor *gTbLight, *gTbDark, *gBgLight, *gBgDark, *gCurBg;
static int gBlinkMs = 530; static NSTimer *gBlink; static BOOL gCursorOn = YES;
static NSColor *gCursorColor; static int gCursorStyle = 0;
static NSString *gFontName = @"JetBrainsMono Nerd Font Mono";
static CGFloat gFontSize = 13;
static NSFont *gFont;
static CGFloat gCharW = 7.8, gLineH = 15.5;
static CGFloat kPadX = 6, kPadY = 4;
static CGFloat gOpacity = 1.0;
static BOOL gCopyOnSelect = NO;
static int gScrollbackLines = 2000;
static CGFloat gLineSpacing = 0;
static int gBellMode = 1;
static NSString *gExecPath, *gKPath;
static NSMutableArray *gPanes;     // all live KryptonView panes (blink + cleanup)

static void glog(const char *fmt, ...) {
    static FILE *f = NULL;
    if (!f) f = fopen("/tmp/kryoterm-gui.log", "w");
    if (!f) return;
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f); fflush(f);
}

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
    kPadX = 6;  kPadY = 4;  gCopyOnSelect = NO;  gScrollbackLines = 2000;  gLineSpacing = 0;  gBellMode = 1;
    NSString *dir  = [NSHomeDirectory() stringByAppendingPathComponent:@".config/kryoterm"];
    NSString *path = [dir stringByAppendingPathComponent:@"config"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *def =
          @"# kryoterm config — colours as #RRGGBB.\n"
           "titlebar_light   = #2b2b2b\n"
           "titlebar_dark    = #000000\n"
           "background_light = #2b2b2b\n"
           "background_dark  = #000000\n"
           "cursor_blink_ms  = 530\n"
           "cursor_color     = #d8dad4\n"
           "cursor_style     = bar          # bar | block | underline\n"
           "font_family      = JetBrainsMono Nerd Font Mono\n"
           "font_size        = 13\n"
           "opacity          = 1.0\n"
           "padding          = 6\n"
           "line_spacing     = 0\n"
           "bell             = visual       # visual | audible | off\n"
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
        if ([k isEqualToString:@"cursor_style"]) { gCursorStyle = [v hasPrefix:@"block"] ? 1 : ([v hasPrefix:@"under"] ? 2 : 0); continue; }
        if ([k isEqualToString:@"font_family"]) { if (v.length) gFontName = v; continue; }
        if ([k isEqualToString:@"font_size"])   { CGFloat fs = atof(v.UTF8String); if (fs >= 6) gFontSize = fs; continue; }
        if ([k isEqualToString:@"opacity"])     { CGFloat o = atof(v.UTF8String); if (o >= 0.2 && o <= 1.0) gOpacity = o; continue; }
        if ([k isEqualToString:@"padding"])     { CGFloat pd = atof(v.UTF8String); if (pd >= 0 && pd <= 40) { kPadX = pd; kPadY = pd; } continue; }
        if ([k isEqualToString:@"copy_on_select"]) { gCopyOnSelect = ([v hasPrefix:@"t"] || [v hasPrefix:@"1"] || [v hasPrefix:@"y"]); continue; }
        if ([k isEqualToString:@"scrollback_lines"]) { int n = atoi(v.UTF8String); if (n >= 100) gScrollbackLines = n; continue; }
        if ([k isEqualToString:@"line_spacing"]) { CGFloat ls = atof(v.UTF8String); if (ls >= 0 && ls <= 20) gLineSpacing = ls; continue; }
        if ([k isEqualToString:@"bell"]) { gBellMode = [v hasPrefix:@"aud"] ? 2 : ([v hasPrefix:@"off"] ? 0 : 1); continue; }
        NSColor *c = hexColor(v.UTF8String, nil);
        if (!c) continue;
        if      ([k isEqualToString:@"cursor_color"])     gCursorColor = c;
        else if ([k isEqualToString:@"titlebar_light"])   gTbLight = c;
        else if ([k isEqualToString:@"titlebar_dark"])    gTbDark  = c;
        else if ([k isEqualToString:@"background_light"]) gBgLight = c;
        else if ([k isEqualToString:@"background_dark"])  gBgDark  = c;
    }
    gCurBg = systemIsDark() ? gBgDark : gBgLight;
}

static void applyFont(void) {
    gFont = [NSFont fontWithName:gFontName size:gFontSize]
         ?: [NSFont fontWithName:@"JetBrainsMono Nerd Font Mono" size:gFontSize]
         ?: [NSFont fontWithName:@"Menlo" size:gFontSize]
         ?: [NSFont userFixedPitchFontOfSize:gFontSize];
    gCharW = gFont.maximumAdvancement.width;
    gLineH = [[NSLayoutManager new] defaultLineHeightForFont:gFont] + gLineSpacing;
}

static NSColor *xterm256(int n) {
    static const unsigned char base[16][3] = {
        {0,0,0},{205,49,49},{13,188,121},{229,229,16},{36,114,200},{188,63,188},{17,168,205},{204,204,204},
        {102,102,102},{241,76,76},{35,209,139},{245,245,67},{59,142,234},{214,112,214},{41,184,219},{255,255,255}
    };
    if (n < 0) n = 7;
    if (n < 16) return [NSColor colorWithCalibratedRed:base[n][0]/255.0 green:base[n][1]/255.0 blue:base[n][2]/255.0 alpha:1];
    if (n < 232) {
        int c = n - 16, r = c / 36, g = (c % 36) / 6, b = c % 6;
        int sc[6] = {0,95,135,175,215,255};
        return [NSColor colorWithCalibratedRed:sc[r]/255.0 green:sc[g]/255.0 blue:sc[b]/255.0 alpha:1];
    }
    int v = 8 + (n - 232) * 10;
    return [NSColor colorWithCalibratedRed:v/255.0 green:v/255.0 blue:v/255.0 alpha:1];
}
static NSColor *defaultFg(void) { return [NSColor colorWithCalibratedRed:0.82 green:0.84 blue:0.80 alpha:1]; }

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

static NSAttributedString *parseFrame(NSData *data) {
    NSFont *font = gFont;
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    const unsigned char *b = data.bytes;
    NSUInteger n = data.length, i = 0, runStart = 0;
    int curFg = -1, curBg = -1;
    while (i < n) {
        if (b[i] == 0x1b && i + 1 < n && b[i+1] == '[') {
            appendRun(out, b, runStart, i - runStart, curFg, curBg, font);
            NSUInteger j = i + 2; int code = 0, have = 0, newFg = curFg, newBg = curBg, stage = 0;
            while (j < n) {
                unsigned char p = b[j];
                if (p >= '0' && p <= '9') { code = code*10 + (p - '0'); have = 1; }
                else if (p == ';' || (p >= 0x40 && p <= 0x7e)) {
                    if (have || p == 'm') {
                        if (stage == 2) { newFg = code; stage = 0; }
                        else if (stage == 4) { newBg = code; stage = 0; }
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
    appendRun(out, b, runStart, i - runStart, curFg, curBg, font);
    if (gLineSpacing > 0 && out.length) {
        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.lineSpacing = gLineSpacing;
        [out addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, out.length)];
    }
    return out;
}

// ---- KryptonView: one pane (its own engine + state) -----------------------
@interface KryptonView : NSView <NSTextFieldDelegate>
@property (strong) NSAttributedString *attr;
@property (assign) int master;
@property (assign) int readFd;
@property (assign) pid_t child;
@property (strong) NSTextField *searchField;
@property (strong) NSTextField *searchCount;
@end

void closePaneView(KryptonView *pane);   // fwd (defined after the class)

@implementation KryptonView {
    int _curRow, _curCol, _cols, _rows, _scrollOff, _scrollMax;
    int _selAR, _selAC, _selER, _selEC; BOOL _hasSel;
    int _matchRow, _matchCol, _matchLen, _matchNum, _matchTotal;
    int _mouseLevel, _mouseSgr, _cursorShape, _pasteMode, _altActive, _focusMode;
    int _mousePressBtn, _lastMouseR, _lastMouseC; BOOL _mouseReporting;
    BOOL _flashOn;
}
- (instancetype)initWithFrame:(NSRect)f {
    self = [super initWithFrame:f];
    if (self) { _master = -1; _readFd = -1; _child = -1; _cols = 104; _rows = 30;
                _curRow = 0; _curCol = 0; _scrollMax = 0; _matchRow = -1; _lastMouseR = -1; _lastMouseC = -1; }
    return self;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return YES; }
- (BOOL)isActivePane { return self.window.isKeyWindow && self.window.firstResponder == self; }

// --- engine + reader ---
- (void)spawnEngine {
    int inpipe[2], outpipe[2];
    if (pipe(inpipe) || pipe(outpipe)) return;
    pid_t pid = fork();
    if (pid < 0) return;
    if (pid == 0) {
        dup2(inpipe[0], 0); dup2(outpipe[1], 1); dup2(outpipe[1], 2);
        close(inpipe[0]); close(inpipe[1]); close(outpipe[0]); close(outpipe[1]);
        execl(gKPath.fileSystemRepresentation, gKPath.fileSystemRepresentation, "-i", (char *)NULL);
        _exit(127);
    }
    close(inpipe[0]); close(outpipe[1]);
    _master = inpipe[1]; _readFd = outpipe[0]; _child = pid;
    glog("pane %p spawned: child=%d master=%d panes=%lu", self, pid, _master, (unsigned long)gPanes.count);
    [NSThread detachNewThreadSelector:@selector(readLoop) toTarget:self withObject:nil];
}
- (void)readLoop {
    NSMutableData *frame = [NSMutableData data];
    unsigned char buf[8192]; ssize_t got;
    int rfd = _readFd;
    while ((got = read(rfd, buf, sizeof(buf))) > 0) {
        for (ssize_t i = 0; i < got; i++) {
            if (buf[i] == 0x0c) {
                NSData *snap = [frame copy];
                dispatch_async(dispatch_get_main_queue(), ^{ [self applyFrame:snap]; });
                [frame setLength:0];
            } else [frame appendBytes:&buf[i] length:1];
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [self engineExited]; });
}
- (void)applyFrame:(NSData *)snap {
    NSData *body = snap;
    const unsigned char *p = snap.bytes; NSUInteger len = snap.length;
    if (len > 0 && p[0] == 1) {
        NSUInteger k = 1; while (k < len && p[k] != 1) k++;
        if (k < len) {
            int fv[16] = {0}; int neg[16] = {0}; int field = 0; NSUInteger ts = 0;
            for (NSUInteger m = 1; m < k; m++) {
                if (p[m] == ',') { field++; if (field == 16) { ts = m+1; break; } }
                else if (field < 16) { if (p[m]=='-') neg[field]=1; else if (p[m]>='0'&&p[m]<='9') fv[field]=fv[field]*10+(p[m]-'0'); }
            }
            for (int q = 0; q < 16; q++) if (neg[q]) fv[q] = -fv[q];
            _curRow=fv[0]; _curCol=fv[1]; _scrollOff=fv[2]; _scrollMax=fv[3];
            _matchRow=fv[4]; _matchCol=fv[5]; _matchLen=fv[6]; _matchNum=fv[7]; _matchTotal=fv[8];
            _mouseLevel=fv[10]; _mouseSgr=fv[11]; _cursorShape=fv[12]; _pasteMode=fv[13]; _altActive=fv[14]; _focusMode=fv[15];
            if (fv[9] == 1) {
                if (gBellMode == 2) NSBeep();
                else if (gBellMode == 1) { _flashOn = YES; [self setNeedsDisplay:YES];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ _flashOn = NO; [self setNeedsDisplay:YES]; }); }
            }
            if (!_searchField.hidden)
                _searchCount.stringValue = _matchTotal > 0 ? [NSString stringWithFormat:@"%d/%d", _matchNum, _matchTotal] : @"0/0";
            if (ts && ts < k) {
                NSString *t = [[NSString alloc] initWithBytes:p+ts length:k-ts encoding:NSUTF8StringEncoding];
                if (t.length && self.isActivePane) [self.window setTitle:t];
            }
            body = [snap subdataWithRange:NSMakeRange(k+1, len-(k+1))];
        }
    }
    self.attr = parseFrame(body);
    gCursorOn = YES;
    [self setNeedsDisplay:YES];
}
- (void)engineExited { closePaneView(self); }
- (void)focusIn { if (_focusMode && self.master >= 0) write(self.master, "\033[I", 3); }

// --- size + control markers ---
- (void)sendResize {
    if (_master < 0 || gCharW < 1 || gLineH < 1) return;
    int cols = (int)((self.bounds.size.width - 2*kPadX) / gCharW);
    int rows = (int)((self.bounds.size.height - 2*kPadY) / gLineH);
    if (cols < 4) cols = 4;  if (rows < 2) rows = 2;
    if (cols == _cols && rows == _rows) return;
    _cols = cols; _rows = rows;
    char b[64]; int n = snprintf(b, sizeof b, "\036R,%d,%d\036", cols, rows); write(_master, b, n);
}
- (void)sendScrollbackCap { if (_master >= 0) { char b[32]; int n = snprintf(b,sizeof b,"\036L,%d\036",gScrollbackLines); write(_master,b,n); } }
- (void)viewDidEndLiveResize { _hasSel = NO; [self sendResize]; }
- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self sendResize]; }

// --- mouse encoding (X10 / SGR-1006) ---
- (void)sendMouseButton:(int)btn row:(int)r col:(int)c press:(BOOL)press {
    if (_master < 0 || r < 0 || c < 0) return;
    int cx = c + 1, cy = r + 1;
    if (_mouseSgr) { char b[48]; snprintf(b,sizeof b,"\033[<%d;%d;%d%c",btn,cx,cy,press?'M':'m'); write(_master,b,strlen(b)); }
    else { int eb = press ? btn : 3; int bx = cx+32, by = cy+32; if (bx>255)bx=255; if (by>255)by=255;
           unsigned char x[6] = {0x1b,'[','M',(unsigned char)(eb+32),(unsigned char)bx,(unsigned char)by}; write(_master,x,6); }
}
- (int)mouseModsFor:(NSEvent *)e {
    int m = 0;
    if (e.modifierFlags & NSEventModifierFlagShift)   m += 4;
    if (e.modifierFlags & NSEventModifierFlagOption)  m += 8;
    if (e.modifierFlags & NSEventModifierFlagControl) m += 16;
    return m;
}
- (void)pointToCell:(NSEvent *)e row:(int *)row col:(int *)col {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    int c = (int)((p.x - kPadX) / gCharW), r = (int)((p.y - kPadY) / gLineH);
    if (c < 0) c = 0;  if (c > _cols) c = _cols;
    if (r < 0) r = 0;  if (r >= _rows) r = _rows - 1;
    *row = r; *col = c;
}
- (BOOL)reportMouse:(NSEvent *)e button:(int)base press:(BOOL)press {
    if (_mouseLevel <= 0 || (e.modifierFlags & NSEventModifierFlagShift)) return NO;
    int r, c; [self pointToCell:e row:&r col:&c];
    _mousePressBtn = base + [self mouseModsFor:e];
    [self sendMouseButton:_mousePressBtn row:r col:c press:press];
    _lastMouseR = r; _lastMouseC = c;
    return YES;
}
- (void)mouseDown:(NSEvent *)e {
    [self.window makeFirstResponder:self];
    int r, c; [self pointToCell:e row:&r col:&c];
    if (e.modifierFlags & NSEventModifierFlagCommand) { [self openUrlAtRow:r col:c]; return; }
    if ([self reportMouse:e button:0 press:YES]) { _mouseReporting = YES; return; }
    if (e.modifierFlags & NSEventModifierFlagShift) { _selER=r; _selEC=c; _hasSel=(_selER!=_selAR||_selEC!=_selAC); [self setNeedsDisplay:YES]; return; }
    if (e.clickCount == 2)      [self selectWordRow:r col:c];
    else if (e.clickCount == 3) [self selectLineRow:r];
    else { _selAR=r; _selAC=c; _selER=r; _selEC=c; _hasSel=NO; }
    [self setNeedsDisplay:YES];
}
- (void)mouseDragged:(NSEvent *)e {
    if (_mouseReporting) { if (_mouseLevel >= 2) { int r,c; [self pointToCell:e row:&r col:&c];
            if (r!=_lastMouseR||c!=_lastMouseC) { [self sendMouseButton:32+_mousePressBtn row:r col:c press:YES]; _lastMouseR=r; _lastMouseC=c; } } return; }
    [self pointToCell:e row:&_selER col:&_selEC]; _hasSel=(_selER!=_selAR||_selEC!=_selAC); [self setNeedsDisplay:YES];
}
- (void)mouseUp:(NSEvent *)e {
    if (_mouseReporting) { [self sendMouseButton:_mousePressBtn row:_lastMouseR col:_lastMouseC press:NO]; _mouseReporting=NO; return; }
    if (gCopyOnSelect && _hasSel) [self copySelection];
}
- (void)otherMouseDown:(NSEvent *)e {
    [self.window makeFirstResponder:self];
    if ([self reportMouse:e button:(e.buttonNumber==2?1:2) press:YES]) { _mouseReporting=YES; return; }
    if (e.buttonNumber == 2) [self pasteClipboard];
}
- (void)otherMouseUp:(NSEvent *)e { if (_mouseReporting) { [self sendMouseButton:_mousePressBtn row:_lastMouseR col:_lastMouseC press:NO]; _mouseReporting=NO; } }
- (void)rightMouseDown:(NSEvent *)e { [self.window makeFirstResponder:self]; if ([self reportMouse:e button:2 press:YES]) _mouseReporting=YES; }
- (void)rightMouseUp:(NSEvent *)e { if (_mouseReporting) { [self sendMouseButton:_mousePressBtn row:_lastMouseR col:_lastMouseC press:NO]; _mouseReporting=NO; } }
- (void)scrollWheel:(NSEvent *)e {
    if (_master < 0 || gLineH < 1) return;
    static CGFloat acc = 0;
    acc += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * gLineH;
    int lines = (int)(acc / gLineH);
    if (lines == 0) return;
    acc -= lines * gLineH;
    if (_mouseLevel > 0 && !(e.modifierFlags & NSEventModifierFlagShift)) {
        int r,c; [self pointToCell:e row:&r col:&c];
        int btn = (lines>0?64:65) + [self mouseModsFor:e]; int n = lines>0?lines:-lines;
        for (int i=0;i<n&&i<8;i++) [self sendMouseButton:btn row:r col:c press:YES]; return;
    }
    if (_altActive && !(e.modifierFlags & NSEventModifierFlagShift)) {
        const char *arrow = lines>0 ? "\x1b[A" : "\x1b[B"; int n = lines>0?lines:-lines;
        for (int i=0;i<n&&i<6;i++) write(_master, arrow, 3); return;
    }
    char b[32];
    if (lines > 0) snprintf(b,sizeof b,"\036U,%d\036",lines); else snprintf(b,sizeof b,"\036D,%d\036",-lines);
    write(_master, b, strlen(b));
}

// --- selection / copy / paste / urls ---
- (void)selectWordRow:(int)r col:(int)c {
    NSArray<NSString *> *L = [self.attr.string componentsSeparatedByString:@"\n"];
    if (r >= (int)L.count) { _hasSel = NO; return; }
    NSString *ln = L[r]; int n = (int)ln.length; if (n==0) { _hasSel=NO; return; } if (c>=n) c=n-1;
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet]; int a=c,b=c;
    while (a>0 && ![ws characterIsMember:[ln characterAtIndex:a-1]]) a--;
    while (b<n && ![ws characterIsMember:[ln characterAtIndex:b]]) b++;
    _selAR=r; _selAC=a; _selER=r; _selEC=b; _hasSel=(b>a);
}
- (void)selectLineRow:(int)r {
    NSArray<NSString *> *L = [self.attr.string componentsSeparatedByString:@"\n"];
    int n = (r<(int)L.count) ? (int)[L[r] length] : 0;
    _selAR=r; _selAC=0; _selER=r; _selEC=n; _hasSel=(n>0);
}
- (NSString *)selectedText {
    if (!_hasSel || !self.attr) return nil;
    NSArray<NSString *> *L = [self.attr.string componentsSeparatedByString:@"\n"];
    int r1=_selAR,c1=_selAC,r2=_selER,c2=_selEC;
    if (r2<r1 || (r2==r1&&c2<c1)) { int tr=r1,tc=c1; r1=r2;c1=c2;r2=tr;c2=tc; }
    NSMutableString *o = [NSMutableString string];
    for (int r=r1; r<=r2 && r<(int)L.count; r++) {
        NSString *ln=L[r]; int n=(int)ln.length; int a=(r==r1)?c1:0,b=(r==r2)?c2:n;
        if (a>n)a=n; if (b>n)b=n; if (b<a)b=a;
        [o appendString:[ln substringWithRange:NSMakeRange(a,b-a)]];
        if (r<r2) [o appendString:@"\n"];
    }
    return o;
}
- (void)copySelection { NSString *t=[self selectedText]; if (t.length) { NSPasteboard *pb=[NSPasteboard generalPasteboard]; [pb clearContents]; [pb setString:t forType:NSPasteboardTypeString]; } }
- (void)pasteClipboard {
    NSString *t = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
    if (t.length && _master >= 0) { const char *b=[t UTF8String];
        if (_pasteMode) write(_master,"\033[200~",6); write(_master,b,strlen(b)); if (_pasteMode) write(_master,"\033[201~",6); }
}

// --- standard Edit-menu actions (routed via responder chain to the focused pane) ---
- (void)copy:(id)s { [self copySelection]; }
- (void)paste:(id)s { [self pasteClipboard]; }
- (void)pasteSelection:(id)s {                      // paste the highlighted terminal selection to the shell
    NSString *t = [self selectedText];
    if (t.length && _master >= 0) { const char *b=[t UTF8String];
        if (_pasteMode) write(_master,"\033[200~",6); write(_master,b,strlen(b)); if (_pasteMode) write(_master,"\033[201~",6); }
}
- (void)selectAll:(id)s { _selAR=0; _selAC=0; _selER=_rows-1; _selEC=_cols; _hasSel=YES; [self setNeedsDisplay:YES]; }
- (void)performFind:(id)s { [self openSearch]; }
- (void)insertText:(id)s {                          // emoji picker / dictation insert here
    NSString *str = [s isKindOfClass:[NSAttributedString class]] ? [(NSAttributedString *)s string] : (NSString *)s;
    if (_master >= 0 && str.length) { const char *b=[str UTF8String]; write(_master, b, strlen(b)); }
}
- (BOOL)validateMenuItem:(NSMenuItem *)mi {
    SEL a = mi.action;
    if (a == @selector(copy:) || a == @selector(pasteSelection:)) return _hasSel;
    return YES;
}
- (void)openUrlAtRow:(int)r col:(int)c {
    NSArray<NSString *> *L = [self.attr.string componentsSeparatedByString:@"\n"];
    if (r<0 || r>=(int)L.count) return;
    NSString *ln=L[r]; int n=(int)ln.length; if (c>=n) return;
    NSCharacterSet *ws=[NSCharacterSet whitespaceCharacterSet]; int a=c,b=c;
    while (a>0 && ![ws characterIsMember:[ln characterAtIndex:a-1]]) a--;
    while (b<n && ![ws characterIsMember:[ln characterAtIndex:b]]) b++;
    NSString *tok=[ln substringWithRange:NSMakeRange(a,b-a)];
    NSCharacterSet *trail=[NSCharacterSet characterSetWithCharactersInString:@".,;:)]}>\"'"];
    while (tok.length && [trail characterIsMember:[tok characterAtIndex:tok.length-1]]) tok=[tok substringToIndex:tok.length-1];
    NSString *url=nil;
    if ([tok hasPrefix:@"http://"]||[tok hasPrefix:@"https://"]||[tok hasPrefix:@"file://"]) url=tok;
    else if ([tok hasPrefix:@"www."]) url=[@"https://" stringByAppendingString:tok];
    if (url) { NSURL *u=[NSURL URLWithString:url]; if (u) [[NSWorkspace sharedWorkspace] openURL:u]; return; }
    if ([tok hasPrefix:@"/"]||[tok hasPrefix:@"~/"]) { NSString *path=[tok stringByExpandingTildeInPath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]]; }
}

// --- find search bar ---
- (void)sendFind:(NSString *)cmd query:(NSString *)q {
    if (_master < 0) return;
    NSString *m = [NSString stringWithFormat:@"\036%@,%@\036", cmd, q ?: @""];
    const char *b = [m UTF8String]; write(_master, b, strlen(b));
}
- (void)openSearch { _searchField.hidden=NO; _searchField.stringValue=@""; _searchCount.hidden=NO; _searchCount.stringValue=@""; [self.window makeFirstResponder:_searchField]; }
- (void)closeSearch { _searchField.hidden=YES; _searchCount.hidden=YES; if (_master>=0) write(_master,"\036X,0\036",5); [self.window makeFirstResponder:self]; }
- (void)controlTextDidChange:(NSNotification *)n { [self sendFind:@"F" query:_searchField.stringValue]; }
- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(insertNewline:))   { [self sendFind:@"N" query:_searchField.stringValue]; return YES; }
    if (sel == @selector(cancelOperation:)) { [self closeSearch]; return YES; }
    return NO;
}

// --- draw ---
- (void)drawRect:(NSRect)dirty {
    [[(gCurBg ?: [NSColor blackColor]) colorWithAlphaComponent:gOpacity] set];
    NSRectFill(self.bounds);
    if (self.attr) [self.attr drawAtPoint:NSMakePoint(kPadX, kPadY)];
    if (self.attr) {     // underline URLs
        NSArray<NSString *> *L = [self.attr.string componentsSeparatedByString:@"\n"];
        NSCharacterSet *ws=[NSCharacterSet whitespaceCharacterSet];
        [[NSColor colorWithCalibratedRed:0.40 green:0.62 blue:0.95 alpha:0.7] set];
        for (int r=0; r<(int)L.count && r<_rows; r++) {
            NSString *ln=L[r]; NSRange sr=NSMakeRange(0,ln.length);
            while (sr.length) { NSRange m=[ln rangeOfString:@"http" options:0 range:sr]; if (m.location==NSNotFound) break;
                NSUInteger a=m.location,b=a; while (b<ln.length && ![ws characterIsMember:[ln characterAtIndex:b]]) b++;
                NSString *tok=[ln substringWithRange:NSMakeRange(a,b-a)];
                if ([tok hasPrefix:@"http://"]||[tok hasPrefix:@"https://"]) NSRectFill(NSMakeRect(kPadX+a*gCharW,kPadY+r*gLineH+gLineH-1.5,(b-a)*gCharW,1.0));
                sr=NSMakeRange(b,ln.length-b); }
        }
    }
    if (_curRow < _rows) {   // cursor: active pane filled, else hollow
        NSColor *cc = gCursorColor ?: [NSColor whiteColor];
        CGFloat x=kPadX+_curCol*gCharW, y=kPadY+_curRow*gLineH;
        if (!self.isActivePane) { [cc set]; NSFrameRect(NSMakeRect(x,y,gCharW,gLineH)); }
        else if (gCursorOn) {
            int style = _cursorShape>0 ? _cursorShape-1 : gCursorStyle; NSRect r;
            if (style==1) { r=NSMakeRect(x,y,gCharW,gLineH); cc=[cc colorWithAlphaComponent:0.45]; }
            else if (style==2) { r=NSMakeRect(x,y+gLineH-2,gCharW,2); }
            else { r=NSMakeRect(x,y,2.0,gLineH); }
            [cc set]; NSRectFill(r);
        }
    }
    if (_hasSel) {
        int r1=_selAR,c1=_selAC,r2=_selER,c2=_selEC; if (r2<r1||(r2==r1&&c2<c1)){int tr=r1,tc=c1;r1=r2;c1=c2;r2=tr;c2=tc;}
        [[NSColor colorWithCalibratedRed:0.30 green:0.48 blue:0.85 alpha:0.30] set];
        for (int r=r1;r<=r2;r++){ int a=(r==r1)?c1:0,b=(r==r2)?c2:_cols; NSRectFill(NSMakeRect(kPadX+a*gCharW,kPadY+r*gLineH,(b-a)*gCharW,gLineH)); }
    }
    if (!_searchField.hidden && _searchField.stringValue.length && self.attr) {
        NSString *q=_searchField.stringValue; NSArray<NSString *> *L=[self.attr.string componentsSeparatedByString:@"\n"];
        [[NSColor colorWithCalibratedRed:0.96 green:0.80 blue:0.25 alpha:0.20] set];
        for (int r=0;r<(int)L.count && r<_rows;r++){ NSString *ln=L[r]; NSRange sr=NSMakeRange(0,ln.length);
            while (sr.length){ NSRange m=[ln rangeOfString:q options:0 range:sr]; if (m.location==NSNotFound) break;
                NSRectFill(NSMakeRect(kPadX+m.location*gCharW,kPadY+r*gLineH,m.length*gCharW,gLineH)); NSUInteger nx=m.location+m.length; sr=NSMakeRange(nx,ln.length-nx); } }
    }
    if (_matchRow >= 0 && _matchLen > 0) { [[NSColor colorWithCalibratedRed:0.96 green:0.80 blue:0.25 alpha:0.55] set];
        NSRectFill(NSMakeRect(kPadX+_matchCol*gCharW,kPadY+_matchRow*gLineH,_matchLen*gCharW,gLineH)); }
    if (_scrollOff > 0 && _scrollMax > 0) {
        CGFloat H=self.bounds.size.height, total=_scrollMax+_rows; CGFloat th=(_rows/total)*H; if (th<24) th=24;
        CGFloat y=((CGFloat)(_scrollMax-_scrollOff)/total)*H; if (y+th>H) y=H-th; if (y<0) y=0;
        [[NSColor colorWithCalibratedRed:0.72 green:0.74 blue:0.70 alpha:0.5] set]; NSRectFill(NSMakeRect(self.bounds.size.width-5,y,3,th));
    }
    // active-pane accent border (so you can see which pane has focus when split)
    if (self.isActivePane && gPanes.count > 1) {
        [[NSColor colorWithCalibratedRed:0.24 green:0.83 blue:0.55 alpha:0.55] set];
        NSFrameRectWithWidth(self.bounds, 1.5);
    }
    if (_flashOn) { [[NSColor colorWithCalibratedWhite:0.9 alpha:0.22] set]; NSRectFill(self.bounds); }
}

- (void)keyDown:(NSEvent *)e {
    if (_master < 0) return;
    if (e.modifierFlags & NSEventModifierFlagCommand) {
        NSString *ch = e.charactersIgnoringModifiers;
        if ([ch isEqualToString:@"c"]) { [self copySelection]; return; }
        if ([ch isEqualToString:@"v"]) { [self pasteClipboard]; return; }
        if ([ch isEqualToString:@"f"]) { [self openSearch]; return; }
        if ([ch isEqualToString:@"a"]) { _selAR=0; _selAC=0; _selER=_rows-1; _selEC=_cols; _hasSel=YES; [self setNeedsDisplay:YES]; return; }
        if ([ch isEqualToString:@"g"]) { write(_master,"\036N,\036",4); return; }
        if ([ch isEqualToString:@"G"]) { write(_master,"\036P,\036",4); return; }
        if ([ch isEqualToString:@"="] || [ch isEqualToString:@"+"]) { gFontSize+=1; applyFont(); for (KryptonView *p in gPanes){[p sendResize];[p setNeedsDisplay:YES];} return; }
        if ([ch isEqualToString:@"-"]) { if (gFontSize>7) gFontSize-=1; applyFont(); for (KryptonView *p in gPanes){[p sendResize];[p setNeedsDisplay:YES];} return; }
        if ([ch isEqualToString:@"0"]) { loadConfig(); applyFont(); for (KryptonView *p in gPanes){[p sendResize];[p setNeedsDisplay:YES];} return; }
        int page = _rows>2 ? _rows-2 : 1; char nb[24];
        if (e.keyCode==126) { snprintf(nb,sizeof nb,"\036U,%d\036",page); write(_master,nb,strlen(nb)); return; }
        if (e.keyCode==125) { snprintf(nb,sizeof nb,"\036D,%d\036",page); write(_master,nb,strlen(nb)); return; }
        if (e.keyCode==115) { write(_master,"\036U,99999\036",9); return; }
        if (e.keyCode==119) { write(_master,"\036D,99999\036",9); return; }
    }
    if ((e.modifierFlags & NSEventModifierFlagShift) && (e.keyCode==116 || e.keyCode==121)) {
        int page=_rows>2?_rows-2:1; char nb[24]; snprintf(nb,sizeof nb,"\036%c,%d\036",e.keyCode==116?'U':'D',page); write(_master,nb,strlen(nb)); return;
    }
    const char *seq = NULL;
    switch (e.keyCode) {
        case 126: seq="\x1b[A"; break; case 125: seq="\x1b[B"; break;
        case 124: seq="\x1b[C"; break; case 123: seq="\x1b[D"; break;
        case 115: seq="\x1b[H"; break; case 119: seq="\x1b[F"; break;
        case 116: seq="\x1b[5~"; break; case 121: seq="\x1b[6~"; break; case 117: seq="\x1b[3~"; break;
    }
    if (seq) { write(_master, seq, strlen(seq)); return; }
    NSString *chars = e.characters;
    if (chars.length) { const char *b=[chars UTF8String]; write(_master, b, strlen(b)); }
}

// drag-drop files -> quoted paths
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)s { return NSDragOperationCopy; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)s {
    NSArray<NSURL *> *urls = [[s draggingPasteboard] readObjectsForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    if (!urls.count || _master < 0) return NO;
    NSMutableString *o=[NSMutableString string];
    for (NSURL *u in urls) [o appendFormat:@"'%@' ",[u.path stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
    const char *b=[o UTF8String]; write(_master,b,strlen(b)); return YES;
}
@end

// ---- pane / window / split / tab management -------------------------------
static KryptonView *activePane(void) {
    NSWindow *w = [NSApp keyWindow]; if (!w) w = [NSApp mainWindow];
    NSResponder *fr = w.firstResponder;
    if ([fr isKindOfClass:[KryptonView class]]) return (KryptonView *)fr;
    // fall back to the first pane found in the window
    for (KryptonView *p in gPanes) if (p.window == w) return p;
    return nil;
}

// Build a pane: view + its search field overlay + a spawned engine.
static KryptonView *makePane(NSRect frame) {
    KryptonView *v = [[KryptonView alloc] initWithFrame:frame];
    [v setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [v registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    NSTextField *sf = [[NSTextField alloc] initWithFrame:NSMakeRect(frame.size.width-230, 4, 220, 24)];
    sf.delegate = v; sf.hidden = YES; sf.bezeled = YES; sf.font = [NSFont systemFontOfSize:12];
    [sf.cell setPlaceholderString:@"find in scrollback…"];
    [sf setAutoresizingMask:(NSViewMinXMargin | NSViewMaxYMargin)];
    [v addSubview:sf]; v.searchField = sf;
    NSTextField *sc = [[NSTextField alloc] initWithFrame:NSMakeRect(frame.size.width-230-62, 6, 56, 20)];
    sc.editable=NO; sc.bezeled=NO; sc.drawsBackground=NO; sc.hidden=YES; sc.alignment=NSTextAlignmentRight;
    sc.font=[NSFont systemFontOfSize:11]; sc.textColor=[NSColor secondaryLabelColor];
    [sc setAutoresizingMask:(NSViewMinXMargin | NSViewMaxYMargin)];
    [v addSubview:sc]; v.searchCount = sc;
    [gPanes addObject:v];
    [v spawnEngine];
    return v;
}

static void applyWindowChrome(NSWindow *win) {
    win.titlebarAppearsTransparent = YES;
    win.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    win.opaque = (gOpacity >= 0.999);
    win.backgroundColor = [(systemIsDark() ? gTbDark : gTbLight) colorWithAlphaComponent:gOpacity];
}

static NSWindow *makeWindow(void) {
    NSRect frame = NSMakeRect(0, 0, 830, 500);
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable)
        backing:NSBackingStoreBuffered defer:NO];
    [win setTitle:@"kryoterm"];
    [win setContentMinSize:NSMakeSize(240, 140)];
    win.tabbingMode = NSWindowTabbingModeAutomatic;
    win.tabbingIdentifier = @"kryoterm";
    win.releasedWhenClosed = NO;
    applyWindowChrome(win);
    NSView *root = [[NSView alloc] initWithFrame:frame];
    root.autoresizesSubviews = YES;
    KryptonView *pane = makePane(root.bounds);
    [root addSubview:pane];
    [win setContentView:root];
    [win setInitialFirstResponder:pane];
    dispatch_async(dispatch_get_main_queue(), ^{ [win makeFirstResponder:pane]; [pane sendResize]; [pane sendScrollbackCap]; });
    return win;
}

// close one pane: kill its engine, drop it; collapse its split; close the window if it was the last pane.
void closePaneView(KryptonView *pane) {
    if (![gPanes containsObject:pane]) return;
    if (pane.child > 0) kill(pane.child, SIGTERM);
    if (pane.master >= 0) close(pane.master);
    [gPanes removeObject:pane];
    NSWindow *win = pane.window;
    NSView *parent = pane.superview;
    [pane removeFromSuperview];
    if ([parent isKindOfClass:[NSSplitView class]]) {
        NSSplitView *sv = (NSSplitView *)parent;
        if (sv.subviews.count == 1) {                 // collapse split -> sole sibling
            NSView *sib = sv.subviews[0];
            [sib removeFromSuperview];
            sib.frame = sv.frame; sib.autoresizingMask = sv.autoresizingMask;
            [sv.superview replaceSubview:sv with:sib];
        } else { [sv adjustSubviews]; }
        KryptonView *focus = nil;                      // refocus some pane in the window
        for (KryptonView *p in gPanes) if (p.window == win) { focus = p; break; }
        if (focus) { [win makeFirstResponder:focus]; }
        for (KryptonView *p in gPanes) if (p.window == win) [p sendResize];
    } else {                                           // sole pane -> close the window
        BOOL more = NO; for (KryptonView *p in gPanes) if (p.window == win) { more = YES; break; }
        if (!more) [win close];
    }
}

static void splitActive(BOOL vertical, BOOL newAfter) {
    KryptonView *act = activePane();
    if (!act) return;
    NSWindow *w = act.window;
    NSSplitView *sv = [[NSSplitView alloc] initWithFrame:act.frame];
    sv.vertical = vertical;            // YES = side-by-side (left/right); NO = stacked (up/down)
    sv.dividerStyle = NSSplitViewDividerStyleThin;
    sv.autoresizingMask = act.autoresizingMask;
    KryptonView *np = makePane(act.bounds);
    [act.superview replaceSubview:act with:sv];   // sv takes act's exact slot
    act.autoresizingMask = (NSViewWidthSizable|NSViewHeightSizable);
    np.autoresizingMask  = (NSViewWidthSizable|NSViewHeightSizable);
    if (newAfter) { [sv addSubview:act]; [sv addSubview:np]; }
    else          { [sv addSubview:np]; [sv addSubview:act]; }
    [sv adjustSubviews];
    CGFloat half = (vertical ? sv.bounds.size.width : sv.bounds.size.height) / 2;
    [sv setPosition:half ofDividerAtIndex:0];
    [w makeFirstResponder:np];
    dispatch_async(dispatch_get_main_queue(), ^{ for (KryptonView *p in gPanes) if (p.window == w) [p sendResize]; });
}

// ---- Contacts AutoFill (out-of-process system picker; no permission prompt) --
@interface ContactsHelper : NSObject <CNContactPickerDelegate>
@property (weak) KryptonView *target;
@end
@implementation ContactsHelper
- (void)contactPicker:(CNContactPicker *)p didSelectContactProperty:(CNContactProperty *)prop {
    id v = prop.value; NSString *s = nil;
    if ([v isKindOfClass:[NSString class]]) s = v;
    else if ([v isKindOfClass:[CNPhoneNumber class]]) s = [(CNPhoneNumber *)v stringValue];
    else if (v) s = [v description];
    if (s.length && self.target) [self.target insertText:s];
}
- (void)contactPicker:(CNContactPicker *)p didSelectContact:(CNContact *)c {
    NSString *n = [[NSString stringWithFormat:@"%@ %@", c.givenName, c.familyName]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (n.length && self.target) [self.target insertText:n];
}
@end
static ContactsHelper *gContacts;
static CNContactPicker *gPicker;

// ---- Writing Tools composer (NSTextView has native Writing Tools; run on the
//      terminal selection, then insert the result to the shell) ----------------
@interface WTComposer : NSObject
@property (strong) NSPanel *panel;
@property (strong) NSTextView *tv;
@property (weak) KryptonView *target;
@end
@implementation WTComposer
- (void)showFor:(KryptonView *)pane seed:(NSString *)seed {
    self.target = pane;
    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,540,380)
        styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered defer:NO];
    [p setTitle:@"Writing Tools"];
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(12,52,516,316)];
    sv.hasVerticalScroller = YES; sv.borderType = NSBezelBorder;
    sv.autoresizingMask = (NSViewWidthSizable|NSViewHeightSizable);
    NSTextView *tv = [[NSTextView alloc] initWithFrame:sv.bounds];
    tv.autoresizingMask = NSViewWidthSizable; tv.richText = NO;
    tv.string = seed ?: @"";
    tv.font = [NSFont systemFontOfSize:13];
    if (@available(macOS 15.2, *)) tv.writingToolsBehavior = NSWritingToolsBehaviorComplete;
    sv.documentView = tv;
    [p.contentView addSubview:sv];
    NSButton *wtb = [NSButton buttonWithTitle:@"Writing Tools…" target:self action:@selector(applyWT:)];
    wtb.frame = NSMakeRect(12,12,150,30); wtb.autoresizingMask = (NSViewMaxXMargin|NSViewMaxYMargin);
    [p.contentView addSubview:wtb];
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.frame = NSMakeRect(316,12,96,28); cancel.autoresizingMask = (NSViewMinXMargin|NSViewMaxYMargin);
    [p.contentView addSubview:cancel];
    NSButton *ins = [NSButton buttonWithTitle:@"Insert to Shell" target:self action:@selector(insert:)];
    ins.frame = NSMakeRect(416,12,112,30); ins.keyEquivalent = @"\r"; ins.autoresizingMask = (NSViewMinXMargin|NSViewMaxYMargin);
    [p.contentView addSubview:ins];
    self.panel = p; self.tv = tv;
    [p center]; [p makeKeyAndOrderFront:nil]; [p makeFirstResponder:tv];
}
- (void)applyWT:(id)s { if (@available(macOS 15.2, *)) [self.tv showWritingTools:nil]; else NSBeep(); }
- (void)insert:(id)s { if (self.target && self.tv.string.length) [self.target insertText:self.tv.string]; [self.panel close]; self.panel=nil; }
- (void)cancel:(id)s { [self.panel close]; self.panel=nil; }
@end
static WTComposer *gWT;

// ---- menu controller ------------------------------------------------------
@interface Controller : NSObject @end
@implementation Controller
- (void)newWindow:(id)s   { NSWindow *w = makeWindow(); [w center]; [w makeKeyAndOrderFront:nil]; }
- (void)newTab:(id)s {
    NSWindow *w = makeWindow();
    NSWindow *key = [NSApp keyWindow];
    if (key) [key addTabbedWindow:w ordered:NSWindowAbove]; else { [w center]; }
    [w makeKeyAndOrderFront:nil];
}
- (void)splitRight:(id)s { splitActive(YES, YES); }
- (void)splitLeft:(id)s  { splitActive(YES, NO); }
- (void)splitDown:(id)s  { splitActive(NO, YES); }
- (void)splitUp:(id)s    { splitActive(NO, NO); }
- (void)closePane:(id)s  { KryptonView *p = activePane(); if (p) closePaneView(p); }
- (void)closeWindow:(id)s { [[NSApp keyWindow] performClose:nil]; }
- (void)closeAll:(id)s   { for (NSWindow *w in [NSApp.windows copy]) [w close]; }
- (void)openWritingTools:(id)s {
    KryptonView *p = activePane(); if (!p) return;
    NSString *seed = [p selectedText] ?: @"";
    if (!gWT) gWT = [[WTComposer alloc] init];
    [gWT showFor:p seed:seed];
}
- (void)autoFillContacts:(id)s {
    KryptonView *p = activePane(); if (!p) return;
    if (!gContacts) gContacts = [[ContactsHelper alloc] init];
    gContacts.target = p;
    gPicker = [[CNContactPicker alloc] init];
    gPicker.delegate = gContacts;
    gPicker.displayedKeys = @[CNContactEmailAddressesKey, CNContactPhoneNumbersKey, CNContactPostalAddressesKey];
    NSRect r = NSMakeRect(NSMidX(p.bounds), NSMidY(p.bounds), 1, 1);
    [gPicker showRelativeToRect:r ofView:p preferredEdge:NSMinYEdge];
}
- (void)autoFillPasswords:(id)s {
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    NSURL *u = [ws URLForApplicationWithBundleIdentifier:@"com.apple.Passwords"];
    if (u) [ws openApplicationAtURL:u configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
    else NSBeep();
}
- (void)zoomIn:(id)s     { gFontSize += 1; applyFont(); for (KryptonView *p in gPanes) { [p sendResize]; [p setNeedsDisplay:YES]; } }
- (void)zoomOut:(id)s    { if (gFontSize > 7) gFontSize -= 1; applyFont(); for (KryptonView *p in gPanes) { [p sendResize]; [p setNeedsDisplay:YES]; } }
- (void)zoomActual:(id)s { loadConfig(); applyFont(); for (KryptonView *p in gPanes) { [p sendResize]; [p setNeedsDisplay:YES]; } }
- (void)openHelpPage:(id)s { [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://krypton-lang.org/kryoterm.html"]]; }
- (void)openGitHub:(id)s   { [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/t3m3d/kryoterm"]]; }
@end

static Controller *gController;

static void buildMenu(void) {
    NSMenu *mainMenu = [[NSMenu alloc] init];
    // App menu
    NSMenuItem *appItem = [[NSMenuItem alloc] init]; [mainMenu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"About kryoterm" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit kryoterm" action:@selector(terminate:) keyEquivalent:@"q"];
    [appItem setSubmenu:appMenu];
    // File menu
    NSMenuItem *fileItem = [[NSMenuItem alloc] init]; [mainMenu addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    NSMenuItem *mi;
    mi=[fileMenu addItemWithTitle:@"New Window" action:@selector(newWindow:) keyEquivalent:@"n"]; mi.target=gController;
    mi=[fileMenu addItemWithTitle:@"New Tab" action:@selector(newTab:) keyEquivalent:@"t"]; mi.target=gController;
    [fileMenu addItem:[NSMenuItem separatorItem]];
    mi=[fileMenu addItemWithTitle:@"Split Right" action:@selector(splitRight:) keyEquivalent:@"d"]; mi.target=gController;
    mi=[fileMenu addItemWithTitle:@"Split Left" action:@selector(splitLeft:) keyEquivalent:@""]; mi.target=gController;
    mi=[fileMenu addItemWithTitle:@"Split Down" action:@selector(splitDown:) keyEquivalent:@"d"]; mi.keyEquivalentModifierMask=(NSEventModifierFlagCommand|NSEventModifierFlagShift); mi.target=gController;
    mi=[fileMenu addItemWithTitle:@"Split Up" action:@selector(splitUp:) keyEquivalent:@""]; mi.target=gController;
    [fileMenu addItem:[NSMenuItem separatorItem]];
    mi=[fileMenu addItemWithTitle:@"Close" action:@selector(closePane:) keyEquivalent:@"w"]; mi.target=gController;
    mi=[fileMenu addItemWithTitle:@"Close Window" action:@selector(closeWindow:) keyEquivalent:@"w"]; mi.keyEquivalentModifierMask=(NSEventModifierFlagCommand|NSEventModifierFlagShift); mi.target=gController;
    mi=[fileMenu addItemWithTitle:@"Close All Windows" action:@selector(closeAll:) keyEquivalent:@"w"]; mi.keyEquivalentModifierMask=(NSEventModifierFlagCommand|NSEventModifierFlagOption); mi.target=gController;
    [fileItem setSubmenu:fileMenu];
    // Edit menu — actions route through the responder chain to the focused pane.
    NSMenuItem *editItem = [[NSMenuItem alloc] init]; [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    mi=[editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"z"]; mi.keyEquivalentModifierMask=(NSEventModifierFlagCommand|NSEventModifierFlagShift);
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Paste Selection" action:@selector(pasteSelection:) keyEquivalent:@""];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Find" action:@selector(performFind:) keyEquivalent:@"f"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *wt = [editMenu addItemWithTitle:@"Writing Tools" action:NULL keyEquivalent:@""];
    NSMenu *wtSub = [[NSMenu alloc] initWithTitle:@"Writing Tools"];
    SEL showWT = @selector(openWritingTools:);   // composer: selection -> native WT -> insert to shell
    [wtSub addItemWithTitle:@"Show Writing Tools" action:showWT keyEquivalent:@""];
    [wtSub addItem:[NSMenuItem separatorItem]];
    [wtSub addItemWithTitle:@"Proofread" action:showWT keyEquivalent:@""];
    [wtSub addItemWithTitle:@"Rewrite" action:showWT keyEquivalent:@""];
    [wtSub addItemWithTitle:@"Make Friendly" action:showWT keyEquivalent:@""];
    [wtSub addItem:[NSMenuItem separatorItem]];
    [wtSub addItemWithTitle:@"Make Professional" action:showWT keyEquivalent:@""];
    [wtSub addItemWithTitle:@"Make Concise" action:showWT keyEquivalent:@""];
    [wtSub addItem:[NSMenuItem separatorItem]];
    [wtSub addItemWithTitle:@"Summarize" action:showWT keyEquivalent:@""];
    [wtSub addItemWithTitle:@"Make Key Points" action:showWT keyEquivalent:@""];
    [wtSub addItemWithTitle:@"Make List" action:showWT keyEquivalent:@""];
    [wtSub addItemWithTitle:@"Make Table" action:showWT keyEquivalent:@""];
    for (NSMenuItem *it in wtSub.itemArray) it.target = gController;
    [wt setSubmenu:wtSub];
    NSMenuItem *af = [editMenu addItemWithTitle:@"AutoFill" action:NULL keyEquivalent:@""];
    NSMenu *afSub = [[NSMenu alloc] initWithTitle:@"AutoFill"];
    [afSub addItemWithTitle:@"Contacts" action:@selector(autoFillContacts:) keyEquivalent:@""];
    [afSub addItemWithTitle:@"Passwords" action:@selector(autoFillPasswords:) keyEquivalent:@""];
    for (NSMenuItem *it in afSub.itemArray) it.target = gController;
    [af setSubmenu:afSub];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Start Dictation…" action:@selector(startDictation:) keyEquivalent:@""];
    [editMenu addItemWithTitle:@"Emoji & Symbols" action:@selector(orderFrontCharacterPalette:) keyEquivalent:@""];
    [editItem setSubmenu:editMenu];
    // View menu — full screen, global font zoom, tab bar.
    NSMenuItem *viewItem = [[NSMenuItem alloc] init]; [mainMenu addItem:viewItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    mi=[viewMenu addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"]; mi.keyEquivalentModifierMask=(NSEventModifierFlagCommand|NSEventModifierFlagControl);
    [viewMenu addItem:[NSMenuItem separatorItem]];
    mi=[viewMenu addItemWithTitle:@"Bigger" action:@selector(zoomIn:) keyEquivalent:@"+"]; mi.target=gController;
    mi=[viewMenu addItemWithTitle:@"Default Size" action:@selector(zoomActual:) keyEquivalent:@"0"]; mi.target=gController;
    mi=[viewMenu addItemWithTitle:@"Smaller" action:@selector(zoomOut:) keyEquivalent:@"-"]; mi.target=gController;
    [viewMenu addItem:[NSMenuItem separatorItem]];
    [viewMenu addItemWithTitle:@"Show/Hide Tab Bar" action:@selector(toggleTabBar:) keyEquivalent:@""];
    [viewMenu addItemWithTitle:@"Show All Tabs" action:@selector(toggleTabOverview:) keyEquivalent:@""];
    [viewItem setSubmenu:viewMenu];
    // Window menu (native — gives tab navigation: Show Next/Previous Tab, etc.)
    NSMenuItem *winItem = [[NSMenuItem alloc] init]; [mainMenu addItem:winItem];
    NSMenu *winMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [winMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [winMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [winMenu addItem:[NSMenuItem separatorItem]];
    mi=[winMenu addItemWithTitle:@"Show Next Tab" action:@selector(selectNextTab:) keyEquivalent:@"\t"]; mi.keyEquivalentModifierMask=NSEventModifierFlagControl;
    mi=[winMenu addItemWithTitle:@"Show Previous Tab" action:@selector(selectPreviousTab:) keyEquivalent:@"\t"]; mi.keyEquivalentModifierMask=(NSEventModifierFlagControl|NSEventModifierFlagShift);
    [winMenu addItemWithTitle:@"Move Tab to New Window" action:@selector(moveTabToNewWindow:) keyEquivalent:@""];
    [winMenu addItemWithTitle:@"Merge All Windows" action:@selector(mergeAllWindows:) keyEquivalent:@""];
    [winMenu addItem:[NSMenuItem separatorItem]];
    [winMenu addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];
    [winMenu addItem:[NSMenuItem separatorItem]];   // macOS appends the open-window list below this
    [winItem setSubmenu:winMenu];
    // Help menu (macOS prepends a search field automatically).
    NSMenuItem *helpItem = [[NSMenuItem alloc] init]; [mainMenu addItem:helpItem];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    mi=[helpMenu addItemWithTitle:@"kryoterm Help" action:@selector(openHelpPage:) keyEquivalent:@"?"]; mi.target=gController;
    [helpMenu addItem:[NSMenuItem separatorItem]];
    mi=[helpMenu addItemWithTitle:@"kryoterm on GitHub" action:@selector(openGitHub:) keyEquivalent:@""]; mi.target=gController;
    [helpItem setSubmenu:helpMenu];
    [NSApp setMainMenu:mainMenu];
    [NSApp setWindowsMenu:winMenu];
    [NSApp setHelpMenu:helpMenu];
}

// ---- blink timer (shared) -------------------------------------------------
static void restartBlink(void) {
    [gBlink invalidate]; gBlink = nil; gCursorOn = YES;
    if (gBlinkMs > 0) gBlink = [NSTimer scheduledTimerWithTimeInterval:gBlinkMs/1000.0 repeats:YES block:^(NSTimer *_t){
        gCursorOn = !gCursorOn; for (KryptonView *p in gPanes) [p setNeedsDisplay:YES]; }];
    for (KryptonView *p in gPanes) [p setNeedsDisplay:YES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        const char *kp0;
        if (argc > 1) kp0 = argv[1];
        else { NSString *here=[[NSString stringWithUTF8String:argv[0]] stringByDeletingLastPathComponent];
               kp0 = strdup([[here stringByAppendingPathComponent:@"kryoterm"] fileSystemRepresentation]); }

        setenv("TERM_PROGRAM", "kryoterm", 1);
        setenv("TERM_PROGRAM_VERSION", "1.7", 1);
        setenv("TERM", "xterm-256color", 1);
        const char *curPath = getenv("PATH");
        if (!curPath || !strstr(curPath, "/opt/homebrew")) {
            FILE *fp = popen("/bin/zsh -lic 'printf KTPATH=%s\\\\n \"$PATH\"' 2>/dev/null", "r");
            if (fp) { char line[8192];
                while (fgets(line, sizeof line, fp)) { if (strncmp(line,"KTPATH=",7)==0) { line[strcspn(line,"\n")]=0; if (strlen(line)>7) setenv("PATH",line+7,1); break; } }
                pclose(fp); }
        }
        NSString *(^abspath)(const char *) = ^NSString *(const char *p){ NSString *s=[NSString stringWithUTF8String:p];
            return [s hasPrefix:@"/"] ? s : [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:s]; };
        gExecPath = abspath(argv[0]);
        gKPath = abspath(kp0);
        const char *home = getenv("HOME"); if (home) chdir(home);

        gPanes = [NSMutableArray array];
        gController = [[Controller alloc] init];

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        loadConfig();
        applyFont();
        buildMenu();

        NSWindow *win = makeWindow();
        [win center]; [win makeKeyAndOrderFront:nil]; [win orderFrontRegardless];
        [NSApp activateIgnoringOtherApps:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ [NSApp activateIgnoringOtherApps:YES]; [win makeKeyAndOrderFront:nil]; });

        // live light/dark switch
        [[NSDistributedNotificationCenter defaultCenter] addObserverForName:@"AppleInterfaceThemeChangedNotification" object:nil
            queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *_n){
                gCurBg = systemIsDark() ? gBgDark : gBgLight;
                for (NSWindow *w in NSApp.windows) applyWindowChrome(w);
                for (KryptonView *p in gPanes) [p setNeedsDisplay:YES]; }];
        // hot-reload config on focus
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification object:nil
            queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){
                loadConfig(); applyFont();
                for (NSWindow *w in NSApp.windows) applyWindowChrome(w);
                restartBlink();
                KryptonView *p = activePane(); if (p) { [p sendResize]; [p sendScrollbackCap]; [p focusIn]; } }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResignKeyNotification object:nil
            queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){
                for (KryptonView *p in gPanes) [p setNeedsDisplay:YES]; }];

        restartBlink();
        [NSApp run];
        for (KryptonView *p in gPanes) if (p.child > 0) kill(p.child, SIGTERM);
    }
    return 0;
}
