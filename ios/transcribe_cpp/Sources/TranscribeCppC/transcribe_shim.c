// Forwarder so the shim's single source of truth can live in ../../../../src,
// shared with other platforms' builds. SwiftPM cannot reference files outside
// the package directory, so it gets this one-line stub instead.
#include "../../../../src/transcribe_shim.c"
