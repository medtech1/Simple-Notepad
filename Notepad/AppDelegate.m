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


@class SNPDocumentWindowController;

// AppDelegate owns the open document controllers. Each controller owns its own
// text view, undo manager, file URL, dirty flag, and independent window.
@interface AppDelegate (SNPDocumentSupport)
- (void)applySavedTextPreferencesToView:(NSTextView *)textView;
- (void)documentWindowWillClose:(SNPDocumentWindowController *)document;
- (BOOL)isURLBeingEdited:(NSURL *)url byAnotherDocument:(SNPDocumentWindowController *)document;
@end

@interface SNPDocumentWindowController : NSWindowController <NSWindowDelegate, NSTextViewDelegate>
@property (nonatomic, weak) AppDelegate *documentHost;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTextView *textView;
@property (nonatomic, strong) NSURL *currentFileURL;
@property (nonatomic) BOOL documentDirty;
@property (nonatomic) BOOL wordWrapEnabled;
@property (nonatomic) BOOL allowCloseWithoutPrompt;
- (instancetype)initWithOwner:(AppDelegate *)owner;
- (BOOL)loadDocumentFromURL:(NSURL *)url;
- (BOOL)saveDocumentToDiskSavingAs:(BOOL)saveAs;
- (BOOL)confirmDiscardingChanges;
- (void)updateWindowTitle;
- (void)toggleWordWrap;
- (void)printDocument;
@end

@implementation SNPDocumentWindowController

- (instancetype)initWithOwner:(AppDelegate *)owner {
    NSRect frame = NSMakeRect(0, 0, 700, 480);
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
                 styleMask:(NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable |
                            NSWindowStyleMaskMiniaturizable)
                   backing:NSBackingStoreBuffered
                     defer:NO];
    self = [super initWithWindow:window];
    if (!self) return nil;
    self.documentHost = owner;
    self.wordWrapEnabled = YES;
    window.delegate = self;
    window.releasedWhenClosed = NO;
    [window center];

    self.scrollView = [[NSScrollView alloc] initWithFrame:frame];
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.borderType = NSNoBorder;

    NSSize contentSize = self.scrollView.contentSize;
    self.textView = [[SNPPlainTextView alloc]
        initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
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
    [owner applySavedTextPreferencesToView:self.textView];
    self.textView.delegate = self;
    self.textView.font = [NSFont userFixedPitchFontOfSize:13.0];

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
    window.contentView = self.scrollView;
    [self updateWindowTitle];
    return self;
}

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    [self.window makeKeyAndOrderFront:sender];
    [self.window makeFirstResponder:self.textView];
}

- (void)updateWindowTitle {
    self.window.title = self.currentFileURL.lastPathComponent ?: @"Untitled";
    self.window.documentEdited = self.documentDirty;
    self.window.representedURL = self.currentFileURL;
}

- (void)textDidChange:(NSNotification *)notification {
    (void)notification;
    self.documentDirty = YES;
    [self updateWindowTitle];
}

- (BOOL)loadDocumentFromURL:(NSURL *)url {
    NSError *error = nil;
    NSString *contents = [NSString stringWithContentsOfURL:url
                                                  encoding:NSUTF8StringEncoding
                                                     error:&error];
    if (!contents) {
        if (error) [NSApp presentError:error];
        return NO;
    }
    // Exactly as before, read literal UTF-8 text; never interpret RTF formatting.
    self.textView.string = contents;
    [self.textView.undoManager removeAllActions];
    self.currentFileURL = url;
    self.documentDirty = NO;
    [self updateWindowTitle];
    return YES;
}

- (BOOL)writeToURL:(NSURL *)url {
    // Avoid silently having two independent windows editing the same output file.
    if ([self.documentHost isURLBeingEdited:url byAnotherDocument:self]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"This file is already open in another window.";
        alert.informativeText = @"Choose a different filename or use the existing window.";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        return NO;
    }
    NSError *error = nil;
    BOOL saved = [self.textView.string writeToURL:url atomically:YES
                                       encoding:NSUTF8StringEncoding error:&error];
    if (!saved) {
        if (error) [NSApp presentError:error];
        return NO;
    }
    self.currentFileURL = url;
    self.documentDirty = NO;
    [self updateWindowTitle];
    return YES;
}

