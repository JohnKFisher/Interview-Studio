#import "DocumentCloseBridge.h"
#import <objc/message.h>

typedef void (*ISDocumentCloseCallback)(id, SEL, id, BOOL, void *);

void ISInvokeDocumentCloseCallback(id delegate, SEL selector, id document, BOOL shouldClose, void *contextInfo) {
    if (delegate == nil || selector == NULL) {
        return;
    }
    ((ISDocumentCloseCallback)objc_msgSend)(delegate, selector, document, shouldClose, contextInfo);
}
