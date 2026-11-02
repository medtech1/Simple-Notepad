#import "AppDelegate.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <float.h>

// AppKit exposes switches for most substitutions, but not for the macOS
// double-space period shortcut. Intercepting the second physical Space key
// keeps literal spacing in this editor without changing system preferences.
// Automatic capitalization is an optional, conservative, ASCII-only behavior.
@interface SNPPlainTextView : NSTextView
@property (nonatomic) BOOL doubleSpacePeriodsEnabled;
@property (nonatomic) BOOL automaticCapitalizationEnabled;
@end

@implementation SNPPlainTextView

- (void)keyDown:(NSEvent *)event {
    NSEventModifierFlags modifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL plainTyping = (modifiers & (NSEventModifierFlagCommand |
                                     NSEventModifierFlagControl |
                                     NSEventModifierFlagOption)) == 0;
    NSString *typed = event.characters;
    NSRange selection = self.selectedRange;
    NSString *existing = self.string ?: @"";

    if (plainTyping && !self.hasMarkedText && selection.length == 0 &&
        selection.location != NSNotFound && selection.location <= existing.length) {

        // Normal typing: a second space must stay a space, not a period.
        if (!self.doubleSpacePeriodsEnabled && [typed isEqualToString:@" "] &&
            selection.location > 0 &&
            [existing characterAtIndex:selection.location - 1] == ' ') {
            [self insertText:@" "];
            return;
        }

        // Optional basic sentence capitalization, never enabled by default.
        if (self.automaticCapitalizationEnabled && typed.length == 1) {
            unichar letter = [typed characterAtIndex:0];
            if (letter >= 'a' && letter <= 'z') {
                BOOL sentenceStart = YES;
                for (NSInteger i = (NSInteger)selection.location - 1; i >= 0; --i) {
                    unichar previous = [existing characterAtIndex:(NSUInteger)i];
                    if (previous == '\n' || previous == '\r') break;
                    if (previous == ' ' || previous == '\t') continue;
                    sentenceStart = (previous == '.' || previous == '?' || previous == '!');
                    break;
                }
                if (sentenceStart) {
                    [self insertText:[typed uppercaseString]];
                    return;
                }
            }
        }
    }
    [super keyDown:event];
}

@end

// Each option is independent and persists in NSUserDefaults.
typedef NS_ENUM(NSInteger, SNPTextFeature) {
    SNPFeatureDoubleSpacePeriods = 1,
    SNPFeatureSmartQuotes,
    SNPFeatureSmartDashes,
    SNPFeatureSpellingCorrection,
    SNPFeatureTextReplacement,
    SNPFeatureLinkDetection,
    SNPFeatureDataDetection,
    SNPFeatureContinuousSpellChecking,
    SNPFeatureGrammarChecking,
    SNPFeatureTextCompletion,
    SNPFeatureAutomaticCapitalization,
    SNPFeatureSmartInsertDelete
};

