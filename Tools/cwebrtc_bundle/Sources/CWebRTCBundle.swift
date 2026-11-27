import ArgumentParser
import Foundation

/// Builds CWebRTC's artifact bundle (Docs/platforms.md): for each platform,
/// LiveKit's prebuilt static libwebrtc with CWebRTC's shim compiled against
/// it and merged in, then one SE-0482 bundle naming every variant.
@main
struct CWebRTCBundle: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cwebrtc-bundle",
        abstract: "Build CWebRTC's artifact bundle from LiveKit's prebuilt libwebrtc.",
        subcommands: [Variant.self, Assemble.self, Pin.self, NextVersion.self, Prepare.self, Verify.self]
    )
}

/// The platforms CWebRTC is built for: LiveKit's release names, and the
/// triples SwiftPM picks a variant by.
enum Platform: String, CaseIterable, ExpressibleByArgument {
    case linuxX64 = "linux-x64"
    case linuxArm64 = "linux-arm64"
    case androidArm64 = "android-arm64"
    case androidX64 = "android-x64"

    /// The Swift target triple the variant is for (SE-0482's supportedTriples):
    /// Android's as swift.org's Swift SDK for Android builds, API 28.
    var triple: String {
        switch self {
        case .linuxX64: "x86_64-unknown-linux-gnu"
        case .linuxArm64: "aarch64-unknown-linux-gnu"
        case .androidArm64: "aarch64-unknown-linux-android28"
        case .androidX64: "x86_64-unknown-linux-android28"
        }
    }

    var isAndroid: Bool { self == .androidArm64 || self == .androidX64 }

    /// clang's target for the shim on Android, the NDK's (Linux: the host's).
    var clangTarget: String? {
        switch self {
        case .linuxX64, .linuxArm64: nil
        case .androidArm64: "aarch64-linux-android28"
        case .androidX64: "x86_64-linux-android28"
        }
    }

    /// The system libraries a program links beside the bundle's. Linux's
    /// libwebrtc carries Chromium's libc++, so only the C library's parts;
    /// Android's is built against the NDK's libc++ (`std::__ndk1`, the one
    /// Swift's Android runtime uses), shared, and logs to liblog.
    var linkedLibraries: [String] {
        switch self {
        case .linuxX64, .linuxArm64: ["m"]
        case .androidArm64, .androidX64: ["log", "c++_shared"]
        }
    }

    /// The shim's sources beside cwebrtc.cc: Linux's X11 stubs (C), and
    /// Android's weak libc++ `__hash_memory` for an NDK older than
    /// libwebrtc's (C++).
    var extraSources: [String] {
        switch self {
        case .linuxX64, .linuxArm64: ["x11_stubs.c"]
        case .androidArm64, .androidX64: ["android_stubs.cc"]
        }
    }
}

