#include "LocalAIBridge.h"
#include <llama/llama.h>
#include <llama/mtmd.h>
#include <llama/mtmd-helper.h>
#include <llama/ggml-backend.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <TargetConditionals.h>

using Clock = std::chrono::steady_clock;
static double seconds(Clock::time_point start) { return std::chrono::duration<double>(Clock::now() - start).count(); }
struct lai_cancellation { std::atomic<bool> cancelled{false}; };
struct lai_engine {
    llama_model * model = nullptr;
    llama_context * context = nullptr;
    std::string path;
    std::string experts_path;
    uint32_t expert_cache_slots = 0;
    uint32_t batch_size = 0;
    uint32_t context_size = 0;
    bool gpu = true;
};
static bool aborted(void * value) { return value && static_cast<lai_cancellation *>(value)->cancelled.load(); }
static bool loading(float, void * value) { return !aborted(value); }
static void quiet_log(ggml_log_level, const char * text, void *) {
    // Explicit developer-only diagnostics; production never logs prompts or pages.
    if (std::getenv("SOULO_LOCAL_AI_DIAGNOSTICS")) std::fputs(text, stderr);
}
extern "C" {
lai_engine * lai_engine_create() {
    static std::once_flag once;
    std::call_once(once, [] { llama_log_set(quiet_log, nullptr); mtmd_helper_log_set(quiet_log, nullptr); ggml_backend_load_all(); llama_backend_init(); });
    return new lai_engine();
}
void lai_engine_unload(lai_engine * e) {
    if (!e) return;
    if (e->context) { llama_free(e->context); e->context = nullptr; }
    if (e->model) { llama_model_free(e->model); e->model = nullptr; }
    e->path.clear(); e->experts_path.clear();
}
void lai_engine_free(lai_engine * e) { lai_engine_unload(e); delete e; }
lai_cancellation * lai_cancellation_create() { return new lai_cancellation(); }
void lai_cancellation_cancel(lai_cancellation * c) { if (c) c->cancelled.store(true); }
void lai_cancellation_free(lai_cancellation * c) { delete c; }

int32_t lai_generate(lai_engine * e, const char * model_path, const char * projector_path,
                     const char * experts_path, uint32_t expert_cache_slots, uint32_t prefill_batch_size,
                     const char * system, const char * prompt, const char * grammar, const lai_message * history, size_t history_count,
                     const uint8_t * image, size_t image_length,
                     uint32_t context_size, uint32_t maximum_tokens, bool use_gpu,
                     lai_cancellation * cancellation, lai_text_callback callback, void * user, lai_metrics * metrics) {
    if (!e || !model_path || !system || !prompt || !metrics) return 2;
    *metrics = {};
    const auto start = Clock::now();
    try {
        if (aborted(cancellation)) return 1;
        const int threads = std::max(1, std::min(4, (int)std::thread::hardware_concurrency()));
        const std::string experts = experts_path ? experts_path : "";
        const bool moe = !experts.empty();
        // A tiny prefill batch rereads most experts for every small prompt
        // segment. Keep long agent catalogs in a few larger I/O passes.
        const int batch_size = moe ? std::max(32u, std::min(prefill_batch_size, 512u)) : 128;
        if (!e->model || e->path != model_path || e->context_size != context_size || e->gpu != use_gpu || e->experts_path != experts || e->expert_cache_slots != expert_cache_slots || e->batch_size != batch_size) {
            lai_engine_unload(e);
            e->experts_path = experts;
            e->expert_cache_slots = expert_cache_slots;
            e->batch_size = batch_size;
            auto mp = llama_model_default_params();
            mp.n_gpu_layers = use_gpu ? 99 : 0;
            if (moe) {
                // This pinned engine exposes cache sizing through these two
                // environment keys. Only this actor owns the native engine.
                const std::string cache = std::to_string(expert_cache_slots);
                setenv("LLAMA_MOE_DECODE_WINDOW", cache.c_str(), 1);
                setenv("LLAMA_MOE_LOOKAHEAD_PREFETCH_DEPTH", "4", 1);
                setenv("LLAMA_MOE_LOOKAHEAD_PREFETCH", "1", 1);
                #if TARGET_OS_IOS && !TARGET_OS_SIMULATOR
                // Expert banks already provide the bounded cache. Avoid a
                // second, unbounded file cache for multi-GB phone shards.
                setenv("LLAMA_MOE_F_NOCACHE", "1", 1);
                #endif
                mp.moe_experts_path = e->experts_path.c_str();
                mp.moe_slot_bank = 256;
                mp.use_mmap = true;
            }
            mp.progress_callback = loading; mp.progress_callback_user_data = cancellation;
            e->model = llama_model_load_from_file(model_path, mp);
            if (!e->model) return aborted(cancellation) ? 1 : 2;
            auto cp = llama_context_default_params();
            cp.n_ctx = context_size; cp.n_batch = batch_size; cp.n_ubatch = batch_size;
            cp.n_threads = threads; cp.n_threads_batch = threads;
            cp.offload_kqv = use_gpu; cp.op_offload = use_gpu;
            cp.abort_callback = aborted; cp.abort_callback_data = cancellation;
            e->context = llama_init_from_model(e->model, cp);
            if (!e->context) { lai_engine_unload(e); return aborted(cancellation) ? 1 : 2; }
            e->path = model_path; e->context_size = context_size; e->gpu = use_gpu;
        }
        metrics->load_seconds = seconds(start);
        llama_set_abort_callback(e->context, aborted, cancellation);
        llama_memory_clear(llama_get_memory(e->context), true);
        struct ClearMemory {
            llama_context * context;
            ~ClearMemory() { llama_memory_clear(llama_get_memory(context), true); llama_set_abort_callback(context, nullptr, nullptr); }
        } clear{e->context};

        std::unique_ptr<mtmd_context, decltype(&mtmd_free)> vision(nullptr, mtmd_free);
        std::unique_ptr<mtmd_bitmap, decltype(&mtmd_bitmap_free)> bitmap(nullptr, mtmd_bitmap_free);
        std::string user_prompt(prompt);
        if (image && image_length) {
            if (!projector_path || !*projector_path) return 6;
            auto vp = mtmd_context_params_default();
            vp.use_gpu = use_gpu; vp.n_threads = threads; vp.warmup = false;
            vp.image_max_tokens = moe ? 512 : 1024; vp.image_max_slice_nums = 1;
            vision.reset(mtmd_init_from_file(projector_path, e->model, vp));
            if (!vision) return aborted(cancellation) ? 1 : 6;
            if (aborted(cancellation)) return 1;
            bitmap.reset(mtmd_helper_bitmap_init_from_buf(vision.get(), image, image_length));
            if (!bitmap) return 6;
            user_prompt = std::string(mtmd_default_marker()) + "\n" + user_prompt;
        }
        std::vector<llama_chat_message> messages{{"system", system}};
        if (history) for (size_t i = 0; i < std::min(history_count, size_t(12)); ++i) {
            if (history[i].content) messages.push_back({history[i].is_user ? "user" : "assistant", history[i].content});
        }
        messages.push_back({"user", user_prompt.c_str()});
        const char * tmpl = llama_model_chat_template(e->model, nullptr);
        const int required = llama_chat_apply_template(tmpl, messages.data(), messages.size(), true, nullptr, 0);
        if (required <= 0) return 5;
        std::vector<char> formatted(required + 256);
        int length = llama_chat_apply_template(tmpl, messages.data(), messages.size(), true, formatted.data(), (int)formatted.size());
        if (length < 0 || length >= (int)formatted.size()) return 5;
        std::string text(formatted.data(), length);
        // Qwen-family templates default to an open reasoning block. The small
        // mobile assistant uses instruct mode to spend tokens on its answer.
        if (text.size() >= 8 && text.compare(text.size() - 8, 8, "<think>\n") == 0) text += "\n</think>\n";
        else if (tmpl && std::string(tmpl).find("<think>") != std::string::npos) text += "<think>\n\n</think>\n";

        int32_t n_past = 0;
        const uint32_t budget = std::min(maximum_tokens, context_size / 2);
        if (vision) {
            std::unique_ptr<mtmd_input_chunks, decltype(&mtmd_input_chunks_free)> chunks(mtmd_input_chunks_init(), mtmd_input_chunks_free);
            mtmd_input_text input{};
            input.text = text.c_str();
            input.add_special = true; input.parse_special = true;
            const mtmd_bitmap * images[] = {bitmap.get()};
            if (mtmd_tokenize(vision.get(), chunks.get(), &input, images, 1) != 0) return 6;
            metrics->prompt_tokens = (int32_t)mtmd_helper_get_n_tokens(chunks.get());
            if (metrics->prompt_tokens + budget >= context_size) return 3;
            if (mtmd_helper_eval_chunks(vision.get(), e->context, chunks.get(), 0, 0, batch_size, true, &n_past) != 0) return aborted(cancellation) ? 1 : 4;
        } else {
            const auto vocab = llama_model_get_vocab(e->model);
            int count = -llama_tokenize(vocab, text.c_str(), (int)text.size(), nullptr, 0, true, true);
            if (count <= 0) return 4;
            if (count + budget >= context_size) return 3;
            std::vector<llama_token> tokens(count);
            count = llama_tokenize(vocab, text.c_str(), (int)text.size(), tokens.data(), count, true, true);
            if (count <= 0) return 4;
            metrics->prompt_tokens = count;
            for (int i = 0; i < count; i += batch_size) {
                if (aborted(cancellation)) return 1;
                const int n = std::min(batch_size, count - i);
                if (llama_decode(e->context, llama_batch_get_one(tokens.data() + i, n)) != 0) return aborted(cancellation) ? 1 : 4;
            }
            n_past = count;
        }
        auto params = llama_sampler_chain_default_params();
        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(llama_sampler_chain_init(params), llama_sampler_free);
        if (grammar && *grammar) {
            auto constrained = llama_sampler_init_grammar(llama_model_get_vocab(e->model), grammar, "root");
            if (!constrained) return 4;
            llama_sampler_chain_add(sampler.get(), constrained);
            // Tool plans select actions rather than generate creative prose.
            // Greedy decoding avoids sampling an unrelated capability or action.
            llama_sampler_chain_add(sampler.get(), llama_sampler_init_greedy());
        } else {
            llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_k(40));
            llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_p(0.9f, 1));
            llama_sampler_chain_add(sampler.get(), llama_sampler_init_temp(0.35f));
            llama_sampler_chain_add(sampler.get(), llama_sampler_init_dist(42));
        }
        std::string output;
        const auto generation_start = Clock::now();
        for (uint32_t i = 0; i < budget && n_past < (int32_t)context_size - 1; ++i, ++n_past) {
            if (aborted(cancellation)) return 1;
            auto token = llama_sampler_sample(sampler.get(), e->context, -1);
            if (llama_vocab_is_eog(llama_model_get_vocab(e->model), token)) break;
            char piece[512];
            int n = llama_token_to_piece(llama_model_get_vocab(e->model), token, piece, sizeof(piece), 0, false);
            if (n < 0) return 4;
            output.append(piece, n);
            metrics->generated_tokens++;
            if (metrics->generated_tokens == 1) metrics->first_token_seconds = seconds(start);
            if (callback) callback(output.data(), output.size(), user);
            if (llama_decode(e->context, llama_batch_get_one(&token, 1)) != 0) return aborted(cancellation) ? 1 : 4;
        }
        metrics->generation_seconds = seconds(generation_start);
        return 0;
    } catch (...) { lai_engine_unload(e); return aborted(cancellation) ? 1 : 4; }
}
}