@interface AppDelegate ()
@property (strong, nonatomic) NSScrollView *scrollView;
@property (strong, nonatomic) NSURL *currentFileURL;
@property (assign, nonatomic) BOOL documentDirty;
@property (strong, nonatomic) NSMenuItem *wrapMenuItem;
@property (strong, nonatomic) NSMutableArray<NSURL *> *pendingOpenURLs;
- (BOOL)saveDocumentToDisk;
- (BOOL)confirmDiscardingChanges;
- (void)updateWindowTitle;
- (BOOL)loadDocumentFromURL:(NSURL *)url;
- (NSString *)preferenceKeyForFeature:(SNPTextFeature)feature;
- (void)applyAutomaticTextFeature:(SNPTextFeature)feature enabled:(BOOL)enabled;
- (void)toggleAutomaticTextFeature:(NSMenuItem *)sender;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.wordWrapEnabled = YES;

    NSRect frame = NSMakeRect(0, 0, 700, 480);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:(NSWindowStyleMaskTitled |
                                                        NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskResizable |
                                                        NSWindowStyleMaskMiniaturizable)
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.window.delegate = self;
    [self.window center];

    self.scrollView = [[NSScrollView alloc] initWithFrame:frame];
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.borderType = NSNoBorder;

    NSSize contentSize = self.scrollView.contentSize;
    self.textView = [[SNPPlainTextView alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
    self.textView.minSize = NSMakeSize(0, contentSize.height);
    self.textView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.textView.verticallyResizable = YES;
    self.textView.horizontallyResizable = NO;
    self.textView.autoresizingMask = NSViewWidthSizable;
    self.textView.textContainer.widthTracksTextView = YES;
    self.textView.textContainer.containerSize = NSMakeSize(contentSize.width, FLT_MAX);
    self.textView.richText = NO;
    self.textView.importsGraphics = NO;
    self.textView.allowsUndo = YES;

    // OFF is the default for every option unless the user has enabled it.
    // NSUserDefaults retains choices across launches and upgrades.
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    for (NSInteger feature = SNPFeatureDoubleSpacePeriods;
         feature <= SNPFeatureSmartInsertDelete; feature++) {
        NSString *key = [self preferenceKeyForFeature:(SNPTextFeature)feature];
        [self applyAutomaticTextFeature:(SNPTextFeature)feature
                               enabled:[preferences boolForKey:key]];
    }

    self.textView.delegate = self;
    self.textView.font = [NSFont userFixedPitchFontOfSize:13.0];

    // An explicit context menu also supports right-click editing commands.
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [contextMenu addItemWithTitle:@"Undo" action:NSSelectorFromString(@"undo:") keyEquivalent:@""];
    [contextMenu addItem:[NSMenuItem separatorItem]];
    [contextMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@""];
    [contextMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@""];
    [contextMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@""];
    [contextMenu addItem:[NSMenuItem separatorItem]];
    [contextMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@""];
    self.textView.menu = contextMenu;

    self.scrollView.documentView = self.textView;
    self.window.contentView = self.scrollView;
    [self setupMenus];
    [self updateWindowTitle];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.textView];
    [NSApp activateIgnoringOtherApps:YES];

    // Finder may send open-file events before the editor window exists.
    NSArray<NSURL *> *pending = [self.pendingOpenURLs copy];
    [self.pendingOpenURLs removeAllObjects];
    for (NSURL *url in pending) {
        [self loadDocumentFromURL:url];
    }
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    (void)sender;
    NSURL *url = [NSURL fileURLWithPath:filename];
    if (!self.textView) {
        if (!self.pendingOpenURLs) self.pendingOpenURLs = [NSMutableArray array];
        [self.pendingOpenURLs addObject:url];
        return YES;
    }
    return [self loadDocumentFromURL:url];
}

- (NSMenuItem *)addItem:(NSString *)title action:(SEL)action shortcut:(NSString *)shortcut
                  menu:(NSMenu *)menu target:(id)target {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:shortcut];
    item.target = target;
    return item;
}

- (NSMenu *)addTopLevelMenu:(NSString *)title to:(NSMenu *)mainMenu {
    NSMenuItem *top = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
    [mainMenu addItem:top];
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:title];
    top.submenu = submenu;
    return submenu;
}

