"""Fetches the prebuilt WebRTC XCFramework."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

# AttilaTheFun's fork, carrying an M148 macOS header fix not yet upstream in
# stasel/WebRTC. Version and checksum match what app_engine resolves through
# SwiftPM, so both repos build against the identical binary.
_VERSION = "148.0.0"
_SHA256 = "71a43f67e8fa142134c9509b5f18cec12df11364a48cb4c492dd63b4e7fd46d4"

def _webrtc_impl(_ctx):
    http_archive(
        name = "webrtc",
        build_file = "//third_party/webrtc:webrtc.BUILD",
        sha256 = _SHA256,
        url = "https://github.com/AttilaTheFun/WebRTC/releases/download/{v}/WebRTC-M{m}.xcframework.zip".format(
            v = _VERSION,
            m = _VERSION.split(".")[0],
        ),
    )

webrtc = module_extension(implementation = _webrtc_impl)
