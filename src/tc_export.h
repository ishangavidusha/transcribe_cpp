/*
 * TC_EXPORT — keep a symbol alive for runtime lookup.
 *
 * This package's C is compiled into the plugin's static target and linked into
 * the host app. Nothing in Swift or Objective-C ever calls it: Dart resolves
 * these functions at runtime through `DynamicLibrary.process()`, i.e. dlsym on
 * the main executable. The linker cannot see that, so from its point of view
 * every function here is unreachable and it drops them — leaving a build that
 * compiles and links cleanly and then throws "symbol not found" the first time
 * Dart looks one up.
 *
 * `used` marks the symbol .no_dead_strip on Mach-O and ELF, and
 * `visibility("default")` keeps it in the dynamic symbol table so dlsym can
 * find it. Both halves are needed; either alone leaves the symbol unreachable.
 *
 * Measured on iOS, `flutter build ios --release`, by building the same app
 * three times: with the attribute 12 of 12 symbols survive, with TC_EXPORT
 * defined empty 0 of 12 do, and restoring it brings all 12 back. So this is
 * load-bearing, not defensive.
 *
 * Verify rather than assume — the failure is invisible at build time, and a
 * Debug build will not reproduce it because Xcode puts the code in
 * Runner.debug.dylib, which is not dead-stripped:
 *
 *   nm -gU build/ios/iphoneos/Runner.app/Runner | grep -c 'silero_vad_\|tcshim_'
 */
#ifndef TC_EXPORT_H
#define TC_EXPORT_H

#if defined(_WIN32)
#define TC_EXPORT __declspec(dllexport)
#else
#define TC_EXPORT __attribute__((used, visibility("default")))
#endif

#endif /* TC_EXPORT_H */
