// Communication's web backend (Docs/platforms.md): the `communication_webrtc`
// wasm imports over the browser's RTCPeerConnection, for CommunicationWeb's
// WebWebRTCHost. Plain ES, with no framework or build step.
//
//   import { CommunicationWebRTC } from "./communication_webrtc.js";
//   const webrtc = new CommunicationWebRTC();
//   const { instance } = await WebAssembly.instantiate(bytes, {
//     ...yourImports,                        // WASI and the rest
//     communication_webrtc: webrtc.imports,
//   });
//   webrtc.attach(instance.exports);         // before the module calls in
//
// Where the module runs as it's instantiated, attach a function instead,
// which gives the exports when they exist: `webrtc.attach(() => instance?.exports)`
// (PackageToJS: `addToCoreImports(imports, { getInstance })`, then
// `webrtc.attach(() => getInstance().exports)`).
//
// Any loader works the same way (Isomer's boot, JavaScriptKit's, a plain
// page): pass `webrtc.imports` under "communication_webrtc", and the
// instance's exports to `attach`. Values cross as UTF-8 in the module's
// memory: W3C JSON, and bytes for binary messages.

// WebRTCHostEvent.Kind's numbers.
const Kind = {
  closed: 0, signalingState: 1, iceConnectionState: 2, connectionState: 3, iceGatheringState: 4,
  candidate: 5, negotiationNeeded: 7, channelState: 8, textMessage: 9, dataMessage: 10,
};

export class CommunicationWebRTC {
  constructor() {
    this.source = null;
    this.connections = new Map();
    this.nextID = 1;
    const self = this;
    this.imports = {
      create: (pointer, length) => self.create(self.read(pointer, length)),
      offer: (id, answer, pointer, length, token) => self.offer(id, answer, self.read(pointer, length), token),
      set_description: (id, local, pointer, length, token) => self.setDescription(id, local, self.read(pointer, length), token),
      local_description: (id, token) => self.localDescription(id, token),
      add_candidate: (id, pointer, length, token) => self.addCandidate(id, self.read(pointer, length), token),
      restart_ice: (id) => self.connections.get(id)?.pc.restartIce(),
      open_channel: (id, label, labelLength, init, initLength) =>
        self.openChannel(id, self.read(label, labelLength), self.read(init, initLength)),
      send: (id, label, labelLength, pointer, length, binary) =>
        self.send(id, self.read(label, labelLength), self.bytes(pointer, length), binary),
      close: (id) => self.close(id),
    };
  }

  /// The instance's exports (its memory, and communication_webrtc_alloc,
  /// _free, _event and _result), or a function that gives them.
  attach(exports) {
    this.source = exports;
  }

  get exports() {
    return typeof this.source === "function" ? this.source() : this.source;
  }

  // MARK: Memory

  read(pointer, length) {
    return new TextDecoder().decode(new Uint8Array(this.exports.memory.buffer, pointer, length));
  }

  bytes(pointer, length) {
    return new Uint8Array(this.exports.memory.buffer, pointer, length).slice();
  }

  // Copies bytes into the module's memory for one call: [pointer, length].
  // The pointer is freed by the caller after the call.
  write(bytes) {
    const pointer = this.exports.communication_webrtc_alloc(bytes.length);
    new Uint8Array(this.exports.memory.buffer, pointer, bytes.length).set(bytes);
    return [pointer, bytes.length];
  }

  // MARK: To the module

  event(id, kind, channel = "", text = "", data = null) {
    const encoder = new TextEncoder();
    const parts = [encoder.encode(channel), encoder.encode(text), data ?? new Uint8Array(0)].map((b) => this.write(b));
    try {
      this.exports.communication_webrtc_event(id, kind, ...parts[0], ...parts[1], ...parts[2]);
    } finally {
      for (const [pointer] of parts) this.exports.communication_webrtc_free(pointer);
    }
  }

  result(token, ok, text) {
    const [pointer, length] = this.write(new TextEncoder().encode(text));
    try {
      this.exports.communication_webrtc_result(token, ok ? 1 : 0, pointer, length);
    } finally {
      this.exports.communication_webrtc_free(pointer);
    }
  }

  async settle(token, work) {
    try {
      this.result(token, true, (await work()) ?? "");
    } catch (error) {
      this.result(token, false, String(error?.message ?? error));
    }
  }

  // MARK: Connections