/// One platform's variant: LiveKit's libwebrtc with the shim merged in, its
/// header and module map, and variant.json for `assemble`.
struct Variant: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build one platform's variant.")

    @Option(help: "The platform (\(Platform.allCases.map(\.rawValue).joined(separator: ", "))).")
    var platform: Platform

    @Option(help: "LiveKit's libwebrtc release (livekit/rust-sdks), one pinned in Pins.swift, e.g. webrtc-83af826.")
    var livekit: String

    @Option(help: "CWebRTC's sources (the repository's CWebRTC folder).")
    var sources: String = "CWebRTC"

    @Option(help: "Where the variant goes: <out>/<platform>/.")
    var out: String

    @Option(help: "A folder for LiveKit's download, kept between runs.")
    var work: String = ".build/cwebrtc"

    @Option(help: "The C++ compiler.")
    var cxx: String = "clang++"

    @Option(help: "The C compiler.")
    var cc: String = "clang"

    @Option(help: "The archiver.")
    var ar: String = "llvm-ar"

    @Option(help: "The Android NDK (its root), for an Android platform: the shim is compiled against its sysroot and libc++.")
    var ndk: String?

    func run() throws {
        let fm = FileManager.default
        // Only a pinned download: what's in it is linked into every program
        // that uses the package.
        guard let expected = Pins.sha256[livekit]?[platform] else {
            throw ValidationError("\(livekit) has no pinned SHA-256 for \(platform.rawValue) in Pins.swift")
        }
        let work = URL(fileURLWithPath: work).appendingPathComponent("\(livekit)-\(platform.rawValue)")
        let release = work.appendingPathComponent("\(platform.rawValue)-release")
        let zip = work.appendingPathComponent("webrtc.zip")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: zip.path) {
            let url = "https://github.com/livekit/rust-sdks/releases/download/\(livekit)/webrtc-\(platform.rawValue)-release.zip"
            print("cwebrtc-bundle: downloading \(url)")
            try Shell.run("curl", ["-fsSL", "--retry", "3", "-o", zip.path, url])
        }
        // Checked every run, the kept download too, before it's unpacked.
        let actual = try Self.sha256(zip)
        guard actual == expected else {
            try? fm.removeItem(at: zip)
            throw ValidationError("\(zip.lastPathComponent) for \(livekit) \(platform.rawValue) is \(actual), not the pinned \(expected)")
        }
        print("cwebrtc-bundle: \(livekit) \(platform.rawValue) matches its pinned SHA-256")
        try? fm.removeItem(at: release)
        try Shell.run("unzip", ["-q", "-o", zip.path, "-d", work.path])
        let include = release.appendingPathComponent("include")
        let defines = try Self.defines(release.appendingPathComponent("webrtc.ninja"))
        let sources = URL(fileURLWithPath: sources)
        // The C++ library the shim is compiled against: Linux's libwebrtc
        // carries Chromium's own libc++ (std::__Cr), whose headers its
        // release ships; Android's is built against the NDK's (std::__ndk1),
        // so the shim takes the NDK's sysroot and headers.
        let target: [String]
        let cxxLibrary: [String]
        if let clangTarget = platform.clangTarget {
            guard let ndk else { throw ValidationError("\(platform.rawValue) needs --ndk <the Android NDK's root>") }
            let prebuilt = URL(fileURLWithPath: ndk).appendingPathComponent("toolchains/llvm/prebuilt")
            guard let host = try fm.contentsOfDirectory(atPath: prebuilt.path).sorted().first else {
                throw ValidationError("no prebuilt toolchain in \(prebuilt.path)")
            }
            let sysroot = prebuilt.appendingPathComponent(host).appendingPathComponent("sysroot")
            target = ["--target=\(clangTarget)", "--sysroot=\(sysroot.path)", "-ffile-prefix-map=\(ndk)=ndk"]
            cxxLibrary = []
        } else {
            target = []
            cxxLibrary = [
                "-nostdinc++",
                "-isystem", include.appendingPathComponent("buildtools/third_party/libc++").path,
                "-isystem", include.appendingPathComponent("third_party/libc++/src/include").path,
                "-isystem", include.appendingPathComponent("third_party/libc++abi/src/include").path,
            ]
        }
        let objects = work.appendingPathComponent("objects")
        try? fm.removeItem(at: objects)
        try fm.createDirectory(at: objects, withIntermediateDirectories: true)

        // The shim, against libwebrtc's C++ library (above), with libwebrtc's defines.
        let shim = objects.appendingPathComponent("cwebrtc.o")
        try Shell.run(cxx, target + [
            "-std=c++20", "-O2", "-fPIC", "-w",
            // Reproducible: the build's paths don't reach the object
            // (Package.swift's checksum is rebuilt and compared).
            "-ffile-prefix-map=\(release.path)=libwebrtc", "-ffile-prefix-map=\(sources.path)=CWebRTC",
        ] + cxxLibrary + [
            "-I", include.path,
            "-I", include.appendingPathComponent("third_party/abseil-cpp").path,
            "-I", sources.appendingPathComponent("include").path,
        ] + defines + ["-c", sources.appendingPathComponent("src/cwebrtc.cc").path, "-o", shim.path])
        var added = [shim.path]
        for source in platform.extraSources {
            let object = objects.appendingPathComponent(source + ".o")
            let cplusplus = source.hasSuffix(".cc")
            try Shell.run(cplusplus ? cxx : cc, target + (cplusplus ? ["-std=c++20"] : []) + [
                "-O2", "-fPIC", "-ffile-prefix-map=\(sources.path)=CWebRTC",
                "-c", sources.appendingPathComponent("src/\(source)").path, "-o", object.path])
            added.append(object.path)
        }

        // libwebrtc.a with the shim merged in, as libcwebrtc.a.
        let variant = URL(fileURLWithPath: out).appendingPathComponent(platform.rawValue)
        try? fm.removeItem(at: variant)
        try fm.createDirectory(at: variant.appendingPathComponent("include"), withIntermediateDirectories: true)
        let library = variant.appendingPathComponent("libcwebrtc.a")
        try fm.copyItem(at: release.appendingPathComponent("lib/libwebrtc.a"), to: library)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: library.path)
        try Shell.run(ar, ["rs", library.path] + added)

        try fm.copyItem(at: sources.appendingPathComponent("include/cwebrtc.h"),
                        to: variant.appendingPathComponent("include/cwebrtc.h"))
        let links = platform.linkedLibraries.map { "    link \"\($0)\"\n" }.joined()
        try "module CWebRTC {\n    header \"cwebrtc.h\"\n\(links)    export *\n}\n"
            .write(to: variant.appendingPathComponent("include/module.modulemap"), atomically: true, encoding: .utf8)
        try fm.copyItem(at: release.appendingPathComponent("LICENSE.md"), to: variant.appendingPathComponent("LICENSE-libwebrtc.md"))
        let description = VariantDescription(platform: platform.rawValue, triple: platform.triple, livekit: livekit)
        try JSONEncoder.pretty.encode(description).write(to: variant.appendingPathComponent("variant.json"))
        print("cwebrtc-bundle: \(platform.rawValue) in \(variant.path)")
    }

    /// A file's SHA-256, hex, by coreutils' sha256sum (Swift's image has it;
    /// Foundation has no hash on Linux).
    static func sha256(_ file: URL) throws -> String {
        let line = try Shell.output("sha256sum", [file.path])
        guard let hash = line.split(separator: " ").first, hash.count == 64 else {
            throw ValidationError("sha256sum gave \(line)")
        }
        return String(hash)
    }

    /// libwebrtc's own defines, from its build's webrtc.ninja, which the
    /// shim must be compiled with to match its headers' layouts.
    static func defines(_ ninja: URL) throws -> [String] {
        let text = try String(contentsOf: ninja, encoding: .utf8)
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("defines = ") }) else {
            throw ValidationError("\(ninja.path) has no defines")
        }
        // CR_CLANG_REVISION's escaped quotes mean nothing to the shim.
        return line.dropFirst("defines = ".count).split(separator: " ").map(String.init)
            .filter { !$0.hasPrefix("-DCR_CLANG_REVISION") }
    }
}

