export type Part = {
  id: string;
  kind: string;
  ord?: number;
  text?: string;
  tool?: {
    name: string;
    title?: string;
    status?: string;
    input?: string;
    output?: string;
    error?: string;
    sources?: Array<{ title: string; url: string }>;
  };
  attachment?: { name: string };
  truncated?: boolean;
};
export type Message = {
  id: string;
  role: string;
  status?: string;
  ord?: number;
  parts?: Part[];
  error?: { message: string };
};
export type ChatEvent = { type: string; seq?: number; [key: string]: any };
export class ResyncNeeded extends Error {}
export function applyEvent(messages: Message[], event: ChatEvent): Message[] {
  if (event.type === "snapshot") return event.messages || [];
  if (event.type === "message.created" && event.message) {
    const next = [
      ...messages.filter((m) => m.id !== event.message.id),
      event.message,
    ];
    return next.sort((a, b) => (a.ord || 0) - (b.ord || 0));
  }
  if (event.type === "message.updated")
    return messages.map((m) =>
      m.id === event.messageId
        ? {
            ...m,
            ...Object.fromEntries(
              ["status", "error", "usage", "completedAt"]
                .filter((k) => event[k] !== undefined)
                .map((k) => [k, event[k]]),
            ),
          }
        : m,
    );
  if (event.type === "message.removed")
    return messages.filter((m) => m.id !== event.messageId);
  if (event.type === "part.removed")
    return messages.map((m) =>
      m.id === event.messageId
        ? { ...m, parts: m.parts?.filter((p) => p.id !== event.partId) }
        : m,
    );
  if (event.type === "part.created" || event.type === "part.updated")
    return messages.map((m) =>
      m.id === event.messageId
        ? {
            ...m,
            parts: [
              ...(m.parts || []).filter((p) => p.id !== event.part.id),
              event.part,
            ].sort((a, b) => (a.ord || 0) - (b.ord || 0)),
          }
        : m,
    );
  if (event.type === "part.delta") {
    let found = false;
    const next = messages.map((m) =>
      m.id !== event.messageId
        ? m
        : {
            ...m,
            parts: m.parts?.map((p) => {
              if (p.id !== event.partId) return p;
              found = true;
              if (event.field !== "text" && event.field !== "output")
                throw new ResyncNeeded();
              const previous =
                event.field === "output" ? p.tool?.output || "" : p.text || "";
              if (new TextEncoder().encode(previous).length !== event.offset)
                throw new ResyncNeeded();
              return event.field === "output"
                ? { ...p, tool: { ...p.tool!, output: previous + event.delta } }
                : { ...p, text: previous + event.delta };
            }),
          },
    );
    if (!found) throw new ResyncNeeded();
    return next;
  }
  return messages;
}
