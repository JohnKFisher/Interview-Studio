#ifndef DOCUMENT_CLOSE_BRIDGE_H
#define DOCUMENT_CLOSE_BRIDGE_H

#import <objc/objc.h>

/// Invokes an NSDocument close-review callback with its original Objective-C
/// ABI. Swift intentionally cannot call variadic objc_msgSend directly.
void ISInvokeDocumentCloseCallback(id delegate, SEL selector, id document, BOOL shouldClose, void *contextInfo);

#endif