/// The variants built by `variant`, gathered into CWebRTC.artifactbundle
/// and zipped, with the checksum Package.swift names it by.
struct Assemble: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Gather variants into the artifact bundle and zip it.")

    @Option(help: "The bundle's version (the release's), or `auto`: the one Package.swift's bundle URL names, else VERSION's line's first (X.Y.1). It's in info.json, so in the checksum: CI and the release take the one prepare did.")
    var version: String

    @Option(help: "Where the zip goes.")
    var out: String

    @Argument(help: "Folders of variants (each holding <platform>/variant.json).")
    var variants: [String]

    func run() throws {
        let version = try self.version == "auto" ? Self.autoVersion() : self.version
        let fm = FileManager.default
        let zip = URL(fileURLWithPath: out)
        let staging = zip.deletingLastPathComponent().appendingPathComponent("staging")
        let bundle = staging.appendingPathComponent("CWebRTC.artifactbundle")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        var entries: [BundleInfo.Variant] = []
        for folder in variants {
            let root = URL(fileURLWithPath: folder)
            for name in try fm.contentsOfDirectory(atPath: root.path).sorted() {
                let described = root.appendingPathComponent(name).appendingPathComponent("variant.json")
                guard fm.fileExists(atPath: described.path) else { continue }
                let variant = try JSONDecoder().decode(VariantDescription.self, from: Data(contentsOf: described))
                try fm.copyItem(at: root.appendingPathComponent(name), to: bundle.appendingPathComponent(variant.platform))
                try fm.removeItem(at: bundle.appendingPathComponent(variant.platform).appendingPathComponent("variant.json"))
                entries.append(.init(
                    path: "\(variant.platform)/libcwebrtc.a",
                    supportedTriples: [variant.triple],
                    staticLibraryMetadata: .init(headerPaths: ["\(variant.platform)/include"],
                                                 moduleMapPath: "\(variant.platform)/include/module.modulemap")
                ))
            }
        }
        guard !entries.isEmpty else { throw ValidationError("no variants in \(variants.joined(separator: ", "))") }
        let info = BundleInfo(schemaVersion: "1.0", artifacts: ["CWebRTC": .init(type: "staticLibrary", version: version, variants: entries)])
        try JSONEncoder.pretty.encode(info).write(to: bundle.appendingPathComponent("info.json"))
        try? fm.removeItem(at: zip)
        // Reproducible: every file's time fixed and the entries in order, with
        // no extra attributes, so the same variants give the same zip (and
        // checksum) wherever it's built.
        let epoch = Date(timeIntervalSince1970: 315_532_800) // 1980-01-01, zip's earliest
        var files: [String] = []
        if let walker = fm.enumerator(atPath: staging.path) {
            for case let relative as String in walker {
                try fm.setAttributes([.modificationDate: epoch], ofItemAtPath: staging.appendingPathComponent(relative).path)
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: staging.appendingPathComponent(relative).path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    files.append(relative)
                }
            }
        }
        try Shell.run("zip", ["-q", "-X", "-D", zip.path] + files.sorted(), in: staging)
        let checksum = try Shell.output("swift", ["package", "compute-checksum", zip.path]).trimmingCharacters(in: .whitespacesAndNewlines)
        print("cwebrtc-bundle: \(zip.path), \(entries.count) variants, checksum \(checksum)")
        try (checksum + "\n").write(to: zip.appendingPathExtension("checksum"), atomically: true, encoding: .utf8)
    }
}

