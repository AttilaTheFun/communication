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
        subcommands: [Variant.self, Assemble.self, Pin.self, NextVersion.self]
    )
}

/// The platforms CWebRTC is built for: LiveKit's release names, and the
/// triples SwiftPM picks a variant by.
enum Platform: String, CaseIterable, ExpressibleByArgument {
    case linuxX64 = "linux-x64"
    case linuxArm64 = "linux-arm64"

    var triple: String {
        switch self {
        case .linuxX64: "x86_64-unknown-linux-gnu"
        case .linuxArm64: "aarch64-unknown-linux-gnu"
        }
    }

    /// The system libraries a program links beside the bundle's: libwebrtc
    /// carries Chromium's libc++, so only the C library's parts.
    var linkedLibraries: [String] {
        switch self {
        case .linuxX64, .linuxArm64: ["m"]
        }
    }

    /// The shim's C sources beside cwebrtc.cc.
    var extraSources: [String] {
        switch self {
        case .linuxX64, .linuxArm64: ["x11_stubs.c"]
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
        let objects = work.appendingPathComponent("objects")
        try? fm.removeItem(at: objects)
        try fm.createDirectory(at: objects, withIntermediateDirectories: true)

        // The shim, against Chromium's libc++ (libwebrtc's own), with libwebrtc's defines.
        let shim = objects.appendingPathComponent("cwebrtc.o")
        try Shell.run(cxx, [
            "-std=c++20", "-O2", "-fPIC", "-w", "-nostdinc++",
            "-isystem", include.appendingPathComponent("buildtools/third_party/libc++").path,
            "-isystem", include.appendingPathComponent("third_party/libc++/src/include").path,
            "-isystem", include.appendingPathComponent("third_party/libc++abi/src/include").path,
            "-I", include.path,
            "-I", include.appendingPathComponent("third_party/abseil-cpp").path,
            "-I", sources.appendingPathComponent("include").path,
        ] + defines + ["-c", sources.appendingPathComponent("src/cwebrtc.cc").path, "-o", shim.path])
        var added = [shim.path]
        for source in platform.extraSources {
            let object = objects.appendingPathComponent(source + ".o")
            try Shell.run(cc, ["-O2", "-fPIC", "-c", sources.appendingPathComponent("src/\(source)").path, "-o", object.path])
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

    @Option(help: "The bundle's version (the release's).")
    var version: String

    @Option(help: "Where the zip goes.")
    var out: String

    @Argument(help: "Folders of variants (each holding <platform>/variant.json).")
    var variants: [String]

    func run() throws {
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
        try Shell.run("zip", ["-q", "-r", "-y", zip.path, "CWebRTC.artifactbundle"], in: staging)
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
        print("\(parts[0]).\(parts[1]).\((patches.max() ?? 0) + 1)")
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

    static func output(_ program: String, _ arguments: [String]) throws -> String {
        let process = try make(program, arguments, nil)
        let pipe = Pipe()
        process.standardOutput = pipe
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
