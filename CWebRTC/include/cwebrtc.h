// CWebRTC: a C interface over libwebrtc's C++ API, for Communication's
// native backend on Linux, Windows and Android (Docs/platforms.md).
//
// It's compiled against LiveKit's prebuilt libwebrtc, with its defines and
// Chromium's libc++, and merged into its libwebrtc.a, so Swift sees only
// this header. Values are plain C; the Swift side turns them into and out
// of the W3C dictionaries.
//
// Threads: every callback runs on libwebrtc's signaling thread. A callback
// must not call back into this interface, or free what its context points
// to; copy what it gives and return. Strings handed to a callback live only
// for that call.
//
// Lifetimes: a peer's on_event and context are used until cw_peer_release
// returns, and not after. Every cw_result_fn is called exactly once:
// cw_peer_close and cw_peer_release end what libwebrtc hasn't, with an
// error, so a context it owns can be freed there.
#ifndef CWEBRTC_H
#define CWEBRTC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A peer connection.
typedef struct cw_peer cw_peer;

/// Event kinds, the same numbers as Communication's WebRTCHostEvent.Kind.
enum {
    CW_EVENT_CLOSED = 0,
    CW_EVENT_SIGNALING_STATE = 1,      // text: the W3C signaling state
    CW_EVENT_ICE_CONNECTION_STATE = 2, // text: the W3C ICE connection state
    CW_EVENT_CONNECTION_STATE = 3,     // text: the W3C connection state
    CW_EVENT_ICE_GATHERING_STATE = 4,  // text: the W3C ICE gathering state
    CW_EVENT_CANDIDATE = 5,            // text: an RTCIceCandidateInit (JSON)
    CW_EVENT_CANDIDATES_REMOVED = 6,   // text: a JSON array of RTCIceCandidateInit
    CW_EVENT_NEGOTIATION_NEEDED = 7,
    CW_EVENT_CHANNEL_STATE = 8,        // channel, text: its W3C ready state
    CW_EVENT_TEXT_MESSAGE = 9,         // channel, text; its UTF-8 in data and length too
    CW_EVENT_DATA_MESSAGE = 10,        // channel, data and length
};

/// Something that happened on a peer connection.
typedef void (*cw_event_fn)(void *context, int32_t kind, const char *channel, const char *text,
                            const uint8_t *data, size_t length);

/// The end of an asynchronous call: error is NULL when it succeeded. A call
/// that makes a description gives its type ("offer", "answer", …) and SDP;
/// the others give NULL for both.
typedef void (*cw_result_fn)(void *context, const char *error, const char *type, const char *sdp);

/// An ICE server: its URLs, and the credentials TURN takes.
typedef struct {
    const char *const *urls;
    size_t url_count;
    const char *username;   // or NULL
    const char *credential; // or NULL
} cw_ice_server;

/// What a peer connection is made with.
typedef struct {
    const cw_ice_server *ice_servers;
    size_t ice_server_count;
    int32_t relay_only;           // iceTransportPolicy "relay"
    int32_t gather_continually;   // keep gathering as networks change
    int32_t low_cost_networks;    // candidateNetworkPolicy "low-cost"
} cw_configuration;

/// A data channel's RTCDataChannelInit; -1 where a number isn't given.
typedef struct {
    int32_t ordered;
    int32_t max_packet_life_time;
    int32_t max_retransmits;
    const char *protocol; // or NULL
    int32_t negotiated;
    int32_t id;
} cw_channel_configuration;

/// A new peer connection, or NULL with the reason in error (at most
/// error_capacity bytes, NUL-terminated). Events go to on_event with
/// context until cw_peer_release.
cw_peer *cw_peer_create(const cw_configuration *configuration, cw_event_fn on_event, void *context,
                        char *error, size_t error_capacity);

void cw_peer_create_offer(cw_peer *peer, int32_t ice_restart, int32_t receive_audio, int32_t receive_video,
                          int32_t voice_activity_detection, cw_result_fn done, void *context);
void cw_peer_create_answer(cw_peer *peer, int32_t ice_restart, int32_t receive_audio, int32_t receive_video,
                           int32_t voice_activity_detection, cw_result_fn done, void *context);
void cw_peer_set_local_description(cw_peer *peer, const char *type, const char *sdp, cw_result_fn done,
                                   void *context);
void cw_peer_set_remote_description(cw_peer *peer, const char *type, const char *sdp, cw_result_fn done,
                                    void *context);
/// The current local description, given to done before this returns
/// (type and SDP NULL when there is none).
void cw_peer_local_description(cw_peer *peer, cw_result_fn done, void *context);
/// sdp_mline_index is -1 when not given; sdp_mid may be NULL.
void cw_peer_add_candidate(cw_peer *peer, const char *candidate, const char *sdp_mid, int32_t sdp_mline_index,
                           cw_result_fn done, void *context);
void cw_peer_restart_ice(cw_peer *peer);

/// Opens a data channel: 0, or -1 with the reason in error. It's reported
/// with CW_EVENT_CHANNEL_STATE as it opens, as channels the remote opens are.
/// Channels are named by label: a new one (ours or the remote's) with a
/// label in use replaces the old, which is closed and reported "closed"
/// first.
int32_t cw_peer_open_channel(cw_peer *peer, const char *label, const cw_channel_configuration *configuration,
                             char *error, size_t error_capacity);
/// Sends on an open channel: 0, or -1 when it can't.
int32_t cw_peer_send(cw_peer *peer, const char *label, const uint8_t *data, size_t length, int32_t binary);

/// Closes the connection and its channels, then reports CW_EVENT_CLOSED.
void cw_peer_close(cw_peer *peer);
/// Closes the connection if it's open, and frees it. No callback runs after
/// this returns.
void cw_peer_release(cw_peer *peer);

#ifdef __cplusplus
}
#endif

#endif
