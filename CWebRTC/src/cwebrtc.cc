// CWebRTC over libwebrtc's C++ API (cwebrtc.h says what each call does).
// Compiled against LiveKit's prebuilt libwebrtc with its defines and
// Chromium's libc++, and merged into its libwebrtc.a (Docs/platforms.md).

#include "cwebrtc.h"

#include <cstdio>
#include <cstring>
#include <algorithm>
#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "api/audio/audio_device.h"
#include "api/audio/create_audio_device_module.h"
#include "api/audio_codecs/builtin_audio_decoder_factory.h"
#include "api/audio_codecs/builtin_audio_encoder_factory.h"
#include "api/create_peerconnection_factory.h"
#include "api/data_channel_interface.h"
#include "api/environment/environment_factory.h"
#include "api/jsep.h"
#include "api/make_ref_counted.h"
#include "api/peer_connection_interface.h"
#include "rtc_base/thread.h"

namespace {

void copy_error(const std::string &message, char *error, size_t capacity) {
    if (error == nullptr || capacity == 0) return;
    std::snprintf(error, capacity, "%s", message.c_str());
}

// JSON string escaping, for the candidate events' RTCIceCandidateInit.
std::string json_string(const std::string &value) {
    std::string out = "\"";
    for (unsigned char c : value) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char escaped[8];
                std::snprintf(escaped, sizeof escaped, "\\u%04x", c);
                out += escaped;
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    return out + "\"";
}

std::string candidate_json(const webrtc::IceCandidate &candidate) {
    std::string sdp;
    candidate.ToString(&sdp);
    std::string json = "{\"candidate\":" + json_string(sdp) + ",\"sdpMid\":" + json_string(candidate.sdp_mid()) +
                       ",\"sdpMLineIndex\":" + std::to_string(candidate.sdp_mline_index());
    if (!candidate.server_url().empty()) json += ",\"url\":" + json_string(candidate.server_url());
    return json + "}";
}

const char *signaling_name(webrtc::PeerConnectionInterface::SignalingState state) {
    using S = webrtc::PeerConnectionInterface::SignalingState;
    switch (state) {
    case S::kStable: return "stable";
    case S::kHaveLocalOffer: return "have-local-offer";
    case S::kHaveLocalPrAnswer: return "have-local-pranswer";
    case S::kHaveRemoteOffer: return "have-remote-offer";
    case S::kHaveRemotePrAnswer: return "have-remote-pranswer";
    case S::kClosed: return "closed";
    }
    return "closed";
}

const char *ice_connection_name(webrtc::PeerConnectionInterface::IceConnectionState state) {
    using S = webrtc::PeerConnectionInterface::IceConnectionState;
    switch (state) {
    case S::kIceConnectionNew: return "new";
    case S::kIceConnectionChecking: return "checking";
    case S::kIceConnectionConnected: return "connected";
    case S::kIceConnectionCompleted: return "completed";
    case S::kIceConnectionFailed: return "failed";
    case S::kIceConnectionDisconnected: return "disconnected";
    case S::kIceConnectionClosed: return "closed";
    case S::kIceConnectionMax: break;
    }
    return "closed";
}

const char *connection_name(webrtc::PeerConnectionInterface::PeerConnectionState state) {
    using S = webrtc::PeerConnectionInterface::PeerConnectionState;
    switch (state) {
    case S::kNew: return "new";
    case S::kConnecting: return "connecting";
    case S::kConnected: return "connected";
    case S::kDisconnected: return "disconnected";
    case S::kFailed: return "failed";
    case S::kClosed: return "closed";
    }
    return "closed";
}

const char *gathering_name(webrtc::PeerConnectionInterface::IceGatheringState state) {
    using S = webrtc::PeerConnectionInterface::IceGatheringState;
    switch (state) {
    case S::kIceGatheringNew: return "new";
    case S::kIceGatheringGathering: return "gathering";
    case S::kIceGatheringComplete: return "complete";
    }
    return "complete";
}

const char *channel_name(webrtc::DataChannelInterface::DataState state) {
    using S = webrtc::DataChannelInterface::DataState;
    switch (state) {
    case S::kConnecting: return "connecting";
    case S::kOpen: return "open";
    case S::kClosing: return "closing";
    case S::kClosed: return "closed";
    }
    return "closed";
}

// One factory and its three threads for the process, made on first use.
struct Runtime {
    std::unique_ptr<webrtc::Thread> network;
    std::unique_ptr<webrtc::Thread> worker;
    std::unique_ptr<webrtc::Thread> signaling;
    webrtc::scoped_refptr<webrtc::PeerConnectionFactoryInterface> factory;

