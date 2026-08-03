# Communication

A Swift wrapper over WebRTC for Apple platforms — peer connections, SDP,
ICE, audio, and data channels, expressed in Swift concurrency and Swift
vocabulary types rather than Objective-C callbacks and `RTC*` classes.

Extracted from `app_engine` so it can be shared. WebRTC itself stays a private
dependency: callers see `CommunicationPeerConnection`, never `RTCPeerConnection`.

## Using it

```starlark
bazel_dep(name = "communication", version = "0.1.0")
git_override(
    module_name = "communication",
    remote = "https://github.com/AttilaTheFun/communication.git",
    commit = "<sha>",
)
```

Then depend on `@communication//communication`.

## The WebRTC dependency

WebRTC ships as a prebuilt XCFramework, so it is fetched directly with
`http_archive` rather than through SwiftPM. Going via
`rules_swift_package_manager` pulls in gazelle and rules_go for what is
ultimately one zip file, and that Go toolchain does not survive Bazel 9
(`'Facts' value has no field or method 'clear'`). Consumers get a WebRTC
target and no Go.

The pin — AttilaTheFun's fork at 148.0.0, carrying an M148 macOS header fix
not yet upstream in `stasel/WebRTC` — matches what `app_engine` resolves
through SwiftPM, so both build against the identical binary.

## Data channels

`openDataChannel(label:)` on one side; the other receives the same channel
through the `dataChannelOpened` event and can `send` without opening
anything. Text and binary are kept distinct on the wire, as WebRTC does.