- (void)setupMenus {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
    NSApp.mainMenu = mainMenu;

    NSMenu *appMenu = [self addTopLevelMenu:@"Simple Notepad" to:mainMenu];
    [self addItem:@"Quit Simple Notepad" action:@selector(terminate:) shortcut:@"q"
             menu:appMenu target:NSApp];

    NSMenu *fileMenu = [self addTopLevelMenu:@"File" to:mainMenu];
    [self addItem:@"New" action:@selector(newDocument:) shortcut:@"n" menu:fileMenu target:self];
    [self addItem:@"Open…" action:@selector(openDocument:) shortcut:@"o" menu:fileMenu target:self];
    [self addItem:@"Save" action:@selector(saveDocument:) shortcut:@"s" menu:fileMenu target:self];
    [self addItem:@"Save As…" action:@selector(saveDocumentAs:) shortcut:@"S" menu:fileMenu target:self];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [self addItem:@"Page Setup…" action:@selector(showPageSetup:) shortcut:@"P" menu:fileMenu target:self];
    [self addItem:@"Print…" action:@selector(printDocument:) shortcut:@"p" menu:fileMenu target:self];

    NSMenu *editMenu = [self addTopLevelMenu:@"Edit" to:mainMenu];
    [self addItem:@"Undo" action:NSSelectorFromString(@"undo:") shortcut:@"z" menu:editMenu target:nil];
    [self addItem:@"Redo" action:NSSelectorFromString(@"redo:") shortcut:@"Z" menu:editMenu target:nil];
    
    [editMenu addItem:[NSMenuItem separatorItem]];
    [self addItem:@"Cut" action:@selector(cut:) shortcut:@"x" menu:editMenu target:nil];
    [self addItem:@"Copy" action:@selector(copy:) shortcut:@"c" menu:editMenu target:nil];
    [self addItem:@"Paste" action:@selector(paste:) shortcut:@"v" menu:editMenu target:nil];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [self addItem:@"Select All" action:@selector(selectAll:) shortcut:@"a" menu:editMenu target:nil];

    [editMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *automaticFeaturesItem =
        [editMenu addItemWithTitle:@"Automatic Text Features"
                           action:NULL
                    keyEquivalent:@""];
    NSMenu *automaticFeaturesMenu =
        [[NSMenu alloc] initWithTitle:@"Automatic Text Features"];
    automaticFeaturesItem.submenu = automaticFeaturesMenu;

    NSArray<NSDictionary<NSString *, id> *> *features = @[
        @{@"title": @"Double-Space Periods (macOS)",     @"id": @(SNPFeatureDoubleSpacePeriods)},
        @{@"title": @"Smart Quotes",                     @"id": @(SNPFeatureSmartQuotes)},
        @{@"title": @"Smart Dashes",                     @"id": @(SNPFeatureSmartDashes)},
        @{@"title": @"Automatic Spelling Correction",    @"id": @(SNPFeatureSpellingCorrection)},
        @{@"title": @"Automatic Text Replacement",       @"id": @(SNPFeatureTextReplacement)},
        @{@"title": @"Automatic Link Detection",         @"id": @(SNPFeatureLinkDetection)},
        @{@"title": @"Automatic Data Detection",         @"id": @(SNPFeatureDataDetection)},
        @{@"title": @"Continuous Spell Checking",        @"id": @(SNPFeatureContinuousSpellChecking)},
        @{@"title": @"Grammar Checking",                @"id": @(SNPFeatureGrammarChecking)},
        @{@"title": @"Text Completion (where supported)", @"id": @(SNPFeatureTextCompletion)},
        @{@"title": @"Automatic Capitalization (basic)", @"id": @(SNPFeatureAutomaticCapitalization)},
        @{@"title": @"Smart Insert/Delete Spacing",     @"id": @(SNPFeatureSmartInsertDelete)}
    ];
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    for (NSDictionary<NSString *, id> *feature in features) {
        SNPTextFeature identifier = (SNPTextFeature)[feature[@"id"] integerValue];
        NSMenuItem *item = [automaticFeaturesMenu addItemWithTitle:feature[@"title"]
                                                           action:@selector(toggleAutomaticTextFeature:)
                                                    keyEquivalent:@""];
        item.target = self;
        item.tag = identifier;
        item.state = [preferences boolForKey:[self preferenceKeyForFeature:identifier]]
            ? NSControlStateValueOn : NSControlStateValueOff;
    }

    NSMenu *formatMenu = [self addTopLevelMenu:@"Format" to:mainMenu];
    self.wrapMenuItem = [self addItem:@"Word Wrap" action:@selector(toggleWordWrap:)
                                  shortcut:@"w" menu:formatMenu target:self];
    self.wrapMenuItem.state = NSControlStateValueOn;
}

// Existing preference keys are retained for the options already built.
- (NSString *)preferenceKeyForFeature:(SNPTextFeature)feature {
    switch (feature) {
        case SNPFeatureDoubleSpacePeriods:      return @"DoubleSpacePeriodsEnabled";
        case SNPFeatureSmartQuotes:             return @"SmartQuotesEnabled";
        case SNPFeatureSmartDashes:             return @"SmartDashesEnabled";
        case SNPFeatureSpellingCorrection:      return @"SpellingCorrectionEnabled";
        case SNPFeatureTextReplacement:         return @"TextReplacementEnabled";
        case SNPFeatureLinkDetection:           return @"LinkDetectionEnabled";
        case SNPFeatureDataDetection:           return @"DataDetectionEnabled";
        case SNPFeatureContinuousSpellChecking: return @"ContinuousSpellCheckingEnabled";
        case SNPFeatureGrammarChecking:         return @"GrammarCheckingEnabled";
        case SNPFeatureTextCompletion:          return @"TextCompletionEnabled";
        case SNPFeatureAutomaticCapitalization: return @"AutomaticCapitalizationEnabled";
        case SNPFeatureSmartInsertDelete:       return @"SmartInsertDeleteEnabled";
    }
    return @"";
}

- (void)applyAutomaticTextFeature:(SNPTextFeature)feature enabled:(BOOL)enabled {
    switch (feature) {
        case SNPFeatureDoubleSpacePeriods:
            ((SNPPlainTextView *)self.textView).doubleSpacePeriodsEnabled = enabled;
            break;
        case SNPFeatureSmartQuotes:
            self.textView.automaticQuoteSubstitutionEnabled = enabled;
            break;
        case SNPFeatureSmartDashes:
            self.textView.automaticDashSubstitutionEnabled = enabled;
            break;
        case SNPFeatureSpellingCorrection:
            self.textView.automaticSpellingCorrectionEnabled = enabled;
            break;
        case SNPFeatureTextReplacement:
            self.textView.automaticTextReplacementEnabled = enabled;
            break;
        case SNPFeatureLinkDetection:
            self.textView.automaticLinkDetectionEnabled = enabled;
            break;
        case SNPFeatureDataDetection:
            self.textView.automaticDataDetectionEnabled = enabled;
            break;
        case SNPFeatureContinuousSpellChecking:
            self.textView.continuousSpellCheckingEnabled = enabled;
            break;
        case SNPFeatureGrammarChecking:
            self.textView.grammarCheckingEnabled = enabled;
            break;
        case SNPFeatureTextCompletion:
            self.textView.automaticTextCompletionEnabled = enabled;
            break;
        case SNPFeatureAutomaticCapitalization:
            ((SNPPlainTextView *)self.textView).automaticCapitalizationEnabled = enabled;
            break;
        case SNPFeatureSmartInsertDelete:
            self.textView.smartInsertDeleteEnabled = enabled;
            break;
    }
}

- (void)toggleAutomaticTextFeature:(NSMenuItem *)sender {
    SNPTextFeature feature = (SNPTextFeature)sender.tag;
    NSString *key = [self preferenceKeyForFeature:feature];
    if (key.length == 0) return;

    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    BOOL enabled = ![preferences boolForKey:key];
    [self applyAutomaticTextFeature:feature enabled:enabled];
    [preferences setBool:enabled forKey:key];
    sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)updateWindowTitle {
    NSString *name = self.currentFileURL ? self.currentFileURL.lastPathComponent : @"Simple Notepad";
    self.window.title = name;
    self.window.documentEdited = self.documentDirty;
    self.window.representedURL = self.currentFileURL;
}

- (void)textDidChange:(NSNotification *)notification {
    (void)notification;
    self.documentDirty = YES;
    [self updateWindowTitle];
}

- (BOOL)confirmDiscardingChanges {
    if (!self.documentDirty) return YES;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Do you want to save your changes?";
    alert.informativeText = @"Unsaved changes will be lost if you don't save them.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Don't Save"];
    [alert addButtonWithTitle:@"Cancel"];
    NSModalResponse result = [alert runModal];
    if (result == NSAlertFirstButtonReturn) return [self saveDocumentToDisk];
    return result == NSAlertSecondButtonReturn;
}

