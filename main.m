#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/graphics/IOGraphicsTypes.h>
#import <libproc.h>
#import <sys/stat.h>

static NSString *const daemonSuffix = @"/O+Connect.app/Contents/Resources/daemon/oplus_remote_service";
static const size_t preferredRemoteWidth = 1152;
static const size_t preferredRemoteHeight = 720;

static BOOL IsRemoteDaemon(NSNumber *pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    return proc_pidpath(pid.intValue, path, sizeof(path)) > 0 &&
           [@(path) hasSuffix:daemonSuffix];
}

@interface SessionLogCursor : NSObject
@property (strong) NSMutableData *partialLine;
@property (strong) NSMutableDictionary<NSString *, NSString *> *lastTimestamps;
@property dev_t device;
@property ino_t inode;
@property uint64_t offset;
@end

@implementation SessionLogCursor
- (instancetype)init {
    self = [super init];
    if (self) {
        _partialLine = [NSMutableData data];
        _lastTimestamps = [NSMutableDictionary dictionary];
    }
    return self;
}
@end

@interface SessionMonitor : NSObject
@property (copy) NSString *directory;
@property (strong) NSDateFormatter *dateFormat;
@property (strong) NSISO8601DateFormatter *timestampFormat;
@property (strong) NSMutableDictionary<NSString *, NSNumber *> *sessions;
@property (strong) NSRegularExpression *pattern;
@property (strong) NSMutableDictionary<NSString *, SessionLogCursor *> *cursors;
@property BOOL manuallyRestored;
@property NSUInteger connectionGeneration;
- (void)poll;
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
        _timestampFormat = [NSISO8601DateFormatter new];
        _timestampFormat.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                                         NSISO8601DateFormatWithFractionalSeconds;
        _sessions = [NSMutableDictionary dictionary];
        _cursors = [NSMutableDictionary dictionary];
        _pattern = [NSRegularExpression regularExpressionWithPattern:
            @"^(\\S+) (\\d+) \\d+ INFO \\[connection_statable\\] set_connection_state from device_id:(\\d+) .* service_type:RemoteControlAndFile to state:(Connected|Idle)$"
            options:0 error:NULL];
    }
    return self;
}

- (NSString *)logPathForDate:(NSDate *)date {
    NSString *name = [[self.dateFormat stringFromDate:date] stringByAppendingString:@"_rc-daemon.log"];
    return [self.directory stringByAppendingPathComponent:name];
}