  create(configuration) {
    let pc;
    try {
      // `native` is libwebrtc's alone, and so is the "noHost" policy.
      const { native, ...rtc } = JSON.parse(configuration);
      if (rtc.iceTransportPolicy !== "relay") rtc.iceTransportPolicy = "all";
      pc = new RTCPeerConnection(rtc);
    } catch {
      return -1;
    }
    const id = this.nextID++;
    const entry = { pc, channels: new Map(), closed: false };
    this.connections.set(id, entry);
    pc.onsignalingstatechange = () => this.event(id, Kind.signalingState, "", pc.signalingState);
    pc.oniceconnectionstatechange = () => this.event(id, Kind.iceConnectionState, "", pc.iceConnectionState);
    pc.onconnectionstatechange = () => this.event(id, Kind.connectionState, "", pc.connectionState);
    pc.onicegatheringstatechange = () => this.event(id, Kind.iceGatheringState, "", pc.iceGatheringState);
    pc.onicecandidate = (e) => {
      if (e.candidate) this.event(id, Kind.candidate, "", JSON.stringify(e.candidate.toJSON()));
    };
    pc.onnegotiationneeded = () => this.event(id, Kind.negotiationNeeded);
    pc.ondatachannel = (e) => this.adopt(id, entry, e.channel);
    return id;
  }

  // A channel, named by its label as WebRTCHost names them: one with a
  // label in use replaces the old, which is closed and reported first.
  adopt(id, entry, channel) {
    channel.binaryType = "arraybuffer";
    const label = channel.label;
    const old = entry.channels.get(label);
    if (old && old !== channel) {
      old.onopen = old.onclose = old.onclosing = old.onmessage = null;
      old.close();
      this.event(id, Kind.channelState, label, "closed");
    }
    entry.channels.set(label, channel);
    const state = () => {
      if (entry.channels.get(label) === channel) this.event(id, Kind.channelState, label, channel.readyState);
    };
    channel.onopen = state;
    channel.onclosing = state;
    channel.onclose = state;
    channel.onmessage = (e) => {
      if (typeof e.data === "string") {
        const utf8 = new TextEncoder().encode(e.data);
        this.event(id, Kind.textMessage, label, e.data, utf8);
      } else {
        this.event(id, Kind.dataMessage, label, "", new Uint8Array(e.data));
      }
    };
    state();
  }

  offer(id, answer, options, token) {
    const entry = this.connections.get(id);
    this.settle(token, async () => {
      if (!entry) throw new Error(`No connection ${id}.`);
      const parsed = JSON.parse(options || "{}");
      const made = answer ? await entry.pc.createAnswer(parsed) : await entry.pc.createOffer(parsed);
      return JSON.stringify({ type: made.type, sdp: made.sdp });
    });
  }

  setDescription(id, local, description, token) {
    const entry = this.connections.get(id);
    this.settle(token, async () => {
      if (!entry) throw new Error(`No connection ${id}.`);
      const parsed = JSON.parse(description);
      if (local) await entry.pc.setLocalDescription(parsed);
      else await entry.pc.setRemoteDescription(parsed);
      return "";
    });
  }

  localDescription(id, token) {
    const local = this.connections.get(id)?.pc.localDescription;
    this.settle(token, async () => (local ? JSON.stringify({ type: local.type, sdp: local.sdp }) : ""));
  }

  addCandidate(id, candidate, token) {
    const entry = this.connections.get(id);
    this.settle(token, async () => {
      if (!entry) throw new Error(`No connection ${id}.`);
      const { url, ...init } = JSON.parse(candidate);
      await entry.pc.addIceCandidate(init);
      return "";
    });
  }

  openChannel(id, label, configuration) {
    const entry = this.connections.get(id);
    if (!entry) return -1;
    try {
      const init = JSON.parse(configuration || "{}");
      for (const key of Object.keys(init)) if (init[key] === null) delete init[key];
      this.adopt(id, entry, entry.pc.createDataChannel(label, init));
      return 0;
    } catch {
      return -1;
    }
  }

  send(id, label, bytes, binary) {
    const channel = this.connections.get(id)?.channels.get(label);
    if (!channel || channel.readyState !== "open") return -1;
    try {
      channel.send(binary ? bytes : new TextDecoder().decode(bytes));
      return 0;
    } catch {
      return -1;
    }
  }

  close(id) {
    const entry = this.connections.get(id);
    if (!entry || entry.closed) return;
    entry.closed = true;
    for (const channel of entry.channels.values()) channel.close();
    entry.pc.close();
    this.connections.delete(id);
    this.event(id, Kind.connectionState, "", "closed");
    this.event(id, Kind.closed);
  }
}
