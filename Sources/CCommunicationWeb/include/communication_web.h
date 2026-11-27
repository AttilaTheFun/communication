// The web backend's way to the browser's WebRTC (Docs/platforms.md): wasm
// imports from the module "communication_webrtc", which Web/communication_webrtc.js
// implements over RTCPeerConnection, and the exports it calls back with.
// Plain C, so the package needs no Swift experimental features or flags.
// On anything but wasm it declares nothing.
#ifndef COMMUNICATION_WEB_H
#define COMMUNICATION_WEB_H

#include <stddef.h>
#include <stdint.h>

#if defined(__wasm__)

#define CW_WEB_IMPORT(name) __attribute__((import_module("communication_webrtc"), import_name(#name)))

/// A new RTCPeerConnection from an RTCConfiguration (JSON): its id, or -1.
CW_WEB_IMPORT(create) int32_t cw_web_create(const char *configuration, size_t length);
/// createOffer (answer 0) or createAnswer (answer 1) with RTCOfferOptions
/// (JSON); the RTCSessionDescriptionInit comes to the result for token.
CW_WEB_IMPORT(offer) void cw_web_offer(int32_t connection, int32_t answer, const char *options, size_t length,
                                       int32_t token);
/// setLocalDescription (local 1) or setRemoteDescription (local 0).
CW_WEB_IMPORT(set_description) void cw_web_set_description(int32_t connection, int32_t local, const char *description,
                                                           size_t length, int32_t token);
/// The current local description (JSON), or "" when there is none.
CW_WEB_IMPORT(local_description) void cw_web_local_description(int32_t connection, int32_t token);
/// addIceCandidate with an RTCIceCandidateInit (JSON).
CW_WEB_IMPORT(add_candidate) void cw_web_add_candidate(int32_t connection, const char *candidate, size_t length,
                                                       int32_t token);
CW_WEB_IMPORT(restart_ice) void cw_web_restart_ice(int32_t connection);
/// createDataChannel with an RTCDataChannelInit (JSON): 0, or -1.
CW_WEB_IMPORT(open_channel) int32_t cw_web_open_channel(int32_t connection, const char *label, size_t label_length,
                                                        const char *configuration, size_t configuration_length);
/// Sends on an open channel: 0, or -1.
CW_WEB_IMPORT(send) int32_t cw_web_send(int32_t connection, const char *label, size_t label_length, const uint8_t *data,
                                        size_t length, int32_t binary);
/// Closes the connection and its channels; its events end with kind 0.
CW_WEB_IMPORT(close) void cw_web_close(int32_t connection);

/// An event on a connection (the kinds are WebRTCHostEvent.Kind's), and
/// the end of an operation (ok 1 with its JSON, or ok 0 with the error).
typedef void (*cw_web_event_fn)(int32_t connection, int32_t kind, const char *channel, size_t channel_length,
                                const char *text, size_t text_length, const uint8_t *data, size_t data_length);
typedef void (*cw_web_result_fn)(int32_t token, int32_t ok, const char *text, size_t length);

/// Where the exports below send what the JavaScript reports: set once, by
/// the Swift host, before its first connection.
void cw_web_set_handlers(cw_web_event_fn on_event, cw_web_result_fn on_result);

#endif

#endif