/// Points Package.swift's CWebRTC at a bundle: a release's, by URL and
/// checksum (the release commit's), or one on disk (the release's tests,
/// before there's a release). Only the text between the cwebrtc-bundle
/// markers changes.
struct Pin: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Point Package.swift's CWebRTC at a bundle.")

    @Option(help: "The bundle's URL (a release asset).")
    var url: String?

    @Option(help: "The bundle's SwiftPM checksum, with --url.")
    var checksum: String?

    @Option(help: "A bundle on disk (a .artifactbundle folder, relative to the package).")
    var path: String?

    @Option(help: "The manifest.")
    var manifest: String = "Package.swift"

    func validate() throws {
        guard (url != nil) != (path != nil) else { throw ValidationError("give --url (with --checksum) or --path") }
        if url != nil, checksum?.count != 64 { throw ValidationError("--url needs --checksum, 64 hex digits") }
    }

    func run() throws {
        try Self.apply(url: url, checksum: checksum, path: path, manifest: manifest)
    }

    static func apply(url: String?, checksum: String?, path: String?, manifest: String) throws {
        var text = try String(contentsOfFile: manifest, encoding: .utf8)
        let target: String
        if let url, let checksum {
            target = """
                    .binaryTarget(
                        name: "CWebRTC",
                        url: "\(url)",
                        checksum: "\(checksum)"
                    ),
            """
        } else {
            target = """
                    .binaryTarget(name: "CWebRTC", path: "\(path ?? "")"),
            """
        }
        text = try Self.fill(text, "dependency", """
                        .target(name: "CWebRTC", condition: .when(platforms: [.linux])),
        """)
        text = try Self.fill(text, "target", target)
        try text.write(toFile: manifest, atomically: true, encoding: .utf8)
        print("cwebrtc-bundle: \(manifest)'s CWebRTC is \(url ?? path ?? "")")
    }

    /// The lines between `// cwebrtc-bundle: <region>` and the next
    /// `// cwebrtc-bundle: end`, replaced with body.
    static func fill(_ text: String, _ region: String, _ body: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "// cwebrtc-bundle: \(region)" }),
              let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "// cwebrtc-bundle: end" })
        else { throw ValidationError("no cwebrtc-bundle \(region) markers in the manifest") }
        lines.replaceSubrange((start + 1)..<end, with: body.components(separatedBy: "\n"))
        return lines.joined(separator: "\n")
    }
}