    static Runtime &shared() {
        static Runtime *runtime = [] {
            auto *made = new Runtime();
            made->network = webrtc::Thread::CreateWithSocketServer();
            made->network->SetName("cwebrtc network", nullptr);
            made->network->Start();
            made->worker = webrtc::Thread::Create();
            made->worker->SetName("cwebrtc worker", nullptr);
            made->worker->Start();
            made->signaling = webrtc::Thread::Create();
            made->signaling->SetName("cwebrtc signaling", nullptr);
            made->signaling->Start();
            // No audio device for data channels: media brings the platform's.
            auto adm = made->worker->BlockingCall([] {
                return webrtc::CreateAudioDeviceModule(webrtc::CreateEnvironment(),
                                                       webrtc::AudioDeviceModule::kDummyAudio);
            });
            made->factory = webrtc::CreatePeerConnectionFactory(
                made->network.get(), made->worker.get(), made->signaling.get(), adm,
                webrtc::CreateBuiltinAudioEncoderFactory(), webrtc::CreateBuiltinAudioDecoderFactory(), nullptr,
                nullptr, nullptr, nullptr);
            return made;
        }();
        return *runtime;
    }
};

class ChannelObserver;

// An operation's cw_result_fn, called once: by libwebrtc's observer when it
// ends, or by cw_peer_release for one it never ended (libwebrtc doesn't
// promise to call the observers of a connection it destroys).
struct Pending {
    std::atomic<bool> finished{false};
    cw_result_fn done;
    void *context;
    Pending(cw_result_fn done, void *context) : done(done), context(context) {}
    void finish(const char *error, const char *type, const char *sdp) {
        if (!finished.exchange(true)) done(context, error, type, sdp);
    }
};

}  // namespace

struct cw_peer : public webrtc::PeerConnectionObserver {
    std::mutex lock;
    cw_event_fn on_event = nullptr;
    void *context = nullptr;
    bool closed = false;
    webrtc::scoped_refptr<webrtc::PeerConnectionInterface> connection;
    // Shared: an adopt in progress holds its observer until it has
    // registered it, even if another adopt replaces it meanwhile.
    std::map<std::string, std::shared_ptr<ChannelObserver>> channels;
    // Operations started and maybe not yet ended, for cw_peer_release.
    // Held strongly: an observer libwebrtc drops unended must still end.
    std::vector<std::shared_ptr<Pending>> pending;

    // Events go out under the lock, so cw_peer_release, which clears
    // on_event under it, waits for one in progress and none follow.
    void emit(int32_t kind, const std::string &channel = "", const std::string &text = "",
              const uint8_t *data = nullptr, size_t length = 0) {
        std::lock_guard<std::mutex> guard(lock);
        if (on_event == nullptr) return;
        on_event(context, kind, channel.c_str(), text.c_str(), data, length);
    }

    // Labels a local open has claimed but not yet adopted (the channel is
    // made on the signaling thread, after cw_peer_open_channel checked).
    std::set<std::string> reserved;

    // Whether a channel named label is open (any state but closed) or
    // claimed by a local open in progress. With lock held.
    bool label_taken_locked(const std::string &label);
    // Claims label for a local open: false when it's taken.
    bool reserve(const std::string &label);
    void unreserve(const std::string &label);
    // Takes a channel: false (and the channel closed) for a remote one whose
    // label is in use.
    bool adopt(webrtc::scoped_refptr<webrtc::DataChannelInterface> channel, bool remote);