- (void)newDocument:(id)sender {
    (void)sender;
    if (![self confirmDiscardingChanges]) return;
    self.textView.string = @"";
    [self.textView.undoManager removeAllActions];
    self.currentFileURL = nil;
    self.documentDirty = NO;
    [self updateWindowTitle];
}

- (BOOL)loadDocumentFromURL:(NSURL *)url {
    if (![self confirmDiscardingChanges]) return NO;

    NSError *error = nil;
    NSString *contents = [NSString stringWithContentsOfURL:url
                                                  encoding:NSUTF8StringEncoding
                                                     error:&error];
    if (!contents) {
        if (error) [NSApp presentError:error];
        return NO;
    }

    // As before, files are loaded as literal UTF-8 plain text, including RTF.
    self.textView.string = contents;
    [self.textView.undoManager removeAllActions];
    self.currentFileURL = url;
    self.documentDirty = NO;
    [self updateWindowTitle];
    return YES;
}

- (void)openDocument:(id)sender {
    (void)sender;
    // Do not ask to discard changes until a file has actually been selected.
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[UTTypePlainText, UTTypeRTF,
                                  [UTType typeWithFilenameExtension:@"md" conformingToType:UTTypePlainText]];
    if ([panel runModal] != NSModalResponseOK) return;
    [self loadDocumentFromURL:panel.URL];
}

- (BOOL)writeToURL:(NSURL *)url {
    NSError *error = nil;

    BOOL saved = [self.textView.string writeToURL:url atomically:YES
                                       encoding:NSUTF8StringEncoding error:&error];

    if (!saved) {
        [NSApp presentError:error];
        return NO;
    }

    self.currentFileURL = url;
    self.documentDirty = NO;
    [self updateWindowTitle];

    return YES;
}

