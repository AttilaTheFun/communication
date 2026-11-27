# The web backend's test

CommunicationWeb over a real browser's RTCPeerConnection: two connections in
one page negotiate, open a channel, carry text and bytes both ways, and
close. A package of its own, so JavaScriptKit (whose event loop runs Swift's
concurrency on the browser's) is the test's dependency, not Communication's.

```sh
cd Tests/WebLoopback
swift package --swift-sdk swift-6.4.2-RELEASE_wasm js --use-cdn --product WebLoopback
ln -sfn ../.build/plugins/PackageToJS/outputs/Package Page/Package
cp ../../Web/communication_webrtc.js Page/
(cd Page && npm ci && npx playwright install --with-deps chromium && node run.mjs)
```
