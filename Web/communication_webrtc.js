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
//
// Pointers and lengths are wasm32's unsigned 32-bit values, read with
// `>>> 0` so memory past 2 GB works.

// WebRTCHostEvent.Kind's numbers.
const Kind = {
  closed: 0, signalingState: 1, iceConnectionState: 2, connectionState: 3, iceGatheringState: 4,
  candidate: 5, negotiationNeeded: 7, channelState: 8, textMessage: 9, dataMessage: 10,
};

// The largest message handed to the module: a remote can't make it copy
// more than this into its memory at once. A bigger one closes its channel.
const maxMessage = 16 * 1024 * 1024;

export class CommunicationWebRTC {
  constructor() {
    this.source = null;
    this.connections = new Map();
    this.nextID = 1;
    // Each import guarded: a synchronous throw (bad memory, a closed
    // connection) gives the import's failure value, or a failed result for
    // its token, rather than unwinding into the module and stranding a
    // continuation.
    const guarded = (failure, body) => (...args) => {
      try {
        return body(...args.map((a) => (typeof a === "number" ? a >>> 0 : a)));
      } catch (error) {
        console.error("communication_webrtc:", error);
        return failure(...args);
      }
    };
    const failed = (token) => (...args) => {
      this.resultSafely(args[token] >>> 0, false, "The browser's WebRTC failed.");
    };
    this.imports = {
      create: guarded(() => -1, (pointer, length) => this.create(this.read(pointer, length))),
      offer: guarded(failed(4), (id, answer, pointer, length, token) => this.offer(id, answer, this.read(pointer, length), token)),
      set_description: guarded(failed(4), (id, local, pointer, length, token) =>
        this.setDescription(id, local, this.read(pointer, length), token)),
      local_description: guarded(failed(1), (id, token) => this.localDescription(id, token)),
      add_candidate: guarded(failed(3), (id, pointer, length, token) => this.addCandidate(id, this.read(pointer, length), token)),
      restart_ice: guarded(() => {}, (id) => this.connections.get(id)?.pc.restartIce()),
      open_channel: guarded(() => -1, (id, label, labelLength, init, initLength) =>
        this.openChannel(id, this.read(label, labelLength), this.read(init, initLength))),
      send: guarded(() => -1, (id, label, labelLength, pointer, length, binary) =>
        this.send(id, this.read(label, labelLength), this.bytes(pointer, length), binary)),
      close: guarded(() => {}, (id) => this.close(id)),
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
    return new TextDecoder().decode(new Uint8Array(this.exports.memory.buffer, pointer >>> 0, length >>> 0));
  }

  bytes(pointer, length) {
    return new Uint8Array(this.exports.memory.buffer, pointer >>> 0, length >>> 0).slice();
  }

  // Copies bytes into the module's memory for one call: [pointer, length].
  // Throws when the module can't allocate them (it answers 0).
  write(bytes) {
    const pointer = this.exports.communication_webrtc_alloc(bytes.length) >>> 0;
    if (pointer === 0) throw new Error(`The module couldn't allocate ${bytes.length} bytes.`);
    new Uint8Array(this.exports.memory.buffer, pointer, bytes.length).set(bytes);
    return [pointer, bytes.length];
  }

  // Runs call with each of buffers written into the module's memory, and
  // frees what was written, whatever happens.
  withWritten(buffers, call) {
    const written = [];
    try {
      for (const buffer of buffers) written.push(this.write(buffer));
      call(written);
    } finally {
      for (const [pointer] of written) this.exports.communication_webrtc_free(pointer);
    }
  }

  // MARK: To the module

  event(id, kind, channel = "", text = "", data = null) {
    const encoder = new TextEncoder();
    try {
      this.withWritten([encoder.encode(channel), encoder.encode(text), data ?? new Uint8Array(0)], ([c, t, d]) => {
        this.exports.communication_webrtc_event(id, kind, c[0], c[1], t[0], t[1], d[0], d[1]);
      });
    } catch (error) {
      // A trap means the module is broken: it goes on up, not swallowed
      // with the module's state half-changed.
      if (error instanceof WebAssembly.RuntimeError) throw error;
      console.error("communication_webrtc: an event was lost:", error);
      // The end of a connection still reaches the module, with nothing to
      // write, so its pulls don't wait for ever.
      if (kind === Kind.closed) this.exports.communication_webrtc_event(id, kind, 0, 0, 0, 0, 0, 0);
    }
  }

  result(token, ok, text) {
    this.withWritten([new TextEncoder().encode(text)], ([[pointer, length]]) => {
      this.exports.communication_webrtc_result(token, ok ? 1 : 0, pointer, length);
    });
  }

  // A result that can't be written at all (no memory) still ends its call:
  // a failure with no text.
  resultSafely(token, ok, text) {
    try {
      this.result(token, ok, text);
    } catch {
      try {
        this.exports.communication_webrtc_result(token, 0, 0, 0);
      } catch (error) {
        console.error("communication_webrtc: a result was lost:", error);
      }
    }
  }

  async settle(token, work) {
    let outcome;
    try {
      outcome = [true, (await work()) ?? ""];
    } catch (error) {
      outcome = [false, String(error?.message ?? error)];
    }
    this.resultSafely(token, ...outcome);
  }

  // MARK: Connections

  create(configuration) {
    let pc;
    try {
      // `native` is libwebrtc's alone, and so is the "noHost" ICE transport
      // policy: browsers have only "all" and "relay", so "noHost" is "all"
      // here (host candidates included).
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
    pc.ondatachannel = (e) => this.adopt(id, entry, e.channel, true);
    return id;
  }

  // Whether a channel named label is open (in any state but closed).
  labelInUse(entry, label) {
    const channel = entry.channels.get(label);
    return channel !== undefined && channel.readyState !== "closed";
  }

  // Channels are named by label (as WebRTCHost names them), one at a time,
  // as CWebRTC has it: a local one with a label in use is refused by
  // openChannel, and a remote one is closed here, unannounced, so a peer
  // can't take over or close the app's channels by reusing their labels.
  // A label is free again once its channel has closed.
  adopt(id, entry, channel, remote) {
    const label = channel.label;
    if (remote && this.labelInUse(entry, label)) {
      channel.close();
      return false;
    }
    const old = entry.channels.get(label);
    if (old) {
      old.onopen = old.onclose = old.onclosing = old.onerror = old.onmessage = null;
      if (old.readyState !== "closed") old.close();
    }
    channel.binaryType = "arraybuffer";
    entry.channels.set(label, channel);
    // Each state once: an error (which may come while open or closing)
    // reports only a change, so the core never sees "open" twice.
    let reported = null;
    const state = () => {
      if (entry.channels.get(label) !== channel || channel.readyState === reported) return;
      reported = channel.readyState;
      this.event(id, Kind.channelState, label, reported);
    };
    channel.onopen = state;
    channel.onclosing = state;
    channel.onclose = state;
    // A channel the remote fails or drops ends as closed, reported.
    channel.onerror = state;
    // A message over maxMessage closes the channel, said in the console:
    // the peer is sending more than the module takes.
    const tooBig = (size) => {
      console.warn(`communication_webrtc: a ${size}-byte message on ${label} is over ${maxMessage}; the channel is closed`);
      channel.close();
    };
    channel.onmessage = (e) => {
      if (typeof e.data === "string") {
        // The UTF-8 once, in data, as CWebRTC sends a text message.
        const utf8 = new TextEncoder().encode(e.data);
        if (utf8.length > maxMessage) return tooBig(utf8.length);
        this.event(id, Kind.textMessage, label, "", utf8);
      } else {
        if (e.data.byteLength > maxMessage) return tooBig(e.data.byteLength);
        this.event(id, Kind.dataMessage, label, "", new Uint8Array(e.data));
      }
    };
    state();
    return true;
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
    if (!entry || this.labelInUse(entry, label)) return -1;
    try {
      const init = JSON.parse(configuration || "{}");
      for (const key of Object.keys(init)) if (init[key] === null) delete init[key];
      this.adopt(id, entry, entry.pc.createDataChannel(label, init), false);
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
    // Nothing more comes from the browser for it: its handlers go first.
    for (const channel of entry.channels.values()) {
      channel.onopen = channel.onclose = channel.onclosing = channel.onerror = channel.onmessage = null;
      channel.close();
    }
    const pc = entry.pc;
    pc.onsignalingstatechange = pc.oniceconnectionstatechange = pc.onconnectionstatechange = null;
    pc.onicegatheringstatechange = pc.onicecandidate = pc.onnegotiationneeded = pc.ondatachannel = null;
    pc.close();
    this.connections.delete(id);
    this.event(id, Kind.connectionState, "", "closed");
    this.event(id, Kind.closed);
  }
}
