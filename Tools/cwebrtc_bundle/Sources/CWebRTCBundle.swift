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
        subcommands: [Variant.self, Assemble.self]
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

    @Option(help: "LiveKit's libwebrtc release (livekit/rust-sdks), e.g. webrtc-83af826.")
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
        let work = URL(fileURLWithPath: work).appendingPathComponent("\(livekit)-\(platform.rawValue)")
        let release = work.appendingPathComponent("\(platform.rawValue)-release")
        if !fm.fileExists(atPath: release.appendingPathComponent("lib/libwebrtc.a").path) {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("webrtc.zip")
            let url = "https://github.com/livekit/rust-sdks/releases/download/\(livekit)/webrtc-\(platform.rawValue)-release.zip"
            print("cwebrtc-bundle: downloading \(url)")
            try Shell.run("curl", ["-fsSL", "--retry", "3", "-o", zip.path, url])
            try Shell.run("unzip", ["-q", "-o", zip.path, "-d", work.path])
            try? fm.removeItem(at: zip)
        }
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
