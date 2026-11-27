// Android: libc++'s __hash_memory, for an app whose libc++ is older than the
// one LiveKit's Android libwebrtc was built with (NDK r30), such as r27's,
// which Swift's Android SDK sets up with. Weak, so a libc++ that has it wins.
// libwebrtc's own hash tables are the only users through this symbol, so
// its value only has to be the same throughout the process: 64-bit FNV-1a.
#include <cstddef>
#include <cstdint>

namespace std {
inline namespace __ndk1 {

[[gnu::weak]] size_t __hash_memory(const void *pointer, size_t length) noexcept {
    const auto *bytes = static_cast<const unsigned char *>(pointer);
    uint64_t hash = 1469598103934665603ull;
    for (size_t i = 0; i < length; i++) {
        hash ^= bytes[i];
        hash *= 1099511628211ull;
    }
    return static_cast<size_t>(hash);
}

}  // namespace __ndk1
}  // namespace std