- (BOOL)saveDocumentToDiskSavingAs:(BOOL)saveAs {
    if (self.currentFileURL && !saveAs) {
        return [self writeToURL:self.currentFileURL];
    }
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypePlainText];
    panel.nameFieldStringValue = self.currentFileURL.lastPathComponent ?: @"Untitled.txt";
    if ([panel runModal] != NSModalResponseOK) return NO;
    return [self writeToURL:panel.URL];
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
    if (result == NSAlertFirstButtonReturn) return [self saveDocumentToDiskSavingAs:NO];
    return result == NSAlertSecondButtonReturn;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    (void)sender;
    return self.allowCloseWithoutPrompt || [self confirmDiscardingChanges];
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    [self.documentHost documentWindowWillClose:self];
}

- (void)printDocument {
    NSPrintInfo *info = [[NSPrintInfo sharedPrintInfo] copy];
    info.horizontallyCentered = NO;
    info.verticallyCentered = NO;
    NSTextView *printView = [self textViewForPrintingWithPrintInfo:info];
    NSPrintOperation *operation =
        [NSPrintOperation printOperationWithView:printView printInfo:info];
    operation.showsPrintPanel = YES;
    operation.showsProgressPanel = YES;
    [operation runOperation];
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

- (void)toggleWordWrap {
    self.wordWrapEnabled = !self.wordWrapEnabled;
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


@end


@interface AppDelegate () <NSMenuDelegate>
@property (nonatomic, strong) NSMutableArray<SNPDocumentWindowController *> *documents;
@property (nonatomic, strong) NSMutableArray<NSURL *> *pendingOpenURLs;
@property (nonatomic, strong) NSMenuItem *wrapMenuItem;
@property (nonatomic, strong) NSMenu *formatMenu;
@property (nonatomic) BOOL didFinishLaunching;
- (NSString *)preferenceKeyForFeature:(SNPTextFeature)feature;
- (void)applyAutomaticTextFeature:(SNPTextFeature)feature enabled:(BOOL)enabled
                        toTextView:(NSTextView *)textView;
- (void)toggleAutomaticTextFeature:(NSMenuItem *)sender;
- (void)setupMenus;
- (SNPDocumentWindowController *)activeDocument;
- (BOOL)openDocumentURL:(NSURL *)url;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.documents = [NSMutableArray array];
    [self setupMenus];
    self.didFinishLaunching = YES;

    NSArray<NSURL *> *pending = [self.pendingOpenURLs copy];
    [self.pendingOpenURLs removeAllObjects];
    if (pending.count == 0) {
        [self newDocument:nil];
    } else {
        BOOL openedAny = NO;
        for (NSURL *url in pending) {
            openedAny = [self openDocumentURL:url] || openedAny;
        }
        if (!openedAny) [self newDocument:nil];
    }
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    (void)sender;
    NSURL *url = [NSURL fileURLWithPath:filename];
    if (!self.didFinishLaunching) {
        if (!self.pendingOpenURLs) self.pendingOpenURLs = [NSMutableArray array];
        [self.pendingOpenURLs addObject:url];
        return YES;
    }
    return [self openDocumentURL:url];
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    BOOL succeeded = YES;
    for (NSString *name in filenames) {
        if (![self application:sender openFile:name]) succeeded = NO;
    }
    [sender replyToOpenOrPrint:(succeeded ? NSApplicationDelegateReplySuccess
                                        : NSApplicationDelegateReplyFailure)];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender;
    if (!flag && self.documents.count == 0) [self newDocument:nil];
    return YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO; // Standard macOS behavior: File > New still works with no windows.
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    for (SNPDocumentWindowController *document in [self.documents copy]) {
        if (![document confirmDiscardingChanges]) return NSTerminateCancel;
    }
    for (SNPDocumentWindowController *document in self.documents) {
        document.allowCloseWithoutPrompt = YES;
    }
    return NSTerminateNow;
}

- (void)documentWindowWillClose:(SNPDocumentWindowController *)document {
    [self.documents removeObject:document];
}

- (SNPDocumentWindowController *)activeDocument {
    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
    for (SNPDocumentWindowController *document in self.documents) {
        if (document.window == window) return document;
    }
    return self.documents.lastObject;
}

- (BOOL)isURLBeingEdited:(NSURL *)url byAnotherDocument:(SNPDocumentWindowController *)document {
    NSString *path = url.URLByStandardizingPath.path;
    for (SNPDocumentWindowController *candidate in self.documents) {
        if (candidate != document &&
            [candidate.currentFileURL.URLByStandardizingPath.path isEqualToString:path]) {
            return YES;
        }
    }
    return NO;
}

- (void)newDocument:(id)sender {
    (void)sender;
    SNPDocumentWindowController *document =
        [[SNPDocumentWindowController alloc] initWithOwner:self];
    [self.documents addObject:document];
    [document showWindow:nil];
}

- (BOOL)openDocumentURL:(NSURL *)url {
    NSString *path = url.URLByStandardizingPath.path;
    for (SNPDocumentWindowController *document in self.documents) {
        if ([document.currentFileURL.URLByStandardizingPath.path isEqualToString:path]) {
            [document showWindow:nil];
            return YES;
        }
    }
    SNPDocumentWindowController *document =
        [[SNPDocumentWindowController alloc] initWithOwner:self];
    if (![document loadDocumentFromURL:url]) return NO;
    [self.documents addObject:document];
    [document showWindow:nil];
    return YES;
}

- (void)openDocument:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[UTTypePlainText, UTTypeRTF,
        [UTType typeWithFilenameExtension:@"md" conformingToType:UTTypePlainText]];
    panel.allowsMultipleSelection = YES;
    if ([panel runModal] != NSModalResponseOK) return;
    for (NSURL *url in panel.URLs) [self openDocumentURL:url];
}