- (BOOL)saveDocumentToDisk {
    if (self.currentFileURL) return [self writeToURL:self.currentFileURL];
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypePlainText];
    panel.nameFieldStringValue = @"Untitled.txt";
    if ([panel runModal] != NSModalResponseOK) return NO;
    return [self writeToURL:panel.URL];
}

- (void)saveDocument:(id)sender {
    (void)sender;
    [self saveDocumentToDisk];
}

- (void)saveDocumentAs:(id)sender {
    (void)sender;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypePlainText];
    panel.nameFieldStringValue = self.currentFileURL.lastPathComponent ?: @"Untitled.txt";
    if ([panel runModal] == NSModalResponseOK) [self writeToURL:panel.URL];
}


- (void)showPageSetup:(id)sender {
    (void)sender;
    [[NSPageLayout pageLayout] runModalWithPrintInfo:[NSPrintInfo sharedPrintInfo]];
}

// Create a separate text view for printing.
// The editor's scrolling and word-wrap settings remain unchanged.
- (NSTextView *)textViewForPrintingWithPrintInfo:(NSPrintInfo *)printInfo {
    NSSize paperSize = printInfo.paperSize;

    CGFloat printableWidth = paperSize.width
        - printInfo.leftMargin - printInfo.rightMargin;

    if (printableWidth < 100.0) {
        printableWidth = 500.0;
    }

    NSTextView *printView = [[NSTextView alloc]
        initWithFrame:NSMakeRect(0, 0, printableWidth, 100)];

    printView.richText = NO;
    printView.editable = NO;
    printView.selectable = NO;
    printView.font = self.textView.font;
    printView.string = self.textView.string ?: @"";

    printView.horizontallyResizable = NO;
    printView.verticallyResizable = YES;
    printView.textContainer.widthTracksTextView = YES;
    printView.textContainer.containerSize =
        NSMakeSize(printableWidth, FLT_MAX);

    printView.textContainerInset = NSMakeSize(0, 0);

    NSLayoutManager *layoutManager = printView.layoutManager;
    [layoutManager ensureLayoutForTextContainer:printView.textContainer];

    NSRect usedRect =
        [layoutManager usedRectForTextContainer:printView.textContainer];

    
    CGFloat printableHeight = paperSize.height
        - printInfo.topMargin - printInfo.bottomMargin;

    printableHeight = MAX(printableHeight, 100.0);

    CGFloat contentHeight = MAX(usedRect.size.height + 20.0, printableHeight);

    [printView setFrameSize:NSMakeSize(printableWidth, contentHeight)];
  
    return printView;
}

- (void)printDocument:(id)sender {
    (void)sender;

    NSPrintInfo *info = [[NSPrintInfo sharedPrintInfo] copy];

    // Keep the printed content aligned with the page margins.
    info.horizontallyCentered = NO;
    info.verticallyCentered = NO;

    NSTextView *printView = [self textViewForPrintingWithPrintInfo:info];

    NSPrintOperation *operation =
        [NSPrintOperation printOperationWithView:printView printInfo:info];

    operation.showsPrintPanel = YES;
    operation.showsProgressPanel = YES;

    [operation runOperation];
}

- (void)toggleWordWrap:(id)sender {
    (void)sender;
    self.wordWrapEnabled = !self.wordWrapEnabled;
    self.wrapMenuItem.state = self.wordWrapEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    NSTextContainer *container = self.textView.textContainer;
    if (self.wordWrapEnabled) {
        self.textView.horizontallyResizable = NO;
        self.textView.autoresizingMask = NSViewWidthSizable;
        container.widthTracksTextView = YES;
        container.containerSize = NSMakeSize(self.scrollView.contentSize.width, FLT_MAX);
        self.scrollView.hasHorizontalScroller = NO;
    } else {
        container.widthTracksTextView = NO;
        container.containerSize = NSMakeSize(FLT_MAX, FLT_MAX);
        self.textView.horizontallyResizable = YES;
        self.textView.autoresizingMask = NSViewNotSizable;
        self.textView.frame = NSMakeRect(0, 0, MAX(self.scrollView.contentSize.width, 2000),
                                         MAX(self.textView.frame.size.height, self.scrollView.contentSize.height));
        self.scrollView.hasHorizontalScroller = YES;
    }
    [self.textView.textContainer setContainerSize:container.containerSize];
    [self.textView setNeedsDisplay:YES];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    (void)sender;
    return [self confirmDiscardingChanges];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    return [self confirmDiscardingChanges] ? NSTerminateNow : NSTerminateCancel;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

@end
