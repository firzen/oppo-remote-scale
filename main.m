#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <libproc.h>
#import <sys/stat.h>

static NSString *const daemonSuffix = @"/O+Connect.app/Contents/Resources/daemon/oplus_remote_service";

static BOOL IsRemoteDaemon(NSNumber *pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    return proc_pidpath(pid.intValue, path, sizeof(path)) > 0 &&
           [@(path) hasSuffix:daemonSuffix];
}

@interface SessionMonitor : NSObject
@property (copy) NSString *directory;
@property (strong) NSDateFormatter *dateFormat;
@property (strong) NSMutableDictionary<NSString *, NSNumber *> *sessions;
@property (strong) NSRegularExpression *pattern;
@property (strong) NSMutableData *partialLine;
@property dev_t device;
@property ino_t inode;
@property uint64_t offset;
@property BOOL manuallyRestored;
@property NSUInteger connectionGeneration;
- (void)poll;
- (void)consumeLine:(NSString *)line;
@end

@implementation SessionMonitor
- (instancetype)init {
    self = [super init];
    if (self) {
        _directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/devicespace"];
        _dateFormat = [NSDateFormatter new];
        _dateFormat.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _dateFormat.timeZone = NSTimeZone.localTimeZone;
        _dateFormat.dateFormat = @"yyyy-MM-dd";
        _sessions = [NSMutableDictionary dictionary];
        _partialLine = [NSMutableData data];
        _pattern = [NSRegularExpression regularExpressionWithPattern:
            @"^\\S+ (\\d+) \\d+ INFO \\[connection_statable\\] set_connection_state from device_id:(\\d+) .* service_type:RemoteControlAndFile to state:(Connected|Idle)$"
            options:0 error:NULL];
    }
    return self;
}

- (NSString *)logPathForDate:(NSDate *)date {
    NSString *name = [[self.dateFormat stringFromDate:date] stringByAppendingString:@"_rc-daemon.log"];
    return [self.directory stringByAppendingPathComponent:name];
}

- (void)consumeLine:(NSString *)line {
    if (![line containsString:@"service_type:RemoteControlAndFile"]) {
        return;
    }
    NSTextCheckingResult *match = [self.pattern firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    if (!match) {
        return;
    }

    NSString *pidText = [line substringWithRange:[match rangeAtIndex:1]];
    NSString *device = [line substringWithRange:[match rangeAtIndex:2]];
    NSString *state = [line substringWithRange:[match rangeAtIndex:3]];
    NSString *key = [NSString stringWithFormat:@"%@/%@", pidText, device];
    NSNumber *pid = @(pidText.intValue);
    if ([state isEqualToString:@"Connected"]) {
        if (IsRemoteDaemon(pid)) {
            if (self.sessions.count == 0) {
                self.connectionGeneration++;

            }
            self.sessions[key] = pid;
        }
    } else {
        [self.sessions removeObjectForKey:key];
        if (self.sessions.count == 0) {
            self.manuallyRestored = NO;
        }
    }
}

- (void)readHandle:(NSFileHandle *)handle {
    struct stat status;
    if (fstat(handle.fileDescriptor, &status) != 0) {
        return;
    }
    if (status.st_dev != self.device || status.st_ino != self.inode ||
        (uint64_t)status.st_size < self.offset) {
        self.device = status.st_dev;
        self.inode = status.st_ino;
        self.offset = 0;
        self.partialLine.length = 0;
    }
    if (self.offset == (uint64_t)status.st_size || ![handle seekToOffset:self.offset error:NULL]) {
        return;
    }
    while (self.offset < (uint64_t)status.st_size) {
        NSUInteger length = (NSUInteger)MIN((uint64_t)65536, (uint64_t)status.st_size - self.offset);
        NSData *bytes = [handle readDataUpToLength:length error:NULL];
        if (bytes.length == 0) {
            break;
        }
        self.offset += bytes.length;
        [self.partialLine appendData:bytes];
        const char *buffer = self.partialLine.bytes;
        NSUInteger start = 0;
        for (NSUInteger index = 0; index < self.partialLine.length; index++) {
            if (buffer[index] == '\n') {
                NSString *line = [[NSString alloc] initWithBytes:buffer + start
                                                        length:index - start
                                                      encoding:NSUTF8StringEncoding];
                [self consumeLine:line];
                start = index + 1;
            }
        }
        if (start > 0) {
            [self.partialLine replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
        }
    }
}

- (void)poll {
    for (NSString *key in self.sessions.allKeys) {
        if (!IsRemoteDaemon(self.sessions[key])) {
            [self.sessions removeObjectForKey:key];
        }
    }
    if (self.sessions.count == 0) {
        self.manuallyRestored = NO;
    }

    NSDate *now = NSDate.date;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:[self logPathForDate:now]];
    if (!handle) {
        NSDate *yesterday = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:now options:0];
        handle = [NSFileHandle fileHandleForReadingAtPath:[self logPathForDate:yesterday]];
    }
    if (handle) {
        [self readHandle:handle];
        [handle closeFile];
    }
}
@end

