load("@rules_apple//apple:apple.bzl", "apple_dynamic_xcframework_import")

package(default_visibility = ["//visibility:public"])

# WebRTC is a dynamic framework: it must be embedded in the app bundle, which
# `apple_dynamic_xcframework_import` arranges for any binary that depends on
# it, per-platform slice.
apple_dynamic_xcframework_import(
    name = "WebRTC",
    xcframework_imports = glob(["WebRTC.xcframework/**"]),
)
