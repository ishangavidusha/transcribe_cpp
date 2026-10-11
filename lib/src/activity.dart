/// Sessions currently capturing or replaying, process-wide.
///
/// [ModelManager] reads this to refuse starting a download while one is
/// running: a transfer, its file writes and its hash compete with a live
/// decode for memory and CPU on exactly the phones least able to spare
/// them, and a decode that falls behind drops live text.
int activeSessions = 0;