static CGDisplayModeRef CopyRemoteMode(CGDirectDisplayID screen, CGDisplayModeRef current) {
    size_t width = CGDisplayModeGetWidth(current);
    size_t height = CGDisplayModeGetHeight(current);
    double refresh = CGDisplayModeGetRefreshRate(current);
    NSDictionary *options = @{ (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
    NSArray *modes = CFBridgingRelease(CGDisplayCopyAllDisplayModes(screen, (__bridge CFDictionaryRef)options));
    CGDisplayModeRef best = NULL;
    double bestScore = INFINITY;
    for (id object in modes) {
        CGDisplayModeRef mode = (__bridge CGDisplayModeRef)object;
        size_t w = CGDisplayModeGetWidth(mode);
        size_t h = CGDisplayModeGetHeight(mode);
        if (w >= width || h >= height || w < 800 || h < 600 ||
            fabs((double)w / h - (double)width / height) > 0.02 ||
            !CGDisplayModeIsUsableForDesktopGUI(mode)) continue;

        double score = fabs((double)w - 1280) * 100 + fabs(CGDisplayModeGetRefreshRate(mode) - refresh);
        if (CGDisplayModeGetPixelWidth(mode) <= w) score += 50;
        if (score < bestScore) {
            best = mode;
            bestScore = score;
        }
    }
    return best ? CGDisplayModeRetain(best) : NULL;
}

static NSString *DisplayModeStatus(CGDisplayModeRef mode) {
    return [NSString stringWithFormat:@"当前分辨率 %zu × %zu",
            CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode)];
}

@interface MenuController : NSObject <NSApplicationDelegate>
@property (strong) NSPanel *panel;
@property (strong) NSStatusItem *statusItem;
@property (strong) NSMenuItem *statusMenuLabel;
@property (strong) NSMenuItem *landscapeMenuItem;
@property (strong) NSMenuItem *restoreMenuItem;
@property (strong) NSTimer *windowTimer;
@property (strong) NSButton *landscapeButton;
@property (strong) NSButton *restoreButton;
@property (strong) NSTextField *statusLabel;
@property (copy) NSString *pendingStatus;
@property (strong) SessionMonitor *monitor;
@property (strong) NSTimer *timer;
@property (copy) NSString *modeStatus;
@end

@implementation MenuController {
    CGDirectDisplayID _screen;
    CGDisplayModeRef _originalMode;
    CGDisplayModeRef _remoteMode;
    BOOL _restorePending;
    NSTimeInterval _nextAutomaticCheck;
    NSUInteger _automaticAttempts;
    BOOL _automaticModeRequested;
    NSTimeInterval _lastVisibleWindow;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.monitor = [SessionMonitor new];
    [self createControls];
    [self createStatusMenu];
    self.windowTimer = [NSTimer timerWithTimeInterval:0.2 target:self
                                            selector:@selector(followOppoWindow:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.windowTimer forMode:NSRunLoopCommonModes];
    [self followOppoWindow:self.windowTimer];

    // Leave an already-connected remote session alone when replacing the helper.
    [self.monitor poll];
    self.timer = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(poll:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self refreshStatus];
}

- (void)createStatusMenu {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"display"
                                               accessibilityDescription:@"远控分辨率"];
    self.statusItem.button.toolTip = @"远控分辨率";

    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    self.statusMenuLabel = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    self.statusMenuLabel.enabled = NO;
    [menu addItem:[NSMenuItem separatorItem]];
    self.landscapeMenuItem = [menu addItemWithTitle:@"手机友好" action:@selector(applyManually:) keyEquivalent:@""];
    self.landscapeMenuItem.target = self;
    self.restoreMenuItem = [menu addItemWithTitle:@"恢复" action:@selector(restoreManually:) keyEquivalent:@""];
    self.restoreMenuItem.target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [menu addItemWithTitle:@"退出助手" action:@selector(terminate:) keyEquivalent:@""];
    quit.target = NSApp;
    self.statusItem.menu = menu;
}

- (void)createControls {
    self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 272, 132)
                                            styleMask:NSWindowStyleMaskBorderless |
                                                      NSWindowStyleMaskNonactivatingPanel
                                              backing:NSBackingStoreBuffered defer:NO];
    self.panel.title = @"O+ Connect 分辨率";
    self.panel.floatingPanel = YES;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.hidesOnDeactivate = NO;
    self.panel.opaque = NO;
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary |
                                    NSWindowCollectionBehaviorIgnoresCycle;

    NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:self.panel.contentView.bounds];
    background.material = NSVisualEffectMaterialHUDWindow;
    background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    background.state = NSVisualEffectStateActive;
    background.wantsLayer = YES;
    background.layer.cornerRadius = 16;
    background.layer.masksToBounds = YES;
    self.panel.contentView = background;

    self.landscapeButton = [self controlWithTitle:@"手机友好" symbol:@"display" action:@selector(applyManually:)];
    self.landscapeButton.toolTip = @"手机友好分辨率 1280 × 800";
    self.restoreButton = [self controlWithTitle:@"恢复" symbol:@"arrow.counterclockwise"
                                         action:@selector(restoreManually:)];
    self.restoreButton.toolTip = @"恢复切换前的分辨率";

    NSStackView *buttons = [NSStackView stackViewWithViews:@[self.landscapeButton, self.restoreButton]];
    buttons.distribution = NSStackViewDistributionFillEqually;
    buttons.spacing = 10;
    self.statusLabel = [NSTextField labelWithString:@""];
    self.statusLabel.alignment = NSTextAlignmentCenter;
    self.statusLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    self.statusLabel.textColor = NSColor.secondaryLabelColor;

    NSStackView *controls = [NSStackView stackViewWithViews:@[buttons, self.statusLabel]];
    controls.orientation = NSUserInterfaceLayoutOrientationVertical;
    controls.alignment = NSLayoutAttributeCenterX;
    controls.spacing = 8;
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:controls];
    [NSLayoutConstraint activateConstraints:@[
        [controls.centerXAnchor constraintEqualToAnchor:background.centerXAnchor],
        [controls.centerYAnchor constraintEqualToAnchor:background.centerYAnchor],
        [buttons.widthAnchor constraintEqualToConstant:252],
        [self.statusLabel.widthAnchor constraintEqualToAnchor:buttons.widthAnchor],
        [self.landscapeButton.heightAnchor constraintEqualToConstant:84],
        [self.restoreButton.heightAnchor constraintEqualToAnchor:self.landscapeButton.heightAnchor]
    ]];
}

