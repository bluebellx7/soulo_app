#ifndef SOULO_LOCAL_AI_BRIDGE_H
#define SOULO_LOCAL_AI_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct lai_engine lai_engine;
typedef struct lai_cancellation lai_cancellation;
typedef void (*lai_text_callback)(const char * text, size_t length, void * user);
typedef struct { bool is_user; const char * content; } lai_message;
typedef struct {
    int32_t prompt_tokens;
    int32_t generated_tokens;
    double load_seconds;
    double first_token_seconds;
    double generation_seconds;
} lai_metrics;
lai_engine * lai_engine_create(void);
void lai_engine_free(lai_engine * engine);
void lai_engine_unload(lai_engine * engine);
lai_cancellation * lai_cancellation_create(void);
void lai_cancellation_cancel(lai_cancellation * cancellation);
void lai_cancellation_free(lai_cancellation * cancellation);
// 0 success; 1 cancelled; 2 load error; 3 context too long; 4 decode error;
// 5 unsupported template; 6 image/projector error. No text is logged.
int32_t lai_generate(lai_engine * engine, const char * model_path, const char * projector_path,
                     const char * experts_path, uint32_t expert_cache_slots, uint32_t prefill_batch_size,
                     const char * system, const char * prompt, const char * grammar,
                     const lai_message * history, size_t history_count,
                     const uint8_t * image, size_t image_length,
                     uint32_t context_size, uint32_t maximum_tokens, bool use_gpu,
                     lai_cancellation * cancellation, lai_text_callback callback, void * user,
                     lai_metrics * metrics);
#ifdef __cplusplus
}
#endif
#endif