    // webrtc::PeerConnectionObserver
    void OnSignalingChange(webrtc::PeerConnectionInterface::SignalingState state) override {
        emit(CW_EVENT_SIGNALING_STATE, "", signaling_name(state));
    }
    void OnDataChannel(webrtc::scoped_refptr<webrtc::DataChannelInterface> channel) override { adopt(channel, true); }
    void OnNegotiationNeededEvent(uint32_t) override { emit(CW_EVENT_NEGOTIATION_NEEDED); }
    void OnStandardizedIceConnectionChange(webrtc::PeerConnectionInterface::IceConnectionState state) override {
        emit(CW_EVENT_ICE_CONNECTION_STATE, "", ice_connection_name(state));
    }
    void OnConnectionChange(webrtc::PeerConnectionInterface::PeerConnectionState state) override {
        emit(CW_EVENT_CONNECTION_STATE, "", connection_name(state));
    }
    void OnIceGatheringChange(webrtc::PeerConnectionInterface::IceGatheringState state) override {
        emit(CW_EVENT_ICE_GATHERING_STATE, "", gathering_name(state));
    }
    void OnIceCandidate(const webrtc::IceCandidate *candidate) override {
        if (candidate != nullptr) emit(CW_EVENT_CANDIDATE, "", candidate_json(*candidate));
    }
};

namespace {

// A channel's observer. It unregisters itself when it goes, so libwebrtc
// never calls a freed one, however adopts interleave; once retired (its
// channel replaced) it reports nothing more; and it reports each state once,
// so a state seen by adopt and by OnStateChange isn't reported twice.
class ChannelObserver : public webrtc::DataChannelObserver {
  public:
    ChannelObserver(cw_peer *peer, webrtc::scoped_refptr<webrtc::DataChannelInterface> channel)
        : peer_(peer), channel_(std::move(channel)), label_(channel_->label()) {}

    ~ChannelObserver() override { channel_->UnregisterObserver(); }

    // A reference of the caller's own, so the channel outlives a close or a
    // replacement on another thread.
    webrtc::scoped_refptr<webrtc::DataChannelInterface> channel() const { return channel_; }

    void retire() { current_ = false; }

    // The channel's state, if it's changed since the last report.
    void report_state() {
        if (!current_) return;
        const char *state = channel_name(channel_->state());
        {
            std::lock_guard<std::mutex> guard(reported_lock_);
            if (state == reported_) return;
            reported_ = state;
        }
        peer_->emit(CW_EVENT_CHANNEL_STATE, label_, state);
    }

    void OnStateChange() override { report_state(); }
    void OnMessage(const webrtc::DataBuffer &buffer) override {
        if (!current_) return;
        const auto *bytes = reinterpret_cast<const uint8_t *>(buffer.data.data());
        if (buffer.binary) {
            peer_->emit(CW_EVENT_DATA_MESSAGE, label_, "", bytes, buffer.data.size());
        } else {
            // The UTF-8 in data and length too: text stops at a NUL.
            peer_->emit(CW_EVENT_TEXT_MESSAGE, label_,
                        std::string(reinterpret_cast<const char *>(bytes), buffer.data.size()), bytes,
                        buffer.data.size());
        }
    }

