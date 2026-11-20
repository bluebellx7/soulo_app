#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct SouloHLSMux SouloHLSMux;
typedef bool (*SouloHLSMuxWrite)(void *context, const uint8_t *bytes, size_t count);

// Source strings are NUL-terminated. The synchronous writer borrows its bytes
// only for the duration of the call. All operations use the creating thread.
SouloHLSMux *soulo_hls_mux_create(const char *library, size_t library_length,
                                 const char *setup, size_t setup_length,
                                 SouloHLSMuxWrite writer, void *context);
bool soulo_hls_mux_push(SouloHLSMux *mux, const uint8_t *bytes, size_t count);
bool soulo_hls_mux_flush(SouloHLSMux *mux);
bool soulo_hls_mux_set_decode_time(SouloHLSMux *mux, double ticks);
void soulo_hls_mux_destroy(SouloHLSMux *mux);
