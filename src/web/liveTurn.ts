/**
 * Whether a thread has a turn running in this sidecar, and the chat session id a
 * client steers it by.  The id is only offered for a Muse turn that has a bridge
 * session to inject into, so a client never holds an id the steer endpoint would
 * refuse as idle.
 */
export function findLiveTurn(
  sessions: ReadonlyMap<string, { engine: string; resumeSessionId: string | null; busy: boolean; bridgeSessionId: string }>,
  engine: string,
  remoteSessionId: string,
): { running: boolean; liveSessionId?: string } {
  for (const [chatId, session] of sessions) {
    if (session.engine !== engine || session.resumeSessionId !== remoteSessionId || !session.busy) continue;
    return { running: true, ...(engine === "muse" && session.bridgeSessionId ? { liveSessionId: chatId } : {}) };
  }
  return { running: false };
}