  private:
    cw_peer *peer_;
    webrtc::scoped_refptr<webrtc::DataChannelInterface> channel_;
    std::string label_;
    std::atomic<bool> current_{true};
    std::mutex reported_lock_;
    // channel_name's strings are static, so they compare by pointer.
    const char *reported_ = nullptr;
};

// The end of an operation, to its cw_result_fn exactly once.
struct Result {
    std::shared_ptr<Pending> pending;
    void operator()(const webrtc::RTCError &error, const webrtc::SessionDescriptionInterface *description = nullptr) const {
        if (!error.ok()) {
            pending->finish(error.message()[0] != '\0' ? error.message() : "WebRTC operation failed", nullptr, nullptr);
            return;
        }
        if (description == nullptr) {
            pending->finish(nullptr, nullptr, nullptr);
            return;
        }
        std::string sdp;
        description->ToString(&sdp);
        pending->finish(nullptr, webrtc::SdpTypeToString(description->GetType()), sdp.c_str());
    }
};

// A Result for an operation on peer, which cw_peer_release can finish.
Result result_for(cw_peer *peer, cw_result_fn done, void *context) {
    auto made = std::make_shared<Pending>(done, context);
    std::lock_guard<std::mutex> guard(peer->lock);
    auto &list = peer->pending;
    list.erase(std::remove_if(list.begin(), list.end(), [](const std::shared_ptr<Pending> &p) { return p->finished.load(); }),
               list.end());
    list.push_back(made);
    return Result{made};
}

class CreateObserver : public webrtc::CreateSessionDescriptionObserver {
  public:
    explicit CreateObserver(Result result) : result_(result) {}
    void OnSuccess(webrtc::SessionDescriptionInterface *description) override {
        std::unique_ptr<webrtc::SessionDescriptionInterface> owned(description);
        result_(webrtc::RTCError::OK(), owned.get());
    }
    void OnFailure(webrtc::RTCError error) override { result_(error); }

  private:
    Result result_;
};

class SetLocalObserver : public webrtc::SetLocalDescriptionObserverInterface {
  public:
    explicit SetLocalObserver(Result result) : result_(result) {}
    void OnSetLocalDescriptionComplete(webrtc::RTCError error) override { result_(error); }

  private:
    Result result_;
};

class SetRemoteObserver : public webrtc::SetRemoteDescriptionObserverInterface {
  public:
    explicit SetRemoteObserver(Result result) : result_(result) {}
    void OnSetRemoteDescriptionComplete(webrtc::RTCError error) override { result_(error); }

  private:
    Result result_;
};

webrtc::PeerConnectionInterface::RTCOfferAnswerOptions answer_options(int32_t ice_restart, int32_t audio,
                                                                      int32_t video, int32_t vad) {
    webrtc::PeerConnectionInterface::RTCOfferAnswerOptions options;
    options.ice_restart = ice_restart != 0;
    options.offer_to_receive_audio = audio != 0 ? 1 : 0;
    options.offer_to_receive_video = video != 0 ? 1 : 0;
    options.voice_activity_detection = vad != 0;
    return options;
}

std::unique_ptr<webrtc::SessionDescriptionInterface> description(const char *type, const char *sdp,
                                                                 std::string *problem) {
    auto parsed = webrtc::SdpTypeFromString(type != nullptr ? type : "");
    if (!parsed) {
        *problem = std::string("Unknown session description type: ") + (type != nullptr ? type : "");
        return nullptr;
    }
    webrtc::SdpParseError error;
    auto made = webrtc::CreateSessionDescription(*parsed, sdp != nullptr ? sdp : "", &error);
    if (!made) *problem = "Invalid SDP: " + error.description + " (" + error.line + ")";
    return made;
}

webrtc::scoped_refptr<webrtc::PeerConnectionInterface> connection_of(cw_peer *peer) {
    std::lock_guard<std::mutex> guard(peer->lock);
    return peer->connection;
}

// Ends every operation libwebrtc hasn't, with error.
void finish_pending(cw_peer *peer, const char *error) {
    std::vector<std::shared_ptr<Pending>> pending;
    {
        std::lock_guard<std::mutex> guard(peer->lock);
        pending = std::move(peer->pending);
    }
    for (auto &left : pending) left->finish(error, nullptr, nullptr);
}

}  // namespace

bool cw_peer::label_taken_locked(const std::string &label) {
    if (reserved.count(label) != 0) return true;
    auto found = channels.find(label);
    return found != channels.end() && found->second->channel()->state() != webrtc::DataChannelInterface::kClosed;
}

bool cw_peer::reserve(const std::string &label) {
    std::lock_guard<std::mutex> guard(lock);
    if (label_taken_locked(label)) return false;
    reserved.insert(label);
    return true;
}

