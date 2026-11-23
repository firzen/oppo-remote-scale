#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ColorSync/ColorSync.h>
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

static NSArray *RemoteDisplayModes(CGDirectDisplayID screen) {
    NSDictionary *options = @{ (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
    return CFBridgingRelease(CGDisplayCopyAllDisplayModes(screen, (__bridge CFDictionaryRef)options));
}

static CGDisplayModeRef CopyRemoteMode(CGDisplayModeRef current, NSArray *modes) {
    if (IsPreferredRemoteMode(current)) return NULL;

    size_t width = CGDisplayModeGetWidth(current);
    size_t height = CGDisplayModeGetHeight(current);
    double refresh = CGDisplayModeGetRefreshRate(current);
    CGDisplayModeRef best = NULL;
    double bestScore = INFINITY;
    NSUInteger bestTier = NSUIntegerMax;
    for (id object in modes) {
        CGDisplayModeRef mode = (__bridge CGDisplayModeRef)object;
        size_t w = CGDisplayModeGetWidth(mode);
        size_t h = CGDisplayModeGetHeight(mode);
        BOOL portrait = height > width;
        if (w > width || h > height || (w == width && h == height) ||
            w < (portrait ? 600 : 800) || h < (portrait ? 800 : 600) ||
            !CGDisplayModeIsUsableForDesktopGUI(mode)) continue;

        double aspectDifference = fabs(((double)w / h) / ((double)width / height) - 1);
        if (aspectDifference > 0.10) continue;
        double targetWidth = portrait ? preferredRemoteWidth * (double)width / height : preferredRemoteWidth;
        double distance = fabs((double)w - targetWidth);
        NSUInteger tier = aspectDifference <= 0.015 ? (distance <= targetWidth * 0.05 ? 0 : 1) : 2;
        double score = distance + fabs(CGDisplayModeGetRefreshRate(mode) - refresh);
        if (tier == 2) score += aspectDifference * targetWidth;
        BOOL hiDPI = CGDisplayModeGetPixelWidth(mode) > w;
        if (IsPreferredRemoteMode(mode) ? hiDPI : !hiDPI) score += 0.5;
        if (tier < bestTier || (tier == bestTier && score < bestScore)) {
            bestTier = tier;
            best = mode;
            bestScore = score;
        }
    }
    return best ? CGDisplayModeRetain(best) : NULL;
}

static NSString *DisplayUUID(CGDirectDisplayID screen) {
    if (screen == kCGNullDirectDisplay) return nil;
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(screen);
    if (!uuid) return nil;
    NSString *key = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
    CFRelease(uuid);
    return key;
}

static CGDirectDisplayID OnlineDisplayForUUID(NSString *key) {
    CFUUIDRef uuid = CFUUIDCreateFromString(NULL, (__bridge CFStringRef)key);
    if (!uuid) return kCGNullDirectDisplay;
    CGDirectDisplayID screen = CGDisplayGetDisplayIDFromUUID(uuid);
    CFRelease(uuid);
    return screen && CGDisplayIsOnline(screen) && [DisplayUUID(screen) isEqualToString:key]
        ? screen : kCGNullDirectDisplay;
}

@interface DisplayRestoreState : NSObject
@property (assign) CGDisplayModeRef originalMode;
@property (assign) CGDisplayModeRef remoteMode;
@property BOOL restorePending;
@property BOOL manualRestoreRequired;
@property BOOL restoreOnReconnect;
@end

@implementation DisplayRestoreState
- (void)dealloc {
    if (_originalMode) CGDisplayModeRelease(_originalMode);
    if (_remoteMode) CGDisplayModeRelease(_remoteMode);
}
@end

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
    NSMutableDictionary<NSString *, DisplayRestoreState *> *_displayStates;
    NSString *_observedMainDisplay;
    BOOL _observedConnection;
    NSUInteger _observedConnectionGeneration;
    NSTimeInterval _nextAutomaticCheck;
    BOOL _waitingForDesktop;
    NSUInteger _automaticAttempts;
    BOOL _automaticModeRequested;
    NSTimeInterval _lastVisibleWindow;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _displayStates = [NSMutableDictionary dictionary];
    _observedMainDisplay = DisplayUUID(CGMainDisplayID());
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
    NSString *mainDisplay = DisplayUUID(CGMainDisplayID());
    BOOL mainChanged = ![_observedMainDisplay isEqualToString:mainDisplay];
    if (mainChanged) {
        _observedMainDisplay = mainDisplay;
        self.modeStatus = nil;
    }
    if ((newConnection || (connected && mainChanged)) && !self.monitor.manuallyRestored) {
        // O+ Connect can reconfigure the display while starting the session.
        _nextAutomaticCheck = now + (newConnection ? 5 : 1);
        _waitingForDesktop = NO;
        _automaticAttempts = 0;
        _automaticModeRequested = NO;
    } else if (disconnected) {
        _nextAutomaticCheck = 0;
        _waitingForDesktop = NO;
        [self prepareFactoryRestoreMode];
        if (_displayStates.count && [self desktopIsReady]) {
            [self performDisplayChangeWithStatus:@"正在恢复原分辨率…" desktopFeedback:YES change:^BOOL{
                [self restoreAllDisplays];
                return YES;
            }];
        } else {
            [self restoreAllDisplays];
        }
    }
    if (!self.pendingStatus && [self desktopIsReady]) {
        for (NSString *key in _displayStates.allKeys) {
            if (_displayStates[key].restoreOnReconnect && OnlineDisplayForUUID(key)) {
                [self restoreDisplay:key manual:NO];
            }
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
    NSString *key = DisplayUUID(CGMainDisplayID());
    DisplayRestoreState *state = key ? _displayStates[key] : nil;
    if (state.restorePending || state.manualRestoreRequired || state.restoreOnReconnect) return;

    if (state) {
        CGDisplayModeRef current = CGDisplayCopyDisplayMode(CGMainDisplayID());
        if (current) {
            BOOL bouncedBack = CFEqual(current, state.originalMode);
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
        if (!self.monitor.sessions.count || self.monitor.connectionGeneration != generation ||
            ![key isEqualToString:DisplayUUID(CGMainDisplayID())]) return NO;

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
    CGDirectDisplayID screen = CGMainDisplayID();
    NSString *key = DisplayUUID(screen);
    DisplayRestoreState *state = key ? _displayStates[key] : nil;
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(screen);
    BOOL remoteSelected = IsPreferredRemoteMode(current) ||
                          (current && state.remoteMode && CFEqual(current, state.remoteMode));
    NSControlStateValue remoteState = remoteSelected ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *status = self.modeStatus;
    if (current && (!status || (remoteSelected && !state.originalMode))) status = DisplayModeStatus(current);
    CGDisplayModeRef defaultMode = !busy && !state.originalMode ? CopyFactoryRestoreMode(screen, current) : NULL;
    BOOL canRestore = state.originalMode || defaultMode;
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
    self.landscapeButton.enabled = !busy && (remoteSelected || state.originalMode == NULL);
    self.restoreButton.enabled = !busy && canRestore;
    self.statusMenuLabel.title = self.statusLabel.stringValue;
    self.landscapeMenuItem.state = remoteState;
    self.landscapeMenuItem.enabled = self.landscapeButton.enabled;
    self.restoreMenuItem.enabled = self.restoreButton.enabled;
}

- (NSString *)switchingStatus {
    CGDirectDisplayID screen = CGMainDisplayID();
    NSString *key = DisplayUUID(screen);
    DisplayRestoreState *state = key ? _displayStates[key] : nil;
    CGDisplayModeRef original = state.originalMode
        ? CGDisplayModeRetain(state.originalMode) : CGDisplayCopyDisplayMode(screen);
    if (IsPreferredRemoteMode(original)) {
        self.modeStatus = DisplayModeStatus(original);
        CGDisplayModeRelease(original);
        return nil;
    }
    CGDisplayModeRef target = original ? CopyRemoteMode(original, RemoteDisplayModes(screen)) : NULL;
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
    CGDirectDisplayID screen = CGMainDisplayID();
    NSString *key = DisplayUUID(screen);
    if (!key || _displayStates[key]) return;
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(screen);
    CGDisplayModeRef fallback = CopyFactoryRestoreMode(screen, current);
    if (!fallback) {
        if (current) CGDisplayModeRelease(current);
        return;
    }

    DisplayRestoreState *state = [DisplayRestoreState new];
    state.originalMode = fallback;
    state.remoteMode = current;
    _displayStates[key] = state;
}

- (void)performManualChangeRestoring:(BOOL)restoring {
    NSString *key = DisplayUUID(CGMainDisplayID());
    if (!key || self.pendingStatus || (!restoring && _displayStates[key])) return;
    if (restoring) {
        [self prepareFactoryRestoreMode];
        if (!_displayStates[key]) {
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
        if (!restoring && ![key isEqualToString:DisplayUUID(CGMainDisplayID())]) return NO;
        self.monitor.manuallyRestored = restoring && self.monitor.sessions.count > 0;
        if (restoring) {
            [self restoreDisplay:key manual:YES];
        } else {
            [self applyRemoteMode];
        }
        return YES;
    }];
}

- (void)applyManually:(id)sender {
    [self performManualChangeRestoring:NO];
}

- (void)applyRemoteMode {
    [self applyRemoteModeAllowingRetry:NO];
}

- (void)applyRemoteModeAllowingRetry:(BOOL)retry {
    CGDirectDisplayID screen = CGMainDisplayID();
    NSString *key = DisplayUUID(screen);
    DisplayRestoreState *state = key ? _displayStates[key] : nil;
    if (!key || (state && !retry)) return;
    if (!_displayStates) _displayStates = [NSMutableDictionary dictionary];
    CGDisplayModeRef original = state ? CGDisplayModeRetain(state.originalMode)
                                      : CGDisplayCopyDisplayMode(screen);
    if (!original) {
        self.modeStatus = @"无法读取当前显示模式";
        return;
    }
    if (IsPreferredRemoteMode(original)) {
        self.modeStatus = DisplayModeStatus(original);
        CGDisplayModeRelease(original);
        return;
    }
    NSMutableArray *modes = [RemoteDisplayModes(screen) mutableCopy];
    CGDisplayModeRef remote;
    while ((remote = CopyRemoteMode(original, modes))) {
        if (CGDisplaySetDisplayMode(screen, remote, NULL) == kCGErrorSuccess) {
            CGDisplayModeRef applied = CGDisplayCopyDisplayMode(screen);
            if (applied && CGDisplayModeGetWidth(applied) == CGDisplayModeGetWidth(remote) &&
                CGDisplayModeGetHeight(applied) == CGDisplayModeGetHeight(remote)) {
                CGDisplayModeRelease(remote);
                remote = applied;
                break;
            }
            if (applied) CGDisplayModeRelease(applied);
        }
        // Core Graphics can reject one mode and accept another at the same size.
        NSUInteger index = [modes indexOfObjectIdenticalTo:(__bridge id)remote];
        [modes removeObjectAtIndex:index];
        CGDisplayModeRelease(remote);
    }
    if (!remote) {
        CGDisplayModeRelease(original);
        self.modeStatus = @"当前显示器无法切换到远控分辨率";
        return;
    }
    DisplayRestoreState *updated = [DisplayRestoreState new];
    updated.originalMode = original;
    updated.remoteMode = remote;
    _displayStates[key] = updated;

    self.modeStatus = DisplayModeStatus(remote);
}

- (void)restoreAllDisplays {
    for (NSString *key in _displayStates.allKeys) {
        [self restoreDisplay:key manual:NO];
    }
}

- (void)restoreDisplay:(NSString *)key manual:(BOOL)manual {
    DisplayRestoreState *state = _displayStates[key];
    if (!state) return;
    CGDirectDisplayID screen = OnlineDisplayForUUID(key);
    if (!screen) {
        state.restoreOnReconnect = YES;
        return;
    }
    BOOL isMain = screen == CGMainDisplayID();
    state.restoreOnReconnect = NO;
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(screen);
    if (!current) {
        if (isMain) self.modeStatus = @"无法读取分辨率，可重试恢复";
        return;
    }

    BOOL alreadyRestored = CFEqual(current, state.originalMode);
    BOOL shouldRestore = manual || state.restorePending || !state.remoteMode || CFEqual(current, state.remoteMode);
    if (!alreadyRestored && !shouldRestore) {
        state.manualRestoreRequired = YES;
        if (isMain) self.modeStatus = [DisplayModeStatus(current) stringByAppendingString:@"，可手动恢复"];
        CGDisplayModeRelease(current);
        return;
    }

    if (!alreadyRestored) {
        CGDisplayModeRelease(current);
        state.restorePending = YES;
        if (CGDisplaySetDisplayMode(screen, state.originalMode, NULL) != kCGErrorSuccess) {
            if (isMain) self.modeStatus = @"恢复失败，可重试";
            return;
        }

        current = CGDisplayCopyDisplayMode(screen);
        if (!current || !CFEqual(current, state.originalMode)) {
            if (current) CGDisplayModeRelease(current);
            if (isMain) self.modeStatus = @"尚未确认恢复，可重试";
            return;
        }
    }

    if (isMain) self.modeStatus = DisplayModeStatus(current);
    CGDisplayModeRelease(current);
    [_displayStates removeObjectForKey:key];
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
    [self restoreAllDisplays];
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