- (void)closeDocument:(id)sender {
    (void)sender;
    [[self activeDocument].window performClose:nil];
}

- (void)saveDocument:(id)sender {
    (void)sender;
    [[self activeDocument] saveDocumentToDiskSavingAs:NO];
}

- (void)saveDocumentAs:(id)sender {
    (void)sender;
    [[self activeDocument] saveDocumentToDiskSavingAs:YES];
}

- (void)showPageSetup:(id)sender {
    (void)sender;
    [[NSPageLayout pageLayout] runModalWithPrintInfo:[NSPrintInfo sharedPrintInfo]];
}

- (void)printDocument:(id)sender {
    (void)sender;
    [[self activeDocument] printDocument];
}

- (void)toggleWordWrap:(id)sender {
    (void)sender;
    SNPDocumentWindowController *document = [self activeDocument];
    [document toggleWordWrap];
    self.wrapMenuItem.state = document.wordWrapEnabled
        ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)menuWillOpen:(NSMenu *)menu {
    if (menu == self.formatMenu) {
        SNPDocumentWindowController *document = [self activeDocument];
        self.wrapMenuItem.state = (!document || document.wordWrapEnabled)
            ? NSControlStateValueOn : NSControlStateValueOff;
    }
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
    [self addItem:@"Close Window" action:@selector(closeDocument:) shortcut:@"w" menu:fileMenu target:self];
    [fileMenu addItem:[NSMenuItem separatorItem]];
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
    NSMenuItem *featuresItem =
        [editMenu addItemWithTitle:@"Automatic Text Features" action:NULL keyEquivalent:@""];
    NSMenu *featuresMenu = [[NSMenu alloc] initWithTitle:@"Automatic Text Features"];
    featuresItem.submenu = featuresMenu;
    NSArray<NSDictionary<NSString *, id> *> *features = @[
        @{@"title": @"Double-Space Periods (macOS)",       @"id": @(SNPFeatureDoubleSpacePeriods)},
        @{@"title": @"Smart Quotes",                       @"id": @(SNPFeatureSmartQuotes)},
        @{@"title": @"Smart Dashes",                       @"id": @(SNPFeatureSmartDashes)},
        @{@"title": @"Automatic Spelling Correction",      @"id": @(SNPFeatureSpellingCorrection)},
        @{@"title": @"Automatic Text Replacement",         @"id": @(SNPFeatureTextReplacement)},
        @{@"title": @"Automatic Link Detection",           @"id": @(SNPFeatureLinkDetection)},
        @{@"title": @"Automatic Data Detection",           @"id": @(SNPFeatureDataDetection)},
        @{@"title": @"Continuous Spell Checking",          @"id": @(SNPFeatureContinuousSpellChecking)},
        @{@"title": @"Grammar Checking",                   @"id": @(SNPFeatureGrammarChecking)},
        @{@"title": @"Text Completion (where supported)",  @"id": @(SNPFeatureTextCompletion)},
        @{@"title": @"Automatic Capitalization (basic)",   @"id": @(SNPFeatureAutomaticCapitalization)},
        @{@"title": @"Smart Insert/Delete Spacing",       @"id": @(SNPFeatureSmartInsertDelete)}
    ];
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    for (NSDictionary<NSString *, id> *feature in features) {
        SNPTextFeature identifier = (SNPTextFeature)[feature[@"id"] integerValue];
        NSMenuItem *item = [featuresMenu addItemWithTitle:feature[@"title"]
                                                 action:@selector(toggleAutomaticTextFeature:)
                                          keyEquivalent:@""];
        item.target = self;
        item.tag = identifier;
        item.state = [preferences boolForKey:[self preferenceKeyForFeature:identifier]]
            ? NSControlStateValueOn : NSControlStateValueOff;
    }

    self.formatMenu = [self addTopLevelMenu:@"Format" to:mainMenu];
    self.formatMenu.delegate = self;
    self.wrapMenuItem = [self addItem:@"Word Wrap" action:@selector(toggleWordWrap:)
                                  shortcut:@"w" menu:self.formatMenu target:self];
    self.wrapMenuItem.state = NSControlStateValueOn;

    // Standard macOS Window menu makes each document accessible independently.
    NSMenu *windowMenu = [self addTopLevelMenu:@"Window" to:mainMenu];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:)
                  keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:)
                  keyEquivalent:@""];
    NSApp.windowsMenu = windowMenu;
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