/// The version the next release takes: one past the highest vX.Y.N among
/// the releases (drafts too) and tags of VERSION's line X.Y, or X.Y.1. A
/// line with a published release is closed: the next needs VERSION moved on.
struct NextVersion: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next-version",
        abstract: "The next release's version, from VERSION and the repository's releases and tags."
    )

    @Option(help: "The repository (owner/name), for its releases.")
    var repository: String

    @Option(help: "The line file.")
    var versionFile: String = "VERSION"

    func run() throws {
        print(try Self.next(repository: repository, versionFile: versionFile))
    }

    static func next(repository: String, versionFile: String) throws -> String {
        let line = try String(contentsOfFile: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3, parts[2] == 0 else { throw ValidationError("\(versionFile) is \(line), not X.Y.0") }
        let prefix = "v\(parts[0]).\(parts[1])."
        struct Release: Decodable { let tagName: String; let isDraft: Bool }
        let releases = try JSONDecoder().decode([Release].self, from: Data(Shell.output("gh", [
            "release", "list", "--repo", repository, "--limit", "200", "--json", "tagName,isDraft",
        ]).utf8))
        let tags = try Shell.output("git", ["tag", "--list", "\(prefix)*"]).split(separator: "\n").map(String.init)
        if let published = releases.first(where: { $0.tagName.hasPrefix(prefix) && !$0.isDraft }) {
            throw ValidationError("\(published.tagName) is published, so the \(parts[0]).\(parts[1]) line is closed: move \(versionFile) to \(parts[0]).\(parts[1] + 1).0")
        }
        let patches = (releases.map(\.tagName) + tags).compactMap { tag -> Int? in
            guard tag.hasPrefix(prefix) else { return nil }
            return Int(tag.dropFirst(prefix.count))
        }
        return "\(parts[0]).\(parts[1]).\((patches.max() ?? 0) + 1)"
    }
}

/// The manifest's CWebRTC, as the release process reads it: the URL and
/// checksum between the cwebrtc-bundle markers, if it names a release's.
struct ManifestBundle {
    var url: String
    var checksum: String

    static func read(_ manifest: String) throws -> ManifestBundle? {
        // Only between the target's markers: the manifest names other URLs.
        let lines = try String(contentsOfFile: manifest, encoding: .utf8).components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "// cwebrtc-bundle: target" }),
              let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "// cwebrtc-bundle: end" })
        else { throw ValidationError("no cwebrtc-bundle target markers in \(manifest)") }
        let text = lines[(start + 1)..<end].joined(separator: "\n")
        func value(_ key: String) -> String? {
            guard let range = text.range(of: "\(key): \""),
                  let end = text[range.upperBound...].firstIndex(of: "\"") else { return nil }
            return String(text[range.upperBound..<end])
        }
        guard let url = value("url"), let checksum = value("checksum") else { return nil }
        return ManifestBundle(url: url, checksum: checksum)
    }

    static func url(repository: String, version: String) -> String {
        "https://github.com/\(repository)/releases/download/v\(version)/CWebRTC.artifactbundle.zip"
    }
}

func swiftPMChecksum(_ zip: String) throws -> String {
    try Shell.output("swift", ["package", "compute-checksum", zip]).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The next release, prepared on a branch for a pull request to main
/// (Docs/releasing.md): Package.swift names that release's bundle (this
/// zip, which CI and the release rebuild and compare), and CHANGELOG.md gets
/// the release's notes, the changes/ entries added since the release before.
struct Prepare: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Point Package.swift at the next release's bundle, and add its notes to CHANGELOG.md.")

    @Option(help: "The bundle (from `assemble`), reproducible from this commit.")
    var zip: String?

    @Option(help: "Or its SwiftPM checksum, from CI's bundle job for this commit (its log), which CI checks again.")
    var checksum: String?

    @Option(help: "The repository (owner/name), for the URL and its releases.")
    var repository: String

    @Option(help: "The version (default: next-version's).")
    var version: String?

    func run() throws {
        let version = try self.version ?? NextVersion.next(repository: repository, versionFile: "VERSION")
        let checksum: String
        if let zip {
            checksum = try swiftPMChecksum(zip)
        } else if let given = self.checksum, given.count == 64, given.allSatisfy(\.isHexDigit) {
            checksum = given.lowercased()
        } else {
            throw ValidationError("give --zip, or --checksum (64 hex digits)")
        }
        let url = ManifestBundle.url(repository: repository, version: version)
        try Pin.apply(url: url, checksum: checksum, path: nil, manifest: "Package.swift")
        let notes = try Notes.since(lastRelease: true)
        let changelog = try String(contentsOfFile: "CHANGELOG.md", encoding: .utf8)
        var lines = changelog.components(separatedBy: "\n")
        let header = min(3, lines.count)
        lines.insert(contentsOf: ["", "## \(version)", ""] + notes.components(separatedBy: "\n").filter { !$0.isEmpty }, at: header)
        try lines.joined(separator: "\n").write(toFile: "CHANGELOG.md", atomically: true, encoding: .utf8)
        print("cwebrtc-bundle: prepared \(version): Package.swift names \(url) (\(checksum)), CHANGELOG.md has its notes")
    }
}