- (void)consumeLine:(NSString *)line cursor:(SessionLogCursor *)cursor {
    if (![line containsString:@"service_type:RemoteControlAndFile"]) {
        return;
    }
    NSTextCheckingResult *match = [self.pattern firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    if (!match) {
        return;
    }

    NSString *timestamp = [line substringWithRange:[match rangeAtIndex:1]];
    NSString *pidText = [line substringWithRange:[match rangeAtIndex:2]];
    NSString *device = [line substringWithRange:[match rangeAtIndex:3]];
    NSString *state = [line substringWithRange:[match rangeAtIndex:4]];
    NSString *key = [NSString stringWithFormat:@"%@/%@", pidText, device];
    NSNumber *pid = @(pidText.intValue);
    // A previous day's log can still receive events after the new file opens.
    for (SessionLogCursor *other in self.cursors.objectEnumerator) {
        NSString *last = other == cursor ? nil : other.lastTimestamps[key];
        if (!last) continue;

        NSDate *eventDate = [self.timestampFormat dateFromString:timestamp];
        NSDate *lastDate = [self.timestampFormat dateFromString:last];
        NSComparisonResult order = eventDate && lastDate ? [eventDate compare:lastDate] : NSOrderedSame;
        if (order == NSOrderedSame) order = [timestamp compare:last options:NSLiteralSearch];
        if (order == NSOrderedAscending) return;
    }
    cursor.lastTimestamps[key] = timestamp;

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

- (void)readHandle:(NSFileHandle *)handle cursor:(SessionLogCursor *)cursor {
    struct stat status;
    if (fstat(handle.fileDescriptor, &status) != 0) {
        return;
    }
    if (status.st_dev != cursor.device || status.st_ino != cursor.inode ||
        (uint64_t)status.st_size < cursor.offset) {
        cursor.device = status.st_dev;
        cursor.inode = status.st_ino;
        cursor.offset = 0;
        cursor.partialLine.length = 0;
    }
    if (cursor.offset == (uint64_t)status.st_size || ![handle seekToOffset:cursor.offset error:NULL]) {
        return;
    }
    while (cursor.offset < (uint64_t)status.st_size) {
        NSUInteger length = (NSUInteger)MIN((uint64_t)65536, (uint64_t)status.st_size - cursor.offset);
        NSData *bytes = [handle readDataUpToLength:length error:NULL];
        if (bytes.length == 0) {
            break;
        }
        cursor.offset += bytes.length;
        [cursor.partialLine appendData:bytes];
        const char *buffer = cursor.partialLine.bytes;
        NSUInteger start = 0;
        for (NSUInteger index = 0; index < cursor.partialLine.length; index++) {
            if (buffer[index] == '\n') {
                NSString *line = [[NSString alloc] initWithBytes:buffer + start
                                                        length:index - start
                                                      encoding:NSUTF8StringEncoding];
                [self consumeLine:line cursor:cursor];
                start = index + 1;
            }
        }
        if (start > 0) {
            [cursor.partialLine replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
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
    NSDate *yesterday = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:now options:0];
    NSArray<NSString *> *paths = @[[self logPathForDate:yesterday], [self logPathForDate:now]];
    for (NSString *path in self.cursors.allKeys) {
        if (![paths containsObject:path]) [self.cursors removeObjectForKey:path];
    }
    for (NSString *path in paths) {
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
        if (!handle) continue;

        SessionLogCursor *cursor = self.cursors[path];
        if (!cursor) {
            cursor = [SessionLogCursor new];
            self.cursors[path] = cursor;
        }
        [self readHandle:handle cursor:cursor];
        [handle closeFile];
    }
}
@end

static BOOL IsPreferredRemoteMode(CGDisplayModeRef mode) {
    return mode && CGDisplayModeGetWidth(mode) == preferredRemoteWidth &&
           CGDisplayModeGetHeight(mode) == preferredRemoteHeight;
}

static CGDisplayModeRef CopyFactoryRestoreMode(CGDirectDisplayID screen, CGDisplayModeRef current) {
    if (!IsPreferredRemoteMode(current) || !CGDisplayIsBuiltin(screen)) return NULL;

    NSDictionary *options = @{ (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
    NSArray *modes = CFBridgingRelease(CGDisplayCopyAllDisplayModes(screen, (__bridge CFDictionaryRef)options));
    CGDisplayModeRef best = NULL;
    double bestDifference = INFINITY;
    for (id object in modes) {
        CGDisplayModeRef mode = (__bridge CGDisplayModeRef)object;
        if (!(CGDisplayModeGetIOFlags(mode) & kDisplayModeDefaultFlag) ||
            IsPreferredRemoteMode(mode) || !CGDisplayModeIsUsableForDesktopGUI(mode)) continue;

        double difference = fabs(CGDisplayModeGetRefreshRate(mode) - CGDisplayModeGetRefreshRate(current));
        if (difference < bestDifference) {
            best = mode;
            bestDifference = difference;
        }
    }
    return best ? CGDisplayModeRetain(best) : NULL;
}

static CGDisplayModeRef CopyRemoteMode(CGDirectDisplayID screen, CGDisplayModeRef current) {
    if (IsPreferredRemoteMode(current)) return NULL;

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

        double score = fabs((double)w - preferredRemoteWidth) * 100 + fabs(CGDisplayModeGetRefreshRate(mode) - refresh);
        // Prefer the standard pixel mode at the target size for remote capture.
        BOOL hiDPI = CGDisplayModeGetPixelWidth(mode) > w;
        if (IsPreferredRemoteMode(mode) ? hiDPI : !hiDPI) score += 50;
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

static BOOL SessionIsUnlocked(NSDictionary *session) {
    // WindowServer omits the lock flag in an unlocked session.
    id locked = session[@"CGSSessionScreenIsLocked"];
    return [session[(__bridge NSString *)kCGSessionLoginDoneKey] isEqual:@YES] &&
           [session[(__bridge NSString *)kCGSessionOnConsoleKey] isEqual:@YES] &&
           (!locked || [locked isEqual:@NO]);
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
@property (strong) NSProgressIndicator *statusSpinner;
@property (strong) NSPanel *feedbackPanel;
@property (strong) NSTextField *feedbackLabel;
@property (strong) NSProgressIndicator *feedbackSpinner;
@property (strong) NSTimer *feedbackDismissTimer;
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
    BOOL _manualRestoreRequired;
    BOOL _observedConnection;
    NSUInteger _observedConnectionGeneration;
    NSTimeInterval _nextAutomaticCheck;
    BOOL _waitingForDesktop;
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
    _observedConnection = self.monitor.sessions.count > 0;
    _observedConnectionGeneration = self.monitor.connectionGeneration;
    self.timer = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(poll:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
                                                        selector:@selector(desktopApplicationDidActivate:)
                                                            name:NSWorkspaceDidActivateApplicationNotification
                                                          object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(displayParametersDidChange:)
                                              name:NSApplicationDidChangeScreenParametersNotification
                                            object:nil];
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
    [self.landscapeButton setButtonType:NSButtonTypeToggle];
    self.landscapeButton.alternateTitle = @"手机友好";
    NSImage *selectedImage = [NSImage imageWithSystemSymbolName:@"checkmark.circle.fill"
                                       accessibilityDescription:nil];
    self.landscapeButton.alternateImage = [selectedImage imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:26 weight:NSFontWeightRegular]];
    self.landscapeButton.toolTip = [NSString stringWithFormat:@"手机友好分辨率 %zu × %zu",
                                    preferredRemoteWidth, preferredRemoteHeight];
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

    self.statusSpinner = [self makeStatusSpinner];
    NSStackView *status = [NSStackView stackViewWithViews:@[self.statusSpinner, self.statusLabel]];
    status.alignment = NSLayoutAttributeCenterY;
    status.spacing = 6;

    NSStackView *controls = [NSStackView stackViewWithViews:@[buttons, status]];
    controls.orientation = NSUserInterfaceLayoutOrientationVertical;
    controls.alignment = NSLayoutAttributeCenterX;
    controls.spacing = 8;
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:controls];
    [NSLayoutConstraint activateConstraints:@[
        [controls.centerXAnchor constraintEqualToAnchor:background.centerXAnchor],
        [controls.centerYAnchor constraintEqualToAnchor:background.centerYAnchor],
        [buttons.widthAnchor constraintEqualToConstant:252],
        [status.widthAnchor constraintLessThanOrEqualToAnchor:buttons.widthAnchor],
        [self.statusSpinner.widthAnchor constraintEqualToConstant:14],
        [self.statusSpinner.heightAnchor constraintEqualToConstant:14],
        [self.landscapeButton.heightAnchor constraintEqualToConstant:84],
        [self.restoreButton.heightAnchor constraintEqualToAnchor:self.landscapeButton.heightAnchor]
    ]];
}

- (NSProgressIndicator *)makeStatusSpinner {
    NSProgressIndicator *spinner = [NSProgressIndicator new];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeSmall;
    spinner.indeterminate = YES;
    spinner.usesThreadedAnimation = YES;
    spinner.hidden = YES;
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    return spinner;
}

- (void)createDesktopFeedback {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 480, 96)
                                               styleMask:NSWindowStyleMaskBorderless |
                                                         NSWindowStyleMaskNonactivatingPanel
                                                 backing:NSBackingStoreBuffered defer:NO];
    panel.level = NSFloatingWindowLevel;
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    panel.hasShadow = YES;
    panel.ignoresMouseEvents = YES;
    panel.hidesOnDeactivate = NO;
    panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace |
                               NSWindowCollectionBehaviorFullScreenAuxiliary |
                               NSWindowCollectionBehaviorIgnoresCycle;

    NSView *background = panel.contentView;
    background.wantsLayer = YES;
    background.layer.backgroundColor = [NSColor colorWithWhite:0.075 alpha:0.98].CGColor;
    background.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.25].CGColor;
    background.layer.borderWidth = 1;
    background.layer.cornerRadius = 20;

    self.feedbackLabel = [NSTextField labelWithString:@""];
    self.feedbackLabel.font = [NSFont systemFontOfSize:28 weight:NSFontWeightBold];
    self.feedbackLabel.textColor = NSColor.whiteColor;
    self.feedbackSpinner = [self makeStatusSpinner];
    self.feedbackSpinner.controlSize = NSControlSizeRegular;
    NSStackView *status = [NSStackView stackViewWithViews:@[self.feedbackSpinner, self.feedbackLabel]];
    status.spacing = 14;
    status.alignment = NSLayoutAttributeCenterY;
    status.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:status];
    [NSLayoutConstraint activateConstraints:@[
        [status.centerXAnchor constraintEqualToAnchor:background.centerXAnchor],
        [status.centerYAnchor constraintEqualToAnchor:background.centerYAnchor],
        [status.widthAnchor constraintLessThanOrEqualToConstant:440],
        [self.feedbackSpinner.widthAnchor constraintEqualToConstant:28],
        [self.feedbackSpinner.heightAnchor constraintEqualToConstant:28]
    ]];
    self.feedbackPanel = panel;
}

- (void)positionDesktopFeedback:(NSNotification *)notification {
    NSScreen *screen = NSScreen.screens.firstObject;
    if (!screen || !self.feedbackPanel) return;
    NSRect visible = screen.visibleFrame;
    NSSize size = self.feedbackPanel.frame.size;
    [self.feedbackPanel setFrameOrigin:NSMakePoint(NSMidX(visible) - size.width / 2,
                                                   NSMaxY(visible) - size.height - 44)];
}

- (void)displayParametersDidChange:(NSNotification *)notification {
    [self positionDesktopFeedback:notification];
    [self refreshStatus];
}

- (void)hideDesktopFeedback {
    [self.feedbackDismissTimer invalidate];
    self.feedbackDismissTimer = nil;
    [self.feedbackSpinner stopAnimation:nil];
    [self.feedbackPanel orderOut:nil];
}

- (void)showDesktopFeedback:(NSString *)status busy:(BOOL)busy {
    [self hideDesktopFeedback];
    if (!self.feedbackPanel) [self createDesktopFeedback];
    self.feedbackLabel.stringValue = status;
    self.feedbackPanel.accessibilityLabel = status;
    self.feedbackSpinner.hidden = !busy;
    if (busy) [self.feedbackSpinner startAnimation:nil];
    [self positionDesktopFeedback:nil];
    [self.feedbackPanel orderFrontRegardless];
    [self.feedbackPanel displayIfNeeded];
    if (!busy) {
        self.feedbackDismissTimer = [NSTimer timerWithTimeInterval:2.5 repeats:NO block:^(NSTimer *timer) {
            [self hideDesktopFeedback];
        }];
        [NSRunLoop.mainRunLoop addTimer:self.feedbackDismissTimer forMode:NSRunLoopCommonModes];
    }
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
    [self.monitor poll];
    BOOL connected = self.monitor.sessions.count > 0;
    NSUInteger generation = self.monitor.connectionGeneration;
    BOOL newConnection = connected && generation != _observedConnectionGeneration;
    BOOL disconnected = !connected && _observedConnection;
    // The deferred switch also reads the log. Handle its observations here.
    _observedConnection = connected;
    _observedConnectionGeneration = generation;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (newConnection && !self.monitor.manuallyRestored) {
        // O+ Connect can reconfigure the display while starting the session.
        _nextAutomaticCheck = now + 5;
        _waitingForDesktop = NO;
        _automaticAttempts = 0;
        _automaticModeRequested = NO;
    } else if (disconnected) {
        _nextAutomaticCheck = 0;
        _waitingForDesktop = NO;
        [self prepareFactoryRestoreMode];
        if (_originalMode && [self desktopIsReady]) {
            [self performDisplayChangeWithStatus:@"正在恢复原分辨率…" desktopFeedback:YES change:^BOOL{
                [self restoreMode:NO];
                return YES;
            }];
        } else {
            [self restoreMode:NO];
        }
    }
    if (connected && _nextAutomaticCheck && !self.monitor.manuallyRestored &&
        [self automaticSwitchIsDueAt:now]) {
        [self advanceAutomaticSwitch];
    }
    [self refreshStatus];
}

- (BOOL)desktopIsReady {
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    if (!SessionIsUnlocked(session)) return NO;

    NSRunningApplication *frontmost = NSWorkspace.sharedWorkspace.frontmostApplication;
    return frontmost && ![frontmost.bundleIdentifier isEqualToString:@"com.apple.loginwindow"];
}

- (BOOL)automaticSwitchIsDueAt:(NSTimeInterval)now {
    if (![self desktopIsReady]) {
        _waitingForDesktop = !_automaticModeRequested;
        return NO;
    }

    return _waitingForDesktop || now >= _nextAutomaticCheck;
}

- (void)desktopApplicationDidActivate:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_waitingForDesktop && self->_nextAutomaticCheck) [self poll:nil];
    });
}

