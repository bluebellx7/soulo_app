#include "include/SouloHLSMux.h"
#include "../Source/quickjs.h"

#include <stdlib.h>

struct SouloHLSMux {
    JSRuntime *runtime;
    JSContext *context;
    JSValue transmuxer;
    SouloHLSMuxWrite writer;
    void *writer_context;
};

static JSValue write_fragment(JSContext *context, JSValueConst receiver,
                              int count, JSValueConst *arguments) {
    if (count != 1) return JS_ThrowTypeError(context, "Expected one MP4 fragment");
    size_t offset, length, capacity;
    JSValue buffer = JS_GetTypedArrayBuffer(context, arguments[0], &offset, &length, NULL);
    if (JS_IsException(buffer)) return buffer;
    uint8_t *bytes = JS_GetArrayBuffer(context, &capacity, buffer);
    SouloHLSMux *mux = JS_GetContextOpaque(context);
    bool written = bytes && offset <= capacity && length > 0 && length <= capacity - offset
        && mux->writer(mux->writer_context, bytes + offset, length);
    JS_FreeValue(context, buffer);
    return written ? JS_UNDEFINED : JS_ThrowInternalError(context, "Could not write MP4 fragment");
}

static bool evaluate(JSContext *context, const char *source, size_t length, const char *filename) {
    JSValue result = JS_Eval(context, source, length, filename, JS_EVAL_TYPE_GLOBAL);
    bool succeeded = !JS_IsException(result);
    JS_FreeValue(context, result);
    return succeeded;
}

SouloHLSMux *soulo_hls_mux_create(const char *library, size_t library_length,
                                 const char *setup, size_t setup_length,
                                 SouloHLSMuxWrite writer, void *writer_context) {
    SouloHLSMux *mux = calloc(1, sizeof(*mux));
    if (!mux) return NULL;
    mux->transmuxer = JS_UNDEFINED;
    mux->writer = writer;
    mux->writer_context = writer_context;
    mux->runtime = JS_NewRuntime();
    if (!mux->runtime) goto failed;
    mux->context = JS_NewContext(mux->runtime);
    if (!mux->context) goto failed;
    JSContext *context = mux->context;
    JS_SetContextOpaque(context, mux);
    JSValue global = JS_GetGlobalObject(context);
    JSValue handler = JS_NewCFunction(context, write_fragment, "souloWrite", 1);
    if (JS_IsException(handler) || JS_SetPropertyStr(context, global, "souloWrite", handler) < 0 ||
        !evaluate(context, library, library_length, "mux.js") ||
        !evaluate(context, setup, setup_length, "soulo-mux.js")) {
        JS_FreeValue(context, global);
        goto failed;
    }
    mux->transmuxer = JS_GetPropertyStr(context, global, "souloMux");
    JS_FreeValue(context, global);
    if (!JS_IsObject(mux->transmuxer)) goto failed;
    return mux;

failed:
    soulo_hls_mux_destroy(mux);
    return NULL;
}

static bool call(SouloHLSMux *mux, const char *name, int count, JSValueConst *arguments) {
    JSContext *context = mux->context;
    JSValue method = JS_GetPropertyStr(context, mux->transmuxer, name);
    if (JS_IsException(method)) return false;
    JSValue result = JS_Call(context, method, mux->transmuxer, count, arguments);
    bool succeeded = !JS_IsException(result);
    JS_FreeValue(context, result);
    JS_FreeValue(context, method);
    return succeeded;
}

bool soulo_hls_mux_push(SouloHLSMux *mux, const uint8_t *bytes, size_t count) {
    JSContext *context = mux->context;
    JSValue buffer = JS_NewArrayBufferCopy(context, bytes, count);
    if (JS_IsException(buffer)) return false;
    JSValueConst arguments[] = { buffer, JS_UNDEFINED, JS_UNDEFINED };
    JSValue array = JS_NewTypedArray(context, 3, arguments, JS_TYPED_ARRAY_UINT8);
    JS_FreeValue(context, buffer);
    if (JS_IsException(array)) return false;
    bool succeeded = call(mux, "push", 1, &array);
    JS_FreeValue(context, array);
    return succeeded;
}

bool soulo_hls_mux_flush(SouloHLSMux *mux) {
    return call(mux, "flush", 0, NULL);
}

bool soulo_hls_mux_set_decode_time(SouloHLSMux *mux, double ticks) {
    JSValue time = JS_NewFloat64(mux->context, ticks);
    return call(mux, "setBaseMediaDecodeTime", 1, &time);
}

void soulo_hls_mux_destroy(SouloHLSMux *mux) {
    if (!mux) return;
    if (mux->context) {
        JS_FreeValue(mux->context, mux->transmuxer);
        JS_FreeContext(mux->context);
    }
    if (mux->runtime) JS_FreeRuntime(mux->runtime);
    free(mux);
}
