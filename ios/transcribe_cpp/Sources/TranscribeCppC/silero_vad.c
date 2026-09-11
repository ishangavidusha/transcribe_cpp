// Forwarder so the VAD's single source of truth can live in ../../../../src,
// shared with other platforms' builds and with the plain-C test harness.
// SwiftPM cannot reference files outside the package directory, so it gets
// this one-line stub instead.
#include "../../../../src/silero_vad.c"