- (void)advanceAutomaticSwitch {
    NSTimeInterval scheduledCheck = _nextAutomaticCheck;
    NSTimeInterval startupCheck = _automaticModeRequested ? 0 : scheduledCheck;
    _nextAutomaticCheck = 0;
    _waitingForDesktop = NO;
    if (_restorePending || _manualRestoreRequired) return;

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
    NSString *status = [self switchingStatus];
    if (!status) return;

    NSUInteger generation = self.monitor.connectionGeneration;
    [self performDisplayChangeWithStatus:status desktopFeedback:YES change:^BOOL{
        [self.monitor poll];
        if (!self.monitor.sessions.count || self.monitor.connectionGeneration != generation) return NO;

        // The screen can relock while AppKit presents the feedback.
        if (![self desktopIsReady]) {
            _waitingForDesktop = !_automaticModeRequested;
            _nextAutomaticCheck = scheduledCheck;
            return NO;
        }
        _automaticAttempts++;
        _automaticModeRequested = YES;
        [self applyRemoteModeAllowingRetry:YES];
        // When unlock allowed an early switch, verify again after O+ Connect has settled.
        _nextAutomaticCheck = MAX(NSProcessInfo.processInfo.systemUptime, startupCheck) + 1;
        return YES;
    }];
}

- (void)refreshStatus {
    BOOL busy = self.pendingStatus != nil;
    CGDirectDisplayID screen = _originalMode ? _screen : CGMainDisplayID();
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(screen);
    BOOL remoteSelected = IsPreferredRemoteMode(current) ||
                          (current && _remoteMode && CFEqual(current, _remoteMode));
    NSControlStateValue remoteState = remoteSelected ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *status = self.modeStatus;
    if (current && (!status || (remoteSelected && !_originalMode))) status = DisplayModeStatus(current);
    CGDisplayModeRef defaultMode = !busy && !_originalMode ? CopyFactoryRestoreMode(screen, current) : NULL;
    BOOL canRestore = _originalMode || defaultMode;
    if (defaultMode) CGDisplayModeRelease(defaultMode);
    if (current) CGDisplayModeRelease(current);

    if (busy && self.statusSpinner.hidden) {
        self.statusSpinner.hidden = NO;
        [self.statusSpinner startAnimation:nil];
    } else if (!busy && !self.statusSpinner.hidden) {
        [self.statusSpinner stopAnimation:nil];
        self.statusSpinner.hidden = YES;
    }
    self.statusLabel.stringValue = self.pendingStatus ?: (status ?: @"无法读取当前分辨率");
    self.panel.accessibilityLabel = self.statusLabel.stringValue;
    self.landscapeButton.state = remoteState;
    self.landscapeButton.enabled = !busy && (remoteSelected || _originalMode == NULL);
    self.restoreButton.enabled = !busy && canRestore;
    self.statusMenuLabel.title = self.statusLabel.stringValue;
    self.landscapeMenuItem.state = remoteState;
    self.landscapeMenuItem.enabled = self.landscapeButton.enabled;
    self.restoreMenuItem.enabled = self.restoreButton.enabled;
}