- (NSButton *)controlWithTitle:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    button.image = [image imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:26 weight:NSFontWeightRegular]];
    button.imagePosition = NSImageAbove;
    button.bezelStyle = NSBezelStyleRegularSquare;
    button.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    return button;
}

- (void)followOppoWindow:(NSTimer *)timer {
    NSRunningApplication *oppo = [NSRunningApplication
        runningApplicationsWithBundleIdentifier:@"com.oplus.devicespace"].firstObject;
    if (!oppo || oppo.hidden) {
        _lastVisibleWindow = 0;
        if (self.panel.isVisible) [self.panel orderOut:nil];
        return;
    }

    NSArray<NSDictionary *> *windows = CFBridgingRelease(
        CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                   kCGNullWindowID));
    NSMutableArray<NSValue *> *coveringWindows = [NSMutableArray array];
    CGRect bounds = CGRectNull;
    for (NSDictionary *window in windows) {
        if ([window[(__bridge NSString *)kCGWindowLayer] intValue] != 0 ||
            [window[(__bridge NSString *)kCGWindowAlpha] doubleValue] == 0) continue;
        NSDictionary *windowBounds = window[(__bridge NSString *)kCGWindowBounds];
        CGRect candidate;
        if (!windowBounds ||
            !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)windowBounds, &candidate)) continue;

        if ([window[(__bridge NSString *)kCGWindowOwnerPID] intValue] == oppo.processIdentifier) {
            if (CGRectGetWidth(candidate) < 300 || CGRectGetHeight(candidate) < 150) continue;
            BOOL covered = NO;
            for (NSValue *frame in coveringWindows) {
                if (CGRectContainsRect(frame.rectValue, candidate)) {
                    covered = YES;
                    break;
                }
            }
            if (!covered) {
                bounds = candidate;
                break;
            }
        } else {
            [coveringWindows addObject:[NSValue valueWithRect:candidate]];
        }
    }

    NSArray<NSScreen *> *screens = NSScreen.screens;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (CGRectIsNull(bounds) || screens.count == 0) {
        // Core Graphics briefly drops windows during a display mode change.
        if (self.panel.isVisible && now - _lastVisibleWindow >= 0.8) [self.panel orderOut:nil];
        return;
    }
    NSRect window = NSMakeRect(CGRectGetMinX(bounds), NSMaxY(screens.firstObject.frame) - CGRectGetMaxY(bounds),
                               CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    NSScreen *host = screens.firstObject;
    CGFloat greatestOverlap = 0;
    for (NSScreen *screen in screens) {
        NSRect overlap = NSIntersectionRect(screen.frame, window);
        CGFloat area = NSWidth(overlap) * NSHeight(overlap);
        if (area > greatestOverlap) {
            greatestOverlap = area;
            host = screen;
        }
    }
    if (!greatestOverlap) {
        if (self.panel.isVisible) [self.panel orderOut:nil];
        return;
    }
    _lastVisibleWindow = now;
    NSRect visible = host.visibleFrame;
    NSSize size = self.panel.frame.size;
    CGFloat gap = 8;
    CGFloat x = NSMaxX(window) + gap;
    if (x + size.width > NSMaxX(visible)) {
        x = NSMinX(window) - size.width - gap;
        if (x < NSMinX(visible)) x = NSMaxX(window) - size.width - gap;
    }
    x = MAX(NSMinX(visible), MIN(x, NSMaxX(visible) - size.width));
    CGFloat y = MAX(NSMinY(visible), MIN(NSMaxY(window) - size.height - gap,
                                        NSMaxY(visible) - size.height));
    NSPoint origin = NSMakePoint(x, y);
    if (!NSEqualPoints(origin, self.panel.frame.origin)) [self.panel setFrameOrigin:origin];
    if (!self.panel.isVisible) [self.panel orderFrontRegardless];
}

