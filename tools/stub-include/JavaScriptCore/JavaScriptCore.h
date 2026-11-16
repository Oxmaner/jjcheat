/*
 * 本机语法检查用的 JavaScriptCore 最小替身 —— 仅用于 tools/check-syntax.sh。
 *
 * 本机 theos-sdks 里的 JavaScriptCore.framework 是空壳（Headers 目录为空），
 * 而 JJVisionBridge.m 只用到下面这一小组 API，所以按真实签名手抄一份。
 * 真机构建走 Xcode SDK 的真头文件，这个文件不参与打包。
 *
 * 覆盖范围（改动 JJVisionBridge 时若用了新 API，这里要同步补）：
 *   JSContext      : init / exceptionHandler / subscript / JSGlobalContextRef
 *   JSValue        : isUndefined|isNull|isString / toDictionary|toArray|toString
 *                    callWithArguments: / valueWith*:inContext: / JSValueRef / subscript
 *   C API          : JSObjectMakeTypedArray / JSObjectGetTypedArrayBytesPtr
 */
#ifndef JJ_STUB_JAVASCRIPTCORE_H
#define JJ_STUB_JAVASCRIPTCORE_H

#import <Foundation/Foundation.h>

/* ---------- C API ---------- */
#ifdef __cplusplus
extern "C" {
#endif

typedef const struct OpaqueJSContext *JSContextRef;
typedef struct OpaqueJSContext *JSGlobalContextRef;
typedef struct OpaqueJSValue *JSObjectRef;
typedef const struct OpaqueJSValue *JSValueRef;

typedef enum {
    kJSTypedArrayTypeInt8Array = 0,
    kJSTypedArrayTypeInt16Array,
    kJSTypedArrayTypeInt32Array,
    kJSTypedArrayTypeUint8Array,
    kJSTypedArrayTypeUint8ClampedArray,
    kJSTypedArrayTypeUint16Array,
    kJSTypedArrayTypeUint32Array,
    kJSTypedArrayTypeFloat32Array,
    kJSTypedArrayTypeFloat64Array,
    kJSTypedArrayTypeArrayBuffer,
    kJSTypedArrayTypeNone,
} JSTypedArrayType;

JSObjectRef JSObjectMakeTypedArray(JSContextRef ctx, JSTypedArrayType arrayType,
                                   size_t length, JSValueRef *exception);
void *JSObjectGetTypedArrayBytesPtr(JSContextRef ctx, JSObjectRef array, JSValueRef *exception);

#ifdef __cplusplus
}
#endif

/* ---------- ObjC API ---------- */
@class JSContext;

@interface JSValue : NSObject

@property (readonly) JSValueRef JSValueRef;
@property (readonly) BOOL isUndefined;
@property (readonly) BOOL isNull;
@property (readonly) BOOL isString;

+ (JSValue *)valueWithObject:(id)value inContext:(JSContext *)context;
+ (JSValue *)valueWithNullInContext:(JSContext *)context;
+ (JSValue *)valueWithNewObjectInContext:(JSContext *)context;
+ (JSValue *)valueWithJSValueRef:(JSValueRef)value inContext:(JSContext *)context;

- (JSValue *)callWithArguments:(NSArray *)arguments;
- (JSValue *)objectForKeyedSubscript:(id)key;
- (void)setObject:(id)object forKeyedSubscript:(id)key;

- (NSString *)toString;
- (NSDictionary *)toDictionary;
- (NSArray *)toArray;
- (NSNumber *)toNumber;

@end

@interface JSContext : NSObject

- (instancetype)init;

@property (readonly) JSGlobalContextRef JSGlobalContextRef;
@property (nonatomic, copy) void (^exceptionHandler)(JSContext *context, JSValue *exception);

- (JSValue *)evaluateScript:(NSString *)script withSourceURL:(NSURL *)sourceURL;
- (JSValue *)objectForKeyedSubscript:(id)key;
- (void)setObject:(id)object forKeyedSubscript:(id)key;

@end

#endif /* JJ_STUB_JAVASCRIPTCORE_H */