void cw_peer::unreserve(const std::string &label) {
    std::lock_guard<std::mutex> guard(lock);
    reserved.erase(label);
}

// Channels are named by label (as WebRTCHost names them), one at a time: a
// local open claims its label before the channel is made (cw_peer_open_channel),
// and fails when it's taken; a remote channel whose label is open or
// claimed is closed here, unannounced, so a peer can't take over or close
// the app's channels by reusing their labels. The check and the taking of
// the slot happen under one hold of the lock, so nothing can come between
// them. A label is free again once its channel has closed; whatever a new
// channel replaces is closed, and its observer unregistered before it goes,
// so libwebrtc never calls a freed one.
bool cw_peer::adopt(webrtc::scoped_refptr<webrtc::DataChannelInterface> channel, bool remote) {
    std::string label = channel->label();
    auto observer = std::make_shared<ChannelObserver>(this, channel);
    std::shared_ptr<ChannelObserver> replaced;
    bool turned_away = false;
    {
        std::lock_guard<std::mutex> guard(lock);
        if (remote && label_taken_locked(label)) {
            turned_away = true;
        } else {
            if (!remote) reserved.erase(label);
            auto &slot = channels[label];
            replaced = std::move(slot);
            slot = observer;
        }
    }
    if (turned_away) {
        channel->Close();
        return false;
    }
    if (replaced) {
        replaced->retire();
        auto old = replaced->channel();
        if (old->state() != webrtc::DataChannelInterface::kClosed) old->Close();
    }
    // The state first, then the observer, which libwebrtc may hand what it
    // buffered (messages) at once. Registered outside the lock (delivering
    // emits, which takes it); `observer` keeps it alive until then even if
    // another adopt has replaced it, and its destructor unregisters it.
    observer->report_state();
    channel->RegisterObserver(observer.get());
    return true;
}