- (void)poll:(NSTimer *)timer {
    if (self.pendingStatus) return;
    BOOL wasConnected = self.monitor.sessions.count > 0;
    NSUInteger generation = self.monitor.connectionGeneration;
    [self.monitor poll];
    BOOL connected = self.monitor.sessions.count > 0;
    if (connected && self.monitor.connectionGeneration != generation && !self.monitor.manuallyRestored) {
        // O+ Connect can reconfigure the display while starting the session.
        _nextAutomaticCheck = NSProcessInfo.processInfo.systemUptime + 5;
        _automaticAttempts = 0;
        _automaticModeRequested = NO;
    } else if (!connected && wasConnected) {
        _nextAutomaticCheck = 0;
        [self restoreMode:NO];
    }
    if (connected && _nextAutomaticCheck && !self.monitor.manuallyRestored &&
        NSProcessInfo.processInfo.systemUptime >= _nextAutomaticCheck) {
        [self advanceAutomaticSwitch];
    }
    [self refreshStatus];
}

- (void)advanceAutomaticSwitch {
    _nextAutomaticCheck = 0;
    if (_restorePending) return;

    if (_automaticModeRequested && _originalMode) {
        CGDisplayModeRef current = CGDisplayCopyDisplayMode(_screen);
        if (current) {
            BOOL bouncedBack = CFEqual(current, _originalMode);
            self.modeStatus = DisplayModeStatus(current);
            CGDisplayModeRelease(current);
            if (!bouncedBack) return;
        }
    }

    if (_automaticAttempts >= 2) return;
    _automaticAttempts++;
    _automaticModeRequested = YES;
    [self applyRemoteModeAllowingRetry:YES];
    _nextAutomaticCheck = NSProcessInfo.processInfo.systemUptime + 1;
}

- (void)refreshStatus {
    BOOL busy = self.pendingStatus != nil;
    self.statusLabel.stringValue = self.pendingStatus ?: (self.modeStatus ?: @"当前为原分辨率");
    self.panel.accessibilityLabel = self.statusLabel.stringValue;
    self.landscapeButton.enabled = !busy && _originalMode == NULL;
    self.restoreButton.enabled = !busy && _originalMode != NULL;
    self.statusMenuLabel.title = self.statusLabel.stringValue;
    self.landscapeMenuItem.enabled = self.landscapeButton.enabled;
    self.restoreMenuItem.enabled = self.restoreButton.enabled;
}

