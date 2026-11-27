// CWebRTC's loopback test, in C so it uses only the C interface: two peers
// in one process negotiate, trade candidates, open a channel, and send text
// and bytes each way. Labels in use: both open "dup" before they connect,
// so each side's copy from the other collides with its own and is closed
// (a peer can't take over a channel by its label), and b's own second
// "chat" is refused; "chat" still carries text after. Exits 0 when every
// message arrived and both "dup"s were turned away.
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "cwebrtc.h"

typedef struct side side;
struct side {
    const char *name;
    cw_peer *peer;
    side *other;
    int open;
    int got_text;
    int got_bytes;
    int got_again;
    int dup_closed;
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;

// Candidates are queued and added from the main thread: callbacks mustn't
// call back into CWebRTC.
typedef struct { side *to; char *candidate; char *mid; int index; } pending;
static pending queue[256];
static int queued = 0;

static char *field(const char *json, const char *key) {
    char pattern[64];
    snprintf(pattern, sizeof pattern, "\"%s\":", key);
    const char *at = strstr(json, pattern);
    if (!at) return NULL;
    at += strlen(pattern);
    if (*at != '"') return strndup(at, strcspn(at, ",}"));
    at++;
    const char *end = at;
    while (*end && !(*end == '"' && end[-1] != '\\')) end++;
    return strndup(at, (size_t)(end - at));
}

static void on_event(void *context, int32_t kind, const char *channel, const char *text, const uint8_t *data,
                     size_t length) {
    side *s = context;
    pthread_mutex_lock(&lock);
    switch (kind) {
    case CW_EVENT_CANDIDATE:
        if (queued < 256) {
            char *index = field(text, "sdpMLineIndex");
            queue[queued++] = (pending){s->other, field(text, "candidate"), field(text, "sdpMid"), index ? atoi(index) : 0};
            free(index);
        }
        break;
    case CW_EVENT_CHANNEL_STATE:
        printf("%s: channel %s %s\n", s->name, channel, text);
        if (strcmp(channel, "dup") == 0) {
            if (strcmp(text, "closed") == 0) s->dup_closed = 1;
        } else if (strcmp(text, "open") == 0) {
            s->open = 1;
        }
        break;
    case CW_EVENT_CONNECTION_STATE:
        printf("%s: connection %s\n", s->name, text);
        break;
    case CW_EVENT_TEXT_MESSAGE:
        printf("%s: text \"%s\" (%zu bytes) on %s\n", s->name, text, length, channel);
        if (strstr(text, "again")) s->got_again = 1;
        else s->got_text = 1;
        break;
    case CW_EVENT_DATA_MESSAGE:
        printf("%s: %zu bytes on %s\n", s->name, length, channel);
        if (length == 3 && data[0] == 1 && data[2] == 3) s->got_bytes = 1;
        break;
    }
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
}

typedef struct { int done; char *error; char *type; char *sdp; } outcome;

static void on_result(void *context, const char *error, const char *type, const char *sdp) {
    outcome *o = context;
    pthread_mutex_lock(&lock);
    o->error = error ? strdup(error) : NULL;
    o->type = type ? strdup(type) : NULL;
    o->sdp = sdp ? strdup(sdp) : NULL;
    o->done = 1;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
}

static void await(outcome *o, const char *what) {
    pthread_mutex_lock(&lock);
    while (!o->done) pthread_cond_wait(&changed, &lock);
    pthread_mutex_unlock(&lock);
    if (o->error) {
        fprintf(stderr, "%s failed: %s\n", what, o->error);
        exit(1);
    }
}

// Adds the queued candidates, and waits (up to 20 s) for done().
static int until(int (*done)(side *, side *), side *a, side *b) {
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        pthread_mutex_lock(&lock);
        int n = queued;
        pending taken[256];
        memcpy(taken, queue, sizeof(pending) * (size_t)n);
        queued = 0;
        int finished = done(a, b);
        pthread_mutex_unlock(&lock);
        for (int i = 0; i < n; i++) {
            outcome o = {0};
            cw_peer_add_candidate(taken[i].to->peer, taken[i].candidate, taken[i].mid, taken[i].index, on_result, &o);
            await(&o, "add candidate");
        }
        if (finished) return 1;
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec > 20) return 0;
        struct timespec pause = {0, 20 * 1000 * 1000};
        nanosleep(&pause, NULL);
    }
}