- (NSString *)switchingStatus {
    CGDirectDisplayID screen = _originalMode ? _screen : CGMainDisplayID();
    CGDisplayModeRef original = _originalMode
        ? CGDisplayModeRetain(_originalMode) : CGDisplayCopyDisplayMode(screen);
    if (IsPreferredRemoteMode(original)) {
        self.modeStatus = DisplayModeStatus(original);
        CGDisplayModeRelease(original);
        return nil;
    }
    CGDisplayModeRef target = original ? CopyRemoteMode(screen, original) : NULL;
    if (original) CGDisplayModeRelease(original);
    if (!target) return @"正在切换到手机友好分辨率…";

    NSString *status = [NSString stringWithFormat:@"正在切换到 %zu × %zu…",
                        CGDisplayModeGetWidth(target), CGDisplayModeGetHeight(target)];
    CGDisplayModeRelease(target);
    return status;
}

- (void)performDisplayChangeWithStatus:(NSString *)status
                       desktopFeedback:(BOOL)desktopFeedback
                                 change:(BOOL (^)(void))change {
    self.pendingStatus = status;
    [self refreshStatus];
    [self.panel displayIfNeeded];
    if (desktopFeedback) [self showDesktopFeedback:status busy:YES];

    // Let AppKit present the status before the synchronous system display transaction.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        BOOL ranChange = change();
        // WindowServer can temporarily omit the host after changing display mode.
        if (self.panel.isVisible) _lastVisibleWindow = NSProcessInfo.processInfo.systemUptime;
        self.pendingStatus = nil;
        [self refreshStatus];
        if (desktopFeedback && ranChange && [self desktopIsReady] && self.modeStatus) {
            [self showDesktopFeedback:self.modeStatus busy:NO];
        } else if (desktopFeedback) {
            [self hideDesktopFeedback];
        }
    });
}