/// Fails unless Package.swift names this bundle: its checksum, and, with
/// --version, that release's URL. CI runs it on every pull request (a
/// manifest that names a bundle CI doesn't reproduce fails) and the release
/// run before it drafts (failing closed).
struct Verify: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check Package.swift names this bundle.")

    @Option(help: "The bundle, rebuilt here.")
    var zip: String

    @Option(help: "The release's version: its URL must be the manifest's too.")
    var version: String?

    @Option(help: "The repository (owner/name), with --version.")
    var repository: String?

    @Option(help: "The manifest.")
    var manifest: String = "Package.swift"

    func run() throws {
        guard let named = try ManifestBundle.read(manifest) else {
            if version != nil { throw ValidationError("\(manifest) names no CWebRTC bundle: prepare the release first") }
            print("cwebrtc-bundle: \(manifest) names no bundle yet; nothing to compare")
            return
        }
        let checksum = try swiftPMChecksum(zip)
        guard named.checksum == checksum else {
            throw ValidationError("\(manifest)'s CWebRTC checksum is \(named.checksum), but this commit's bundle is \(checksum): run `cwebrtc-bundle prepare` again")
        }
        if let version, let repository {
            let expected = ManifestBundle.url(repository: repository, version: version)
            guard named.url == expected else { throw ValidationError("\(manifest)'s CWebRTC is \(named.url), not \(expected)") }
        }
        print("cwebrtc-bundle: \(manifest) names this bundle (\(checksum))")
    }
}

/// The changes/ entries added since the latest release's tag (all of them
/// before the first).
enum Notes {
    static func since(lastRelease: Bool) throws -> String {
        let before = (try? Shell.output("git", ["describe", "--tags", "--abbrev=0", "--match", "v*"], quiet: true))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let files: [String]
        if before.isEmpty {
            files = try FileManager.default.contentsOfDirectory(atPath: "changes").sorted().map { "changes/\($0)" }
        } else {
            files = try Shell.output("git", ["diff", "--diff-filter=A", "--name-only", before, "HEAD", "--", "changes/"])
                .split(separator: "\n").map(String.init)
        }
        return try files.filter { $0.hasSuffix(".md") && $0 != "changes/README.md" }
            .map { try String(contentsOfFile: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n")
    }
}

extension Assemble {
    static func autoVersion() throws -> String {
        if let named = try ManifestBundle.read("Package.swift"),
           let range = named.url.range(of: #"/v([0-9]+\.[0-9]+\.[0-9]+)/"#, options: .regularExpression) {
            return String(named.url[range].dropFirst(2).dropLast())
        }
        let line = try String(contentsOfFile: "VERSION", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: ".")
        guard parts.count == 3 else { throw ValidationError("VERSION is \(line), not X.Y.0") }
        return "\(parts[0]).\(parts[1]).1"
    }
}

struct VariantDescription: Codable {
    var platform: String
    var triple: String
    var livekit: String
}

/// SE-0482's info.json.
struct BundleInfo: Encodable {
    struct Artifact: Encodable {
        var type: String
        var version: String
        var variants: [Variant]
    }

    struct Variant: Encodable {
        struct Metadata: Encodable {
            var headerPaths: [String]
            var moduleMapPath: String
        }

        var path: String
        var supportedTriples: [String]
        var staticLibraryMetadata: Metadata
    }

    var schemaVersion: String
    var artifacts: [String: Artifact]
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// Programs run by name (found on PATH), failing with their exit status.
enum Shell {
    static func run(_ program: String, _ arguments: [String], in directory: URL? = nil) throws {
        let process = try make(program, arguments, directory)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ValidationError("\(program) \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
        }
    }

    static func output(_ program: String, _ arguments: [String], quiet: Bool = false) throws -> String {
        let process = try make(program, arguments, nil)
        let pipe = Pipe()
        process.standardOutput = pipe
        if quiet { process.standardError = FileHandle.nullDevice }
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ValidationError("\(program) \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func make(_ program: String, _ arguments: [String], _ directory: URL?) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [program] + arguments
        if let directory { process.currentDirectoryURL = directory }
        return process
    }
}