- (void)performManualChangeRestoring:(BOOL)restoring {
    if (self.pendingStatus || restoring != (_originalMode != NULL)) return;

    _nextAutomaticCheck = 0;
    self.pendingStatus = restoring ? @"正在恢复原分辨率…" : @"正在切换到手机友好模式…";
    [self refreshStatus];
    [self.panel displayIfNeeded];

    // Present the feedback before the synchronous system display transaction.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        self.monitor.manuallyRestored = restoring && self.monitor.sessions.count > 0;
        if (restoring) {
            [self restoreMode:YES];
        } else {
            [self applyRemoteMode];
        }
        // WindowServer can temporarily omit the host after changing display mode.
        if (self.panel.isVisible) _lastVisibleWindow = NSProcessInfo.processInfo.systemUptime;
        self.pendingStatus = nil;
        [self refreshStatus];
    });
}

- (void)applyManually:(id)sender {
    [self performManualChangeRestoring:NO];
}

- (void)applyRemoteMode {
    [self applyRemoteModeAllowingRetry:NO];
}

- (void)applyRemoteModeAllowingRetry:(BOOL)retry {
    if (_originalMode && !retry) return;
    CGDirectDisplayID screen = _originalMode ? _screen : CGMainDisplayID();
    CGDisplayModeRef original = _originalMode
        ? CGDisplayModeRetain(_originalMode) : CGDisplayCopyDisplayMode(screen);
    if (!original) {
        self.modeStatus = @"无法读取当前显示模式";
        return;
    }
    CGDisplayModeRef remote = CopyRemoteMode(screen, original);
    if (!remote || CGDisplaySetDisplayMode(screen, remote, NULL) != kCGErrorSuccess) {
        if (remote) CGDisplayModeRelease(remote);
        CGDisplayModeRelease(original);
        self.modeStatus = @"当前显示器无法切换到远控分辨率";
        return;
    }
    if (_originalMode) CGDisplayModeRelease(_originalMode);
    if (_remoteMode) CGDisplayModeRelease(_remoteMode);
    _screen = screen;
    _originalMode = original;
    _remoteMode = remote;

    CGDisplayModeRef applied = CGDisplayCopyDisplayMode(screen);
    self.modeStatus = applied ? DisplayModeStatus(applied) : @"已请求切换，实际分辨率暂不可读";
    if (applied) CGDisplayModeRelease(applied);
}

- (void)restoreMode:(BOOL)manual {
    if (!_originalMode) return;
    if (!CGDisplayIsOnline(_screen)) {
        self.modeStatus = @"显示器暂不可用，可重试恢复";
        return;
    }
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(_screen);
    if (!current) {
        self.modeStatus = @"无法读取分辨率，可重试恢复";
        return;
    }

    BOOL alreadyRestored = CFEqual(current, _originalMode);
    BOOL shouldRestore = manual || _restorePending || !_remoteMode || CFEqual(current, _remoteMode);
    if (!alreadyRestored && shouldRestore) {
        CGDisplayModeRelease(current);
        _restorePending = YES;
        if (CGDisplaySetDisplayMode(_screen, _originalMode, NULL) != kCGErrorSuccess) {
            self.modeStatus = @"恢复失败，可重试";
            return;
        }

        current = CGDisplayCopyDisplayMode(_screen);
        if (!current || !CFEqual(current, _originalMode)) {
            if (current) CGDisplayModeRelease(current);
            self.modeStatus = @"尚未确认恢复，可重试";
            return;
        }
    }

    self.modeStatus = DisplayModeStatus(current);
    CGDisplayModeRelease(current);
    CGDisplayModeRelease(_originalMode);
    if (_remoteMode) CGDisplayModeRelease(_remoteMode);
    _originalMode = NULL;
    _remoteMode = NULL;
    _restorePending = NO;
    _screen = kCGNullDirectDisplay;
}

- (void)restoreManually:(id)sender {
    [self performManualChangeRestoring:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.timer invalidate];
    self.timer = nil;
    [self.windowTimer invalidate];
    self.windowTimer = nil;
    [self.panel orderOut:nil];
    [self restoreMode:NO];
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        MenuController *controller = [MenuController new];
        app.delegate = controller;
        [app run];
    }
    return 0;
}