- (void)prepareFactoryRestoreMode {
    if (_originalMode) return;

    CGDirectDisplayID screen = CGMainDisplayID();
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(screen);
    CGDisplayModeRef fallback = CopyFactoryRestoreMode(screen, current);
    if (!fallback) {
        if (current) CGDisplayModeRelease(current);
        return;
    }

    _screen = screen;
    _originalMode = fallback;
    _remoteMode = current;
}

- (void)performManualChangeRestoring:(BOOL)restoring {
    if (self.pendingStatus || (!restoring && _originalMode)) return;
    if (restoring) {
        [self prepareFactoryRestoreMode];
        if (!_originalMode) {
            [self refreshStatus];
            return;
        }
    }

    _nextAutomaticCheck = 0;
    NSString *status = restoring ? @"正在恢复原分辨率…" : [self switchingStatus];
    if (!status) {
        [self refreshStatus];
        return;
    }
    [self performDisplayChangeWithStatus:status desktopFeedback:!self.panel.isVisible change:^BOOL{
        self.monitor.manuallyRestored = restoring && self.monitor.sessions.count > 0;
        if (restoring) {
            [self restoreMode:YES];
        } else {
            [self applyRemoteMode];
        }
        return YES;
    }];
}

- (void)applyManually:(id)sender {
    if (_originalMode) {
        [self refreshStatus];
        return;
    }
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
    if (IsPreferredRemoteMode(original)) {
        self.modeStatus = DisplayModeStatus(original);
        CGDisplayModeRelease(original);
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
    if (!alreadyRestored && !shouldRestore) {
        _manualRestoreRequired = YES;
        self.modeStatus = [DisplayModeStatus(current) stringByAppendingString:@"，可手动恢复"];
        CGDisplayModeRelease(current);
        return;
    }

    if (!alreadyRestored) {
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
    _manualRestoreRequired = NO;
    _screen = kCGNullDirectDisplay;
}

- (void)restoreManually:(id)sender {
    [self performManualChangeRestoring:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self
                                                               name:NSWorkspaceDidActivateApplicationNotification
                                                             object:nil];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.timer invalidate];
    self.timer = nil;
    [self.windowTimer invalidate];
    self.windowTimer = nil;
    [self.panel orderOut:nil];
    [self hideDesktopFeedback];
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