static int both_open(side *a, side *b) { return a->open && b->open; }
static int all_received(side *a, side *b) { return a->got_text && a->got_bytes && b->got_text && b->got_bytes; }
static int again_received(side *a, side *b) { return a->got_again && b->got_again; }
static int dups_closed(side *a, side *b) { return a->dup_closed && b->dup_closed; }

int main(void) {
    char error[256];
    cw_configuration configuration = {0};
    side a = {"a"}, b = {"b"};
    a.other = &b;
    b.other = &a;
    a.peer = cw_peer_create(&configuration, on_event, &a, error, sizeof error);
    b.peer = cw_peer_create(&configuration, on_event, &b, error, sizeof error);
    if (!a.peer || !b.peer) {
        fprintf(stderr, "create failed: %s\n", error);
        return 1;
    }
    cw_channel_configuration channel = {1, -1, -1, NULL, 0, -1};
    if (cw_peer_open_channel(a.peer, "chat", &channel, error, sizeof error) != 0) {
        fprintf(stderr, "open channel failed: %s\n", error);
        return 1;
    }
    // "dup" on both before they connect: each arrives at the other while
    // its own is there.
    if (cw_peer_open_channel(a.peer, "dup", &channel, error, sizeof error) != 0 ||
        cw_peer_open_channel(b.peer, "dup", &channel, error, sizeof error) != 0) {
        fprintf(stderr, "dup failed: %s\n", error);
        return 1;
    }

    outcome offer = {0}, set = {0}, remote = {0}, answer = {0}, set_answer = {0}, remote_answer = {0};
    cw_peer_create_offer(a.peer, 0, 0, 0, 1, on_result, &offer);
    await(&offer, "offer");
    cw_peer_set_local_description(a.peer, offer.type, offer.sdp, on_result, &set);
    await(&set, "a's local description");
    cw_peer_set_remote_description(b.peer, offer.type, offer.sdp, on_result, &remote);
    await(&remote, "b's remote description");
    cw_peer_create_answer(b.peer, 0, 0, 0, 1, on_result, &answer);
    await(&answer, "answer");
    cw_peer_set_local_description(b.peer, answer.type, answer.sdp, on_result, &set_answer);
    await(&set_answer, "b's local description");
    cw_peer_set_remote_description(a.peer, answer.type, answer.sdp, on_result, &remote_answer);
    await(&remote_answer, "a's remote description");

    outcome local = {0};
    cw_peer_local_description(a.peer, on_result, &local);
    printf("a's local description: %s\n", local.type ? local.type : "(none)");

    if (!until(both_open, &a, &b)) {
        fprintf(stderr, "the channel didn't open\n");
        return 1;
    }
    const uint8_t bytes[3] = {1, 2, 3};
    if (cw_peer_send(a.peer, "chat", (const uint8_t *)"hello from a", 12, 0) != 0 ||
        cw_peer_send(a.peer, "chat", bytes, 3, 1) != 0 ||
        cw_peer_send(b.peer, "chat", (const uint8_t *)"hello from b", 12, 0) != 0 ||
        cw_peer_send(b.peer, "chat", bytes, 3, 1) != 0) {
        fprintf(stderr, "send failed\n");
        return 1;
    }
    if (!until(all_received, &a, &b)) {
        fprintf(stderr, "not every message arrived\n");
        return 1;
    }
    // A second "chat" of b's own: its label is in use.
    if (cw_peer_open_channel(b.peer, "chat", &channel, error, sizeof error) == 0) {
        fprintf(stderr, "a second channel named chat was opened\n");
        return 1;
    }
    printf("b: second chat refused: %s\n", error);
    struct timespec settle = {1, 0};
    nanosleep(&settle, NULL);
    if (cw_peer_send(a.peer, "chat", (const uint8_t *)"a again", 7, 0) != 0 ||
        cw_peer_send(b.peer, "chat", (const uint8_t *)"b again", 7, 0) != 0) {
        fprintf(stderr, "chat stopped working after dup\n");
        return 1;
    }
    if (!until(again_received, &a, &b)) {
        fprintf(stderr, "chat's messages after dup didn't arrive\n");
        return 1;
    }
    if (!until(dups_closed, &a, &b)) {
        fprintf(stderr, "a remote dup wasn't turned away\n");
        return 1;
    }
    cw_peer_release(a.peer);
    cw_peer_release(b.peer);
    printf("loopback: ok\n");
    return 0;
}
