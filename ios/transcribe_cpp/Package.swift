// swift-tools-version: 5.9
// The SwiftPM manifest for the transcribe_cpp Flutter plugin.
//
// Flutter 3.44 made Swift Package Manager the default for iOS/macOS apps and
// CocoaPods' trunk goes read-only in December 2026, so this is the primary
// integration path. ../transcribe_cpp.podspec is kept alongside it for apps
// that have not migrated yet; both point at the SAME xcframework and the same
// sources, so there is nothing to keep in sync by hand.
import PackageDescription

let package = Package(
    name: "transcribe_cpp",
    platforms: [
        // Matches IOS_MIN_OS_VERSION in transcribe.cpp's build_xcframework.sh.
        // The framework's slices refuse to link below this.
        .iOS("16.0")
    ],
    products: [
        .library(name: "transcribe-cpp", targets: ["transcribe_cpp"])
    ],
    dependencies: [
        // Flutter's own SwiftPM package. The path is resolved by the Flutter
        // tool when it generates the app's package graph — see
        // docs.flutter.dev/packages-and-plugins/swift-package-manager.
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        // The engine, consumed as a prebuilt dynamic xcframework — the same
        // artifact transcribe.cpp's own Swift binding ships. Dynamic (not a
        // static .a) on purpose: ggml-metal is Objective-C and creates
        // libdispatch objects during Metal device init; a static slice pushes
        // that ObjC runtime registration onto the app's final link and aborts
        // at launch without -ObjC/-force_load. A dynamic framework is
        // registered by dyld normally and needs no consumer flags.
        .binaryTarget(
            name: "CTranscribe",
            path: "Frameworks/TranscribeCpp.xcframework"
        ),
        // This package's own C, in its own target because a SwiftPM target is
        // single-language and the capture layer below is Swift. Three pieces,
        // all of which Dart calls directly over FFI: the cancellation shim, the
        // Silero VAD, and the lock-free ring the audio thread writes into.
        //
        // Every function here is annotated TC_EXPORT — nothing in Swift calls
        // them, so without it the linker drops the lot. See src/tc_export.h.
        .target(
            name: "TranscribeCppC",
            path: "Sources/TranscribeCppC",
            cSettings: [.headerSearchPath("include")]
        ),
        // The capture layer. Swift rather than C because AVAudioSession and
        // AVAudioEngine are the only way to get microphone audio on iOS, and
        // because route changes, interruptions and media-services resets are
        // all delivered as NotificationCenter callbacks.
        //
        // Audio *data* never travels through here into Dart — it goes into the
        // C ring and is read by an isolate over FFI. This target only carries
        // control and state.
        // Named for the plugin, not for Swift convention: Flutter's generated
        // registrant emits `@import transcribe_cpp;`, deriving the module name
        // from the pubspec plugin name, so the target that holds the plugin
        // class has to answer to exactly that.
        .target(
            name: "transcribe_cpp",
            dependencies: [
                "CTranscribe",
                "TranscribeCppC",
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            path: "Sources/transcribe_cpp"
        ),
    ]
)
