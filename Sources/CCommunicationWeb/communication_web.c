// The exports Web/communication_webrtc.js calls: memory for what it hands
// over, and its events and results, passed to the Swift host's handlers.
#include "communication_web.h"

#if defined(__wasm__)

#include <stdlib.h>

static cw_web_event_fn event_handler;
static cw_web_result_fn result_handler;

void cw_web_set_handlers(cw_web_event_fn on_event, cw_web_result_fn on_result) {
    event_handler = on_event;
    result_handler = on_result;
}

/// Memory the JavaScript writes strings and bytes into before a call.
__attribute__((export_name("communication_webrtc_alloc"))) void *communication_webrtc_alloc(size_t size) {
    return malloc(size > 0 ? size : 1);
}

__attribute__((export_name("communication_webrtc_free"))) void communication_webrtc_free(void *pointer) {
    free(pointer);
}

__attribute__((export_name("communication_webrtc_event"))) void communication_webrtc_event(
    int32_t connection, int32_t kind, const char *channel, size_t channel_length, const char *text, size_t text_length,
    const uint8_t *data, size_t data_length) {
    if (event_handler) event_handler(connection, kind, channel, channel_length, text, text_length, data, data_length);
}

__attribute__((export_name("communication_webrtc_result"))) void communication_webrtc_result(int32_t token, int32_t ok,
                                                                                             const char *text,
                                                                                             size_t length) {
    if (result_handler) result_handler(token, ok, text, length);
}

#endif