- (void)applyAutomaticTextFeature:(SNPTextFeature)feature enabled:(BOOL)enabled
                        toTextView:(NSTextView *)textView {
    switch (feature) {
        case SNPFeatureDoubleSpacePeriods:
            ((SNPPlainTextView *)textView).doubleSpacePeriodsEnabled = enabled;
            break;
        case SNPFeatureSmartQuotes:
            textView.automaticQuoteSubstitutionEnabled = enabled;
            break;
        case SNPFeatureSmartDashes:
            textView.automaticDashSubstitutionEnabled = enabled;
            break;
        case SNPFeatureSpellingCorrection:
            textView.automaticSpellingCorrectionEnabled = enabled;
            break;
        case SNPFeatureTextReplacement:
            textView.automaticTextReplacementEnabled = enabled;
            break;
        case SNPFeatureLinkDetection:
            textView.automaticLinkDetectionEnabled = enabled;
            break;
        case SNPFeatureDataDetection:
            textView.automaticDataDetectionEnabled = enabled;
            break;
        case SNPFeatureContinuousSpellChecking:
            textView.continuousSpellCheckingEnabled = enabled;
            break;
        case SNPFeatureGrammarChecking:
            textView.grammarCheckingEnabled = enabled;
            break;
        case SNPFeatureTextCompletion:
            textView.automaticTextCompletionEnabled = enabled;
            break;
        case SNPFeatureAutomaticCapitalization:
            ((SNPPlainTextView *)textView).automaticCapitalizationEnabled = enabled;
            break;
        case SNPFeatureSmartInsertDelete:
            textView.smartInsertDeleteEnabled = enabled;
            break;
    }
}

- (void)applySavedTextPreferencesToView:(NSTextView *)textView {
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    for (NSInteger feature = SNPFeatureDoubleSpacePeriods;
         feature <= SNPFeatureSmartInsertDelete; ++feature) {
        SNPTextFeature identifier = (SNPTextFeature)feature;
        [self applyAutomaticTextFeature:identifier
                               enabled:[preferences boolForKey:[self preferenceKeyForFeature:identifier]]
                            toTextView:textView];
    }
}

- (void)toggleAutomaticTextFeature:(NSMenuItem *)sender {
    SNPTextFeature feature = (SNPTextFeature)sender.tag;
    NSString *key = [self preferenceKeyForFeature:feature];
    if (key.length == 0) return;
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    BOOL enabled = ![preferences boolForKey:key];
    [preferences setBool:enabled forKey:key];
    for (SNPDocumentWindowController *document in self.documents) {
        [self applyAutomaticTextFeature:feature enabled:enabled toTextView:document.textView];
    }
    sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
}

@end