extern "C" {

cw_peer *cw_peer_create(const cw_configuration *configuration, cw_event_fn on_event, void *context, char *error,
                        size_t error_capacity) {
    auto &runtime = Runtime::shared();
    if (!runtime.factory) {
        copy_error("Unable to create the WebRTC factory.", error, error_capacity);
        return nullptr;
    }
    webrtc::PeerConnectionInterface::RTCConfiguration rtc;
    rtc.sdp_semantics = webrtc::SdpSemantics::kUnifiedPlan;
    if (configuration != nullptr) {
        for (size_t i = 0; i < configuration->ice_server_count; i++) {
            const cw_ice_server &server = configuration->ice_servers[i];
            webrtc::PeerConnectionInterface::IceServer ice;
            for (size_t u = 0; u < server.url_count; u++) ice.urls.emplace_back(server.urls[u]);
            if (server.username != nullptr) ice.username = server.username;
            if (server.credential != nullptr) ice.password = server.credential;
            rtc.servers.push_back(ice);
        }
        rtc.type = configuration->relay_only != 0 ? webrtc::PeerConnectionInterface::kRelay
                                                  : webrtc::PeerConnectionInterface::kAll;
        rtc.continual_gathering_policy = configuration->gather_continually != 0
                                             ? webrtc::PeerConnectionInterface::GATHER_CONTINUALLY
                                             : webrtc::PeerConnectionInterface::GATHER_ONCE;
        rtc.candidate_network_policy = configuration->low_cost_networks != 0
                                           ? webrtc::PeerConnectionInterface::kCandidateNetworkPolicyLowCost
                                           : webrtc::PeerConnectionInterface::kCandidateNetworkPolicyAll;
    }
    auto *peer = new cw_peer();
    peer->on_event = on_event;
    peer->context = context;
    auto made = runtime.factory->CreatePeerConnectionOrError(rtc, webrtc::PeerConnectionDependencies(peer));
    if (!made.ok()) {
        copy_error(made.error().message(), error, error_capacity);
        delete peer;
        return nullptr;
    }
    std::lock_guard<std::mutex> guard(peer->lock);
    peer->connection = made.MoveValue();
    return peer;
}

void cw_peer_create_offer(cw_peer *peer, int32_t ice_restart, int32_t receive_audio, int32_t receive_video,
                          int32_t voice_activity_detection, cw_result_fn done, void *context) {
    auto connection = connection_of(peer);
    auto observer = webrtc::make_ref_counted<CreateObserver>(result_for(peer, done, context));
    if (!connection) return observer->OnFailure(webrtc::RTCError(webrtc::RTCErrorType::INVALID_STATE, "Closed."));
    connection->CreateOffer(observer.get(),
                            answer_options(ice_restart, receive_audio, receive_video, voice_activity_detection));
}

void cw_peer_create_answer(cw_peer *peer, int32_t ice_restart, int32_t receive_audio, int32_t receive_video,
                           int32_t voice_activity_detection, cw_result_fn done, void *context) {
    auto connection = connection_of(peer);
    auto observer = webrtc::make_ref_counted<CreateObserver>(result_for(peer, done, context));
    if (!connection) return observer->OnFailure(webrtc::RTCError(webrtc::RTCErrorType::INVALID_STATE, "Closed."));
    connection->CreateAnswer(observer.get(),
                             answer_options(ice_restart, receive_audio, receive_video, voice_activity_detection));
}

void cw_peer_set_local_description(cw_peer *peer, const char *type, const char *sdp, cw_result_fn done,
                                   void *context) {
    Result result = result_for(peer, done, context);
    std::string problem;
    auto parsed = description(type, sdp, &problem);
    auto connection = connection_of(peer);
    if (!parsed) return result(webrtc::RTCError(webrtc::RTCErrorType::INVALID_PARAMETER, problem));
    if (!connection) return result(webrtc::RTCError(webrtc::RTCErrorType::INVALID_STATE, "Closed."));
    connection->SetLocalDescription(std::move(parsed), webrtc::make_ref_counted<SetLocalObserver>(result));
}

void cw_peer_set_remote_description(cw_peer *peer, const char *type, const char *sdp, cw_result_fn done,
                                    void *context) {
    Result result = result_for(peer, done, context);
    std::string problem;
    auto parsed = description(type, sdp, &problem);
    auto connection = connection_of(peer);
    if (!parsed) return result(webrtc::RTCError(webrtc::RTCErrorType::INVALID_PARAMETER, problem));
    if (!connection) return result(webrtc::RTCError(webrtc::RTCErrorType::INVALID_STATE, "Closed."));
    connection->SetRemoteDescription(std::move(parsed), webrtc::make_ref_counted<SetRemoteObserver>(result));
}

void cw_peer_local_description(cw_peer *peer, cw_result_fn done, void *context) {
    auto connection = connection_of(peer);
    if (!connection) return done(context, nullptr, nullptr, nullptr);
    // Read on the signaling thread, where the description lives.
    std::string type, sdp;
    bool has = Runtime::shared().signaling->BlockingCall([&] {
        const auto *local = connection->local_description();
        if (local == nullptr) return false;
        type = webrtc::SdpTypeToString(local->GetType());
        local->ToString(&sdp);
        return true;
    });
    if (has) {
        done(context, nullptr, type.c_str(), sdp.c_str());
    } else {
        done(context, nullptr, nullptr, nullptr);
    }
}

void cw_peer_add_candidate(cw_peer *peer, const char *candidate, const char *sdp_mid, int32_t sdp_mline_index,
                           cw_result_fn done, void *context) {
    Result result = result_for(peer, done, context);
    auto connection = connection_of(peer);
    if (!connection) return result(webrtc::RTCError(webrtc::RTCErrorType::INVALID_STATE, "Closed."));
    webrtc::SdpParseError error;
    std::unique_ptr<webrtc::IceCandidate> parsed(webrtc::CreateIceCandidate(
        sdp_mid != nullptr ? sdp_mid : "", sdp_mline_index < 0 ? 0 : sdp_mline_index,
        candidate != nullptr ? candidate : "", &error));
    if (!parsed) {
        return result(webrtc::RTCError(webrtc::RTCErrorType::INVALID_PARAMETER, "Invalid candidate: " + error.description));
    }
    connection->AddIceCandidate(std::move(parsed), [result](webrtc::RTCError outcome) { result(outcome); });
}

void cw_peer_restart_ice(cw_peer *peer) {
    if (auto connection = connection_of(peer)) connection->RestartIce();
}

int32_t cw_peer_open_channel(cw_peer *peer, const char *label, const cw_channel_configuration *configuration,
                             char *error, size_t error_capacity) {
    auto connection = connection_of(peer);
    if (!connection) {
        copy_error("Closed.", error, error_capacity);
        return -1;
    }
    std::string name = label != nullptr ? label : "";
    // Claimed now, under the lock, so a remote channel with the label that
    // arrives before this one is made is turned away.
    if (!peer->reserve(name)) {
        copy_error("A data channel named " + name + " is open.", error, error_capacity);
        return -1;
    }
    webrtc::DataChannelInit init;
    if (configuration != nullptr) {
        init.ordered = configuration->ordered != 0;
        if (configuration->max_packet_life_time >= 0) init.maxRetransmitTime = configuration->max_packet_life_time;
        if (configuration->max_retransmits >= 0) init.maxRetransmits = configuration->max_retransmits;
        if (configuration->protocol != nullptr) init.protocol = configuration->protocol;
        init.negotiated = configuration->negotiated != 0;
        if (configuration->id >= 0) init.id = configuration->id;
    }
    auto made = connection->CreateDataChannelOrError(name, &init);
    if (!made.ok()) {
        peer->unreserve(name);
        copy_error(made.error().message(), error, error_capacity);
        return -1;
    }
    peer->adopt(made.MoveValue(), false);
    return 0;
}

int32_t cw_peer_send(cw_peer *peer, const char *label, const uint8_t *data, size_t length, int32_t binary) {
    webrtc::scoped_refptr<webrtc::DataChannelInterface> channel;
    {
        std::lock_guard<std::mutex> guard(peer->lock);
        auto found = peer->channels.find(label != nullptr ? label : "");
        if (found != peer->channels.end()) channel = found->second->channel();
    }
    if (!channel || channel->state() != webrtc::DataChannelInterface::kOpen) return -1;
    webrtc::CopyOnWriteBuffer buffer(data, length);
    return channel->Send(webrtc::DataBuffer(buffer, binary != 0)) ? 0 : -1;
}

void cw_peer_close(cw_peer *peer) {
    webrtc::scoped_refptr<webrtc::PeerConnectionInterface> connection;
    std::vector<webrtc::scoped_refptr<webrtc::DataChannelInterface>> channels;
    {
        std::lock_guard<std::mutex> guard(peer->lock);
        if (peer->closed) return;
        peer->closed = true;
        connection = peer->connection;
        for (auto &entry : peer->channels) channels.push_back(entry.second->channel());
    }
    for (auto &channel : channels) channel->Close();
    if (connection) connection->Close();
    // An operation libwebrtc never ended ends now, so a caller awaiting it
    // across a close (which holds the peer, so it isn't released) returns.
    finish_pending(peer, "The peer connection was closed.");
    peer->emit(CW_EVENT_CLOSED);
}

void cw_peer_release(cw_peer *peer) {
    if (peer == nullptr) return;
    {
        std::lock_guard<std::mutex> guard(peer->lock);
        peer->on_event = nullptr;
    }
    cw_peer_close(peer);
    webrtc::scoped_refptr<webrtc::PeerConnectionInterface> connection;
    std::map<std::string, std::shared_ptr<ChannelObserver>> channels;
    {
        std::lock_guard<std::mutex> guard(peer->lock);
        connection = std::move(peer->connection);
        channels = std::move(peer->channels);
    }
    // Each observer unregisters itself as it goes (channels.clear() below).
    for (auto &entry : channels) entry.second->retire();
    // The connection goes before its observer, peer, does.
    connection = nullptr;
    channels.clear();
    // What libwebrtc never ended ends now.
    finish_pending(peer, "The peer connection was released.");
    delete peer;
}

}  // extern "C"
