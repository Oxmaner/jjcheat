//
//  JavaScriptCore.h  —— 最小可用声明（2.0.0r1）
//
//  为什么需要这个文件：
//  工程用 #import <JavaScriptCore/JavaScriptCore.h> 引入 JSCore，但
//  Dylix 内置的 iOS SDK（16.4 与 26.0 都是）**把 JavaScriptCore.framework
//  整个裁掉了**，编译直接 fatal error: file not found。
//
//  而设备上 JavaScriptCore 是系统框架，运行时必然存在（Safari/WebKit 都依赖它），
//  所以只要编译期有声明就能链接上 —— 这里只写本工程实际用到的那部分 API，
//  签名与 Apple 公开头文件一致。
//
//  用法：把本文件放在 Vision/ 下，源码改用 #import "JavaScriptCore.h"。
//

#ifndef JJ_MINI_JAVASCRIPTCORE_H
#define JJ_MINI_JAVASCRIPTCORE_H

#import <Foundation/Foundation.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------- 不透明句柄 ---------- */
typedef struct OpaqueJSContext       *JSContextRef;
typedef struct OpaqueJSContext       *JSGlobalContextRef;
typedef struct OpaqueJSContextGroup  *JSContextGroupRef;
typedef struct OpaqueJSValue         *JSObjectRef;
typedef const struct OpaqueJSValue   *JSValueRef;
typedef struct OpaqueJSString        *JSStringRef;
typedef struct OpaqueJSClass         *JSClassRef;
typedef struct OpaqueJSPropertyNameAccumulator *JSPropertyNameAccumulatorRef;

/* ---------- TypedArray ---------- */
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

/* ---------- 本工程用到的三个 C 函数 ---------- */

/* 建一个 TypedArray；成功返回对象，失败返回 NULL 并通过 exception 回传异常 */
JSObjectRef JSObjectMakeTypedArray(JSGlobalContextRef ctx,
                                   JSTypedArrayType arrayType,
                                   size_t length,
                                   JSValueRef *exception);

/* 取 TypedArray 的裸内存指针（直接 memcpy 进去，零拷贝） */
void *JSObjectGetTypedArrayBytesPtr(JSGlobalContextRef ctx,
                                    JSObjectRef array,
                                    JSValueRef *exception);

/* 取长度（备用） */
size_t JSObjectGetTypedArrayLength(JSGlobalContextRef ctx,
                                   JSObjectRef array,
                                   JSValueRef *exception);

#ifdef __cplusplus
}
#endif

/* ---------- Objective-C 包装层 ---------- */

/* JSContext 的 exceptionHandler 里用到 JSValue，必须先做前向声明，
   否则 clang 报 unknown type name 'JSValue'; did you mean 'NSValue'? */
@class JSValue;
@class JSContext;

@interface JSContext : NSObject
/* 底层 C 上下文，用于 TypedArray 这类 C API */
@property (readonly) JSGlobalContextRef JSGlobalContextRef;
/* JS 侧未捕获异常回调 */
@property (copy) void (^exceptionHandler)(JSContext *context, JSValue *exception);
- (JSValue *)objectForKeyedSubscript:(id)key;
- (void)setObject:(id)object forKeyedSubscript:(id)key;

/* 执行 JS 脚本（工程用它把 engine.js 喂进上下文） */
- (JSValue *)evaluateScript:(NSString *)script;
- (JSValue *)evaluateScript:(NSString *)script withSourceURL:(NSURL *)sourceURL;
@end

@interface JSValue : NSObject
/* 底层 C 值，用于和 C API 互操作 */
@property (readonly) JSValueRef JSValueRef;

+ (JSValue *)valueWithObject:(id)value inContext:(JSContext *)context;
+ (JSValue *)valueWithNullInContext:(JSContext *)context;
+ (JSValue *)valueWithUndefinedInContext:(JSContext *)context;
+ (JSValue *)valueWithNewObjectInContext:(JSContext *)context;
+ (JSValue *)valueWithNewArrayInContext:(JSContext *)context;
+ (JSValue *)valueWithBool:(BOOL)value inContext:(JSContext *)context;
+ (JSValue *)valueWithDouble:(double)value inContext:(JSContext *)context;
+ (JSValue *)valueWithJSValueRef:(JSValueRef)value inContext:(JSContext *)context;

- (JSValue *)callWithArguments:(NSArray *)arguments;
- (JSValue *)constructWithArguments:(NSArray *)arguments;
- (JSValue *)invokeMethod:(NSString *)method withArguments:(NSArray *)arguments;

- (JSValue *)objectForKeyedSubscript:(id)key;
- (void)setObject:(id)object forKeyedSubscript:(id)key;

- (BOOL)isUndefined;
- (BOOL)isNull;
- (BOOL)isBoolean;
- (BOOL)isNumber;
- (BOOL)isString;
- (BOOL)isObject;
- (BOOL)isArray;

- (BOOL)toBool;
- (double)toDouble;
- (NSNumber *)toNumber;
- (NSString *)toString;
- (NSArray *)toArray;
- (NSDictionary *)toDictionary;
- (id)toObject;
@end

#endif /* JJ_MINI_JAVASCRIPTCORE_H */
