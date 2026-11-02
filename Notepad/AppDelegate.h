#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate>
@property (strong, nonatomic) NSWindow *window;
@property (strong, nonatomic) NSTextView *textView;
@property (assign, nonatomic) BOOL wordWrapEnabled;
@end
