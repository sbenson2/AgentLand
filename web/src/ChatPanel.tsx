import { useEffect, useRef, useState } from "react";
import { api, APIError, post, query } from "./api";
import type { Capabilities, Project, Tab } from "./types";
import {
  chatProviderEntry,
  chatProviderName,
  chatProviderOf,
  isReadOnlyChat,
  modeConfirmation,
  modeToSend,
  readOnlyChatNotice,
  unattendedModes,
  workspaceChatProviders,
} from "./chat-policy";
import {
  applyEvent,
  ResyncNeeded,
  type ChatEvent,
  type Message,
} from "./chat-events";
export { applyEvent } from "./chat-events";
type Attachment = { id: string; name: string; mime: string; size: number };
type Model = {
  id: string;
  name: string;
  efforts?: string[];
  defaultEffort?: string;
};
type Options = {
  models: Model[];
  defaultModel?: string;
  agents?: string[];
  modes?: Array<{ id: string; name: string }>;
  defaultMode?: string;
};
type Question = {
  text: string;
  multiple: boolean;
  custom: boolean;
  secret?: boolean;
  options: Array<{ label: string; description?: string }>;
};
type Interaction = {
  id: string;
  kind: string;
  permission?: { title: string; detail: string };
  choices?: string[];
  alwaysLabel?: string;
  alwaysDetail?: string;
  questions?: Question[];
};
const errorText = (e: unknown) =>
  e instanceof Error ? e.message : "The server did not confirm this action.";

export function ChatPanel({
  tab,
  capabilities,
  projects,
  continueWorkspace,
  onChange,
  onOpen,
}: {
  tab: Tab;
  capabilities: Capabilities;
  projects: Project[];
  // The workspace in use: where a read-only Chats-space chat continues.
  continueWorkspace?: Project;
  onChange: (changes: Partial<Tab>) => void;
  onOpen: (tab: Omit<Tab, "id">) => void;
}) {
  const provider = chatProviderEntry(tab, capabilities, projects);
  const providerName = chatProviderName(chatProviderOf(tab), capabilities);
  // Chats-space Claude Code and Codex chats (and OpenCode's without
  // --opencode-chat) are read-only on hosts with workspaceChats.
  const readOnly = isReadOnlyChat(tab, capabilities, projects);
  const supports = (feature: string) => !readOnly && provider?.features.includes(feature) === true;
  const [refresh, setRefresh] = useState(0);
  const [rewound, setRewound] = useState(false);
  const [queued, setQueued] = useState<Array<{ id: string; text: string; status: string }>>([]);
  const [mutating, setMutating] = useState(false);
  const mutationRef = useRef(false);
  const [mutationUncertain, setMutationUncertain] = useState(false);
  const [messages, setMessages] = useState<Message[]>([]),
    [status, setStatus] = useState("connecting"),
    [error, setError] = useState(
      tab.deliveryUncertain
        ? "Delivery is uncertain. Check the conversation before sending again; your draft is retained."
        : "",
    );
  const [options, setOptions] = useState<Options>({ models: [] }),
    [interactions, setInteractions] = useState<Interaction[]>([]);
  const [hasMore, setHasMore] = useState(false),
    [sending, setSending] = useState(false),
    [uploading, setUploading] = useState(false);
  const [uncertain, setUncertain] = useState(!!tab.deliveryUncertain),
    [attachments, setAttachments] = useState<Attachment[]>(
      (tab.attachments as Attachment[]) || [],
    );
  const current = useRef(tab),
    change = useRef(onChange),
    transcript = useRef<Message[]>([]),
    sendingRef = useRef(false),
    uploadRef = useRef(false),
    optionsRef = useRef<Options>(options),
    reportedMode = useRef<string>();
  optionsRef.current = options;
  current.current = tab;
  change.current = onChange;
  const scope = { projectId: tab.projectId, sessionId: tab.resourceId };
  useEffect(() => {
    const abort = new AbortController();
    let cursor = "",
      stopped = false;
    const publish = (next: Message[]) => {
      transcript.current = next;
      setMessages(next);
    };
    // A read-only chat takes no options: the host refuses them.
    if (!readOnly)
      void api
        .request<Options>("/v1/chat/options?" + query(scope), {
          signal: abort.signal,
        })
        .then(setOptions)
        .catch((e) => {
          if (!abort.signal.aborted) setError(errorText(e));
        });
    // Follows a mode change the host reports while the chat is open (Claude
    // Code leaves Plan for the mode before it once a plan is approved), never
    // the first report: the chat opens in its saved choice, else the host's
    // default. A return to Bypass permissions or Full access is followed only
    // in a chat that confirmed it; otherwise its choice stays and is sent.
    const followHostMode = (mode: unknown) => {
      if (typeof mode !== "string" || !mode || mode === reportedMode.current) return;
      const first = reportedMode.current === undefined;
      reportedMode.current = mode;
      const chat = current.current, modes = optionsRef.current.modes || [];
      if (first || !modes.some((m) => m.id === mode)) return;
      if (mode === (chat.mode || optionsRef.current.defaultMode)) return;
      if (unattendedModes.includes(mode) && !chat.modeConfirmed) return;
      change.current({ mode });
    };
    const consume = (event: ChatEvent) => {
      if (event.type === "unauthorized") {
        window.dispatchEvent(new Event("agentland-auth-expired"));
        throw new APIError("Session expired.", 401);
      }
      if (event.type === "stopping")
        throw new APIError("The server is stopping.");
      publish(applyEvent(transcript.current, event));
      if (event.type === "snapshot" || event.type === "chat.updated")
        followHostMode(event.type === "snapshot" ? event.chat?.mode : event.mode);
      if (event.type === "snapshot") {
        setRewound(!!event.rewind);
        setQueued(event.queue || []);
        setMutationUncertain(false);
        setInteractions(event.interactions || []);
        setStatus(event.status?.state || "idle");
        setHasMore(!!event.hasMore);
      }
      if (event.type === "queue.updated") setQueued(event.items || []);
      if (event.type === "status") {
        setStatus(event.state);
        change.current({ status: event.state });
      }
      if (event.type === "turn.finished")
        setStatus(event.outcome === "error" ? "error" : "idle");
      if (event.type === "interaction.requested")
        setInteractions((items) => [
          ...items.filter((i) => i.id !== event.interaction.id),
          event.interaction,
        ]);
      if (event.type === "interaction.resolved")
        setInteractions((items) => items.filter((i) => i.id !== event.id));
      if (event.cursor) cursor = event.cursor;
      else if (event.seq !== undefined && cursor.includes("."))
        cursor = cursor.slice(0, cursor.lastIndexOf(".") + 1) + event.seq;
    };
    const run = async () => {
      let failures = 0,
        coarse = false;
      while (!stopped) {
        try {
          if (coarse) {
            const [page, state] = await Promise.all([
              api.request(
                "/v1/chat/messages?" + query({ ...scope, limit: 40 }),
                { signal: abort.signal },
              ),
              api.request("/v1/chat/status?" + query(scope), {
                signal: abort.signal,
              }),
            ]);
            publish([...page.messages].reverse());
            setHasMore(page.hasMore);
            setStatus(state.state);
            await new Promise((resolve) => setTimeout(resolve, 3000));
            continue;
          }
          const response = await api.response(
            "/v1/chat/events?" +
              query({ ...scope, ...(cursor ? { after: cursor } : {}) }),
            { signal: abort.signal },
          );
          const reader = response.body?.getReader();
          if (!reader) throw new Error("The chat stream is unavailable.");
          try {
            const decoder = new TextDecoder();
            let pending = "";
            while (!stopped) {
              const next = await reader.read();
              if (next.done) break;
              pending += decoder.decode(next.value, { stream: true });
              const lines = pending.split("\n");
              pending = lines.pop() || "";
              if (pending.length > 262144) throw new ResyncNeeded();
              for (const line of lines)
                if (line.trim()) consume(JSON.parse(line));
              failures = 0;
            }
          } finally {
            await reader.cancel().catch(() => {});
            reader.releaseLock();
          }
        } catch (e) {
          if (abort.signal.aborted || stopped) return;
          if (e instanceof APIError && [401, 403, 404].includes(e.status)) {
            setError(errorText(e));
            setStatus("unavailable");
            return;
          }
          if (e instanceof APIError && e.status === 501) {
            coarse = true;
            continue;
          }
          if (e instanceof ResyncNeeded || e instanceof SyntaxError)
            cursor = "";
          setStatus("reconnecting");
          if (++failures >= 3)
            setError(
              "Connection interrupted. Messages will resume when the server responds.",
            );
        }
        await new Promise((resolve) =>
          setTimeout(resolve, Math.min(8000, 500 * 2 ** Math.min(failures, 4))),
        );
      }
    };
    void run();
    return () => {
      stopped = true;
      abort.abort();
    };
  }, [tab.projectId, tab.resourceId, refresh, readOnly]);
  const send = async () => {
    if (
      sendingRef.current ||
      uploadRef.current ||
      uncertain ||
      mutating || mutationUncertain ||
      (!current.current.draft?.trim() && !attachments.length)
    )
      return;
    sendingRef.current = true;
    setSending(true);
    setError("");
    const draft = current.current.draft || "";
    try {
      const result = await api.request<{ accepted: boolean }>(
        "/v1/messages",
        post({
          ...scope,
          text: draft,
          model: current.current.model || undefined,
          mode: supports("modes") ? modeToSend(current.current, options) : undefined,
          effort: selectedModel?.efforts?.includes(
            String(current.current.effort),
          )
            ? current.current.effort
            : undefined,
          attachments: attachments.map((a) => a.id),
          clientMessageId: crypto.randomUUID(),
        }),
      );
      if (!result.accepted)
        throw new APIError("The host did not confirm delivery.");
      setAttachments([]);
      change.current({
        ...(current.current.draft === draft ? { draft: "" } : {}),
        attachments: [],
        deliveryUncertain: false,
      });
      setStatus("running");
    } catch (e) {
      const ambiguous = !(e instanceof APIError) || e.uncertain;
      setUncertain(ambiguous);
      change.current({ deliveryUncertain: ambiguous });
      setError(
        errorText(e) +
          (ambiguous
            ? " Delivery is uncertain. Check the conversation before sending again; your draft is retained."
            : " Your draft is retained."),
      );
    } finally {
      sendingRef.current = false;
      setSending(false);
    }
  };
  const upload = async (files: File[]) => {
    if (uploadRef.current || sendingRef.current) return;
    uploadRef.current = true;
    setUploading(true);
    setError("");
    let added = [...attachments];
    try {
      for (const file of files) {
        if (added.length >= 5)
          throw new Error("Attach at most 5 files to one message.");
        if (file.size > 10 * 1024 * 1024)
          throw new Error("Attachments must be 10 MiB or smaller.");
        const mime =
          file.type ||
          (/\.md$/i.test(file.name)
            ? "text/markdown"
            : /\.txt$/i.test(file.name)
              ? "text/plain"
              : "application/octet-stream");
        if (provider?.attachmentTypes && !provider.attachmentTypes.includes(mime))
          throw new Error(`${providerName} can’t read ${file.name}. It accepts photos and text files${provider.attachmentTypes.includes("application/pdf") ? " and PDFs" : ""}.`);
        const result = await api.request<Attachment>(
          "/v1/attachments?" + query({ ...scope, name: file.name }),
          {
            method: "POST",
            headers: { "Content-Type": mime },
            body: await file.arrayBuffer(),
          },
        );
        added = [...added, result];
        setAttachments(added);
        change.current({ attachments: added });
      }
    } catch (e) {
      setError(errorText(e));
    } finally {
      uploadRef.current = false;
      setUploading(false);
    }
  };
  const abortTurn = async () => {
    try {
      const result = await api.request("/v1/abort", post(scope));
      if (!result.aborted) throw new APIError("Stop was not confirmed.");
    } catch (e) {
      setError(errorText(e));
    }
  };
  const older = async () => {
    try {
      const page = await api.request(
        "/v1/chat/messages?" +
          query({ ...scope, before: messages[0]?.id || "", limit: 40 }),
      );
      const existing = new Set(transcript.current.map((m) => m.id));
      const all = [
        ...[...page.messages]
          .reverse()
          .filter((m: Message) => !existing.has(m.id)),
        ...transcript.current,
      ];
      transcript.current = all;
      setMessages(all);
      setHasMore(page.hasMore);
    } catch (e) {
      setError(errorText(e));
    }
  };
  const selectedModel = options.models.find(
    (m) => m.id === (tab.model || options.defaultModel),
  );
  const modes = supports("modes") ? options.modes || [] : [];
  const selectedMode = modes.some((m) => m.id === tab.mode)
    ? tab.mode
    : modes.find((m) => m.id === options.defaultMode)?.id;
  // Bypass permissions and Full access ask once per chat; the answer stays
  // with the tab, and a declined switch leaves the mode as it was.
  const chooseMode = (id: string) => {
    const mode = modes.find((m) => m.id === id);
    if (!mode || id === selectedMode) return;
    if (unattendedModes.includes(id) && !current.current.modeConfirmed) {
      if (!window.confirm(modeConfirmation(mode, providerName))) return;
      onChange({ mode: id, modeConfirmed: true });
      return;
    }
    onChange({ mode: id });
  };
  const latestUser = [...messages].reverse().find((m) => m.role === "user");
  const idle = status === "idle" || status === "error";
  const canChangeTurn = idle && !sending && !uploading && !mutating && !mutationUncertain && !uncertain && !queued.length;
  const mutate = async (action: () => Promise<void>) => {
    if (mutationRef.current || mutationUncertain || sendingRef.current) return;
    mutationRef.current = true;
    setMutating(true);
    setError("");
    try { await action(); }
    catch (e) {
      const ambiguous = !(e instanceof APIError) || e.uncertain;
      setMutationUncertain(ambiguous);
      setError(errorText(e) + (ambiguous ? " This action is not confirmed. Refresh status before trying again." : ""));
    } finally { mutationRef.current = false; setMutating(false); }
  };
  const editLatest = () => mutate(async () => {
    if (!latestUser || !canChangeTurn || rewound) return;
    const text = latestUser.parts?.filter((p) => p.kind === "text").map((p) => p.text || "").join("\n\n") || "";
    const result = await api.request("/v1/messages/rewind", post({ ...scope, messageId: latestUser.id }));
    if (!result.rewound) throw new APIError("Edit was not confirmed.");
    onChange({ draft: text });
    setRewound(true);
    if (latestUser.parts?.some((p) => p.kind === "attachment")) setError("Attach the files again before resending this message.");
    setRefresh((v) => v + 1);
  });
  const retryLatest = () => mutate(async () => {
    if (!latestUser || !canChangeTurn || rewound) return;
    if (latestUser.parts?.some((p) => p.kind === "attachment")) {
      setError("Use Edit and resend, then attach the files again to retry this message.");
      return;
    }
    const settings = {
      model: tab.model || undefined,
      mode: supports("modes") ? modeToSend(tab, options) : undefined,
      effort: supports("effort") && selectedModel?.efforts?.includes(String(tab.effort)) ? tab.effort : undefined,
    };
    if (supports("regenerate")) {
      const result = await api.request("/v1/chat/regenerate", post({ ...scope, ...settings }));
      if (!result.accepted) throw new APIError("Retry was not confirmed.");
    } else {
      const text = latestUser.parts?.filter((p) => p.kind === "text").map((p) => p.text || "").join("\n\n") || "";
      const result = await api.request("/v1/messages/rewind", post({ ...scope, messageId: latestUser.id }));
      if (!result.rewound) throw new APIError("Rewind was not confirmed.");
      setRewound(true);
      const sent = await api.request("/v1/messages", post({ ...scope, ...settings, text, clientMessageId: crypto.randomUUID() }));
      if (!sent.accepted) throw new APIError("Retry was not confirmed.");
    }
    setRewound(false);
    setStatus("running");
    setRefresh((v) => v + 1);
  });
  const restore = () => mutate(async () => {
    const result = await api.request("/v1/messages/restore", post(scope));
    if (!result.restored) throw new APIError("Restore was not confirmed.");
    setRewound(false);
    setRefresh((v) => v + 1);
  });
  const enqueue = () => mutate(async () => {
    const text = tab.draft || "";
    if (!text.trim() || attachments.length) return;
    const result = await api.request("/v1/queue", post({ ...scope, text, model: tab.model || undefined }));
    if (!result.id) throw new APIError("The queued message was not confirmed.");
    if (current.current.draft === text) onChange({ draft: "" });
    setRefresh((v) => v + 1);
  });
  const removeQueued = (itemId: string) => mutate(async () => {
    await api.request("/v1/queue/remove", post({ ...scope, itemId }));
    setRefresh((v) => v + 1);
  });
  return (
    <section className="chat-view">
      <div className="surface-tools">
        <span role="status">{sending ? "Sending…" : status}</span>
        <span className="grow" />
        <label>
          Model{" "}
          <select
            aria-label="Chat model"
            value={tab.model || ""}
            onChange={(e) => onChange({ model: e.target.value, effort: "" })}
          >
            <option value="">Default model</option>
            {options.models.map((m) => (
              <option key={m.id} value={m.id}>
                {m.name}
              </option>
            ))}
          </select>
        </label>
        {!!modes.length && (
          <label>
            Mode{" "}
            <select
              aria-label="Mode"
              value={selectedMode || ""}
              onChange={(e) => chooseMode(e.target.value)}
            >
              {!selectedMode && <option value="">Default</option>}
              {modes.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.name}
                </option>
              ))}
            </select>
          </label>
        )}
        {!!selectedModel?.efforts?.length && (
          <label>
            Effort{" "}
            <select
              value={String(tab.effort || "")}
              onChange={(e) => onChange({ effort: e.target.value })}
            >
              <option value="">Default</option>
              {selectedModel.efforts.map((e) => (
                <option key={e}>{e}</option>
              ))}
            </select>
          </label>
        )}
      </div>
      {error && (
        <div className="notice error" role="alert">
          {error}
          {uncertain && (
            <button
              onClick={() => {
                setUncertain(false);
                onChange({ deliveryUncertain: false });
                setError("");
              }}
            >
              I checked the conversation
            </button>
          )}
        </div>
      )}
      <div className="transcript" aria-label="Conversation">
        {mutationUncertain && <button disabled={mutating} onClick={() => setRefresh((v) => v + 1)}>Refresh status</button>}
        {rewound && <div className="notice">Editing the latest message. <button disabled={!canChangeTurn} onClick={() => void restore()}>Cancel edit</button></div>}
        {hasMore && (
          <button onClick={() => void older()}>Load earlier messages</button>
        )}
        {!messages.length && (
          <div className="empty-chat">
            <h2>
              {status === "connecting"
                ? "Loading conversation…"
                : "Start a conversation"}
            </h2>
            <p>
              {readOnly
                ? "This chat has no messages."
                : `Ask ${providerName} a question or describe a task. Its approvals and questions appear here.`}
            </p>
          </div>
        )}
        {messages.map((message) => (
          <article className="message" key={message.id}>
            <header>
              {message.role === "user" ? "You" : providerName}
              <small>{message.status}</small>
              {message.id === latestUser?.id && supports("rewind") && !rewound && <button disabled={!canChangeTurn || !!tab.draft?.trim() || !!attachments.length} onClick={() => void editLatest()}>Edit and resend</button>}
            </header>
            {message.parts?.map((part) => (
              <div className={`part part-${part.kind}`} key={part.id}>
                {part.kind === "tool" ? (
                  <details>
                    <summary>
                      {part.tool?.title || part.tool?.name || "Tool"}{" "}
                      <small>{part.tool?.status}</small>
                    </summary>
                    {part.tool?.input && <pre>{part.tool.input}</pre>}
                    {part.tool?.output && <pre>{part.tool.output}</pre>}
                    {part.tool?.error && (
                      <pre className="error">{part.tool.error}</pre>
                    )}
                  </details>
                ) : part.kind === "reasoning" || part.kind === "context" ? (
                  <details>
                    <summary>
                      {part.kind === "reasoning"
                        ? "Reasoning"
                        : "Earlier context"}
                    </summary>
                    <p>{part.text}</p>
                  </details>
                ) : part.kind === "attachment" ? (
                  <p>Attachment: {part.attachment?.name || "File"}</p>
                ) : (
                  <p>{part.text}</p>
                )}
                {!!part.tool?.sources?.length && <ul className="chat-sources">{part.tool.sources.filter((source) => /^https?:\/\//i.test(source.url)).map((source) => <li key={source.url}><a href={source.url} target="_blank" rel="noreferrer">{source.title}</a></li>)}</ul>}
                {part.truncated && (
                  <small>Content shortened by the host.</small>
                )}
              </div>
            ))}
            {message.error && <p className="error">{message.error.message}</p>}
          </article>
        ))}
        {latestUser && (supports("regenerate") || supports("rewind")) && !rewound && <button disabled={!canChangeTurn} onClick={() => void retryLatest()}>Run again</button>}
      </div>
      <div className="interactions">
        {queued.map((item) => <p key={item.id}>Queued: {item.text}{" "}<button disabled={mutating || mutationUncertain || item.status === "sending"} onClick={() => void removeQueued(item.id)}>Remove queued message</button></p>)}
        {interactions.map((interaction) => (
          <InteractionPanel
            key={interaction.id}
            interaction={interaction}
            scope={scope}
            onDone={() =>
              setInteractions((v) => v.filter((i) => i.id !== interaction.id))
            }
          />
        ))}
      </div>
      {readOnly ? (
        <ContinueNotice
          tab={tab}
          capabilities={capabilities}
          workspace={continueWorkspace}
          onOpen={onOpen}
        />
      ) : (
      <form
        className="composer"
        onSubmit={(e) => {
          e.preventDefault();
          void send();
        }}
      >
        <textarea
          aria-label="Message"
          value={tab.draft || ""}
          onChange={(e) => onChange({ draft: e.target.value })}
          placeholder="Message…"
          rows={3}
          onKeyDown={(e) => {
            if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
              e.preventDefault();
              void send();
            }
          }}
        />
        {!!attachments.length && (
          <div className="attachments">
            {attachments.map((a) => (
              <span key={a.id}>
                {a.name}
                <button
                  type="button"
                  disabled={sending || uploading}
                  aria-label={`Remove ${a.name}`}
                  onClick={() => {
                    const next = attachments.filter((f) => f.id !== a.id);
                    setAttachments(next);
                    onChange({ attachments: next });
                  }}
                >
                  ×
                </button>
              </span>
            ))}
          </div>
        )}
        <div className="composer-actions">
          {supports("attachments") && <label className="attach-button">
            Attach files
            <input
              aria-label="Attach files"
              type="file"
              accept={provider?.attachmentTypes?.join(",")}
              multiple
              disabled={sending || uploading || uncertain}
              onChange={(e) => {
                void upload([...(e.target.files || [])]);
                e.target.value = "";
              }}
            />
          </label>}
          <span className="grow" />
          <small>{uploading ? "Uploading…" : "⌘ Enter to send"}</small>
          {supports("queue") && ["busy", "running", "waiting", "retry"].includes(status) && <button type="button" disabled={mutating || mutationUncertain || uncertain || sending || uploading || !!attachments.length || !tab.draft?.trim()} onClick={() => void enqueue()}>Queue message</button>}
          {["busy", "running", "waiting", "retry"].includes(status) && (
            <button type="button" onClick={() => void abortTurn()}>
              Stop
            </button>
          )}
          <button
            className="primary"
            type="submit"
            disabled={
              sending ||
              uploading ||
              uncertain ||
              mutating || mutationUncertain ||
              [
                "connecting",
                "reconnecting",
                "unavailable",
                "running",
                "busy",
                "waiting",
                "retry",
              ].includes(status) ||
              (!tab.draft?.trim() && !attachments.length)
            }
          >
            Send
          </button>
        </div>
      </form>
      )}
    </section>
  );
}

// A read-only Chats-space chat continues as a new Claude Code or Codex chat in
// the workspace in use, with this conversation as context. Nothing is sent,
// and an unconfirmed continue is never tried again by itself.
function ContinueNotice({
  tab,
  capabilities,
  workspace,
  onOpen,
}: {
  tab: Tab;
  capabilities: Capabilities;
  workspace?: Project;
  onOpen: (tab: Omit<Tab, "id">) => void;
}) {
  const providers = workspaceChatProviders(capabilities);
  const source = chatProviderOf(tab);
  const [chosen, setChosen] = useState(source);
  const target = providers.some((p) => p.id === chosen) ? chosen : providers[0]?.id || "";
  const [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [uncertain, setUncertain] = useState(false);
  const flight = useRef(false);
  const continueChat = async () => {
    if (flight.current || !workspace || !target || uncertain) return;
    flight.current = true;
    setBusy(true);
    setError("");
    try {
      const created = await api.request<{ id?: string; title?: string }>(
        "/v1/chat/continue",
        post({ projectId: workspace.id, sourceSessionId: tab.resourceId, provider: target }),
      );
      if (!created?.id)
        throw new APIError("The server did not return the new chat.");
      onOpen({
        kind: "chat",
        projectId: workspace.id,
        resourceId: created.id,
        title: created.title || "Continued chat",
        agent: target,
      });
    } catch (e) {
      // agent_unavailable is the host's refusal, not a lost answer.
      const ambiguous =
        !(e instanceof APIError) || (e.uncertain && e.code !== "agent_unavailable");
      setUncertain(ambiguous);
      setError(
        errorText(e) +
          (ambiguous
            ? " The new chat may exist. Check Running Sessions before continuing again."
            : ""),
      );
    } finally {
      flight.current = false;
      setBusy(false);
    }
  };
  return (
    <div className="notice read-only-chat" role="note" aria-label="Read-only chat">
      <p>{readOnlyChatNotice}</p>
      {!workspace ? (
        <p>Choose a workspace to continue this chat there.</p>
      ) : !providers.length ? (
        <p>Claude Code and Codex are unavailable on this Mac.</p>
      ) : (
        <div className="field-row">
          {providers.length > 1 && (
            <select
              aria-label="Continue with"
              value={target}
              disabled={busy}
              onChange={(e) => setChosen(e.target.value)}
            >
              {providers.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </select>
          )}
          <button
            className="primary"
            disabled={busy || uncertain}
            onClick={() => void continueChat()}
          >
            {busy ? "Continuing…" : `Continue in ${workspace.name}`}
          </button>
        </div>
      )}
      {!!workspace && !!providers.length && (
        <small>
          The new chat starts with this conversation as context. Nothing is
          sent until you write.
        </small>
      )}
      {error && (
        <p role="alert" className="error">
          {error}{" "}
          {uncertain && (
            <button
              onClick={() => {
                setUncertain(false);
                setError("");
              }}
            >
              I checked Running Sessions
            </button>
          )}
        </p>
      )}
    </div>
  );
}
function InteractionPanel({
  interaction,
  scope,
  onDone,
}: {
  interaction: Interaction;
  scope: { projectId: string; sessionId: string };
  onDone: () => void;
}) {
  const [answers, setAnswers] = useState<string[][]>(
      (interaction.questions || []).map(() => []),
    ),
    [custom, setCustom] = useState<string[]>(
      (interaction.questions || []).map(() => ""),
    );
  const [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const reply = async (path: string, payload: object) => {
    if (busy) return;
    setBusy(true);
    try {
      const result = await api.request(
        path,
        post({ ...scope, requestId: interaction.id, ...payload }),
      );
      if (!result.accepted)
        throw new Error("The host did not accept this reply.");
      onDone();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };
  const all = answers.map((a, i) =>
    custom[i]?.trim()
      ? interaction.questions?.[i].multiple
        ? [...a, custom[i]]
        : [custom[i]]
      : a,
  );
  return (
    <section className="interaction">
      <h3>
        {interaction.kind === "permission"
          ? interaction.permission?.title || "Permission required"
          : "The agent has a question"}
      </h3>
      {error && (
        <p role="alert" className="error">
          {error}
        </p>
      )}
      {interaction.kind === "permission" ? (
        <>
          <pre>{interaction.permission?.detail}</pre>
          <div className="field-row">
            {interaction.choices?.map((choice) => (
              <button
                key={choice}
                disabled={busy}
                onClick={() =>
                  void reply("/v1/permissions/reply", { reply: choice })
                }
              >
                {choice === "once"
                  ? "Allow once"
                  : choice === "always"
                    ? interaction.alwaysLabel || "Allow as requested"
                    : "Deny"}
              </button>
            ))}
          </div>
          {interaction.alwaysDetail && <p>{interaction.alwaysDetail}</p>}
        </>
      ) : (
        <>
          {interaction.questions?.map((q, i) => (
            <fieldset key={i}>
              <legend>{q.text}</legend>
              {q.options?.map((option) => (
                <label key={option.label}>
                  <input
                    type={q.multiple ? "checkbox" : "radio"}
                    name={`${interaction.id}-${i}`}
                    checked={answers[i]?.includes(option.label) || false}
                    onChange={(e) =>
                      setAnswers((v) =>
                        v.map((a, index) =>
                          index !== i
                            ? a
                            : q.multiple
                              ? e.target.checked
                                ? [...a, option.label]
                                : a.filter((s) => s !== option.label)
                              : [option.label],
                        ),
                      )
                    }
                  />
                  {option.label}
                  {option.description && <small>{option.description}</small>}
                </label>
              ))}
              {q.custom && (
                <input
                  type={q.secret ? "password" : "text"}
                  autoComplete="off"
                  aria-label={`Your answer: ${q.text}`}
                  value={custom[i]}
                  onChange={(e) =>
                    setCustom((v) =>
                      v.map((a, index) => (index === i ? e.target.value : a)),
                    )
                  }
                />
              )}
            </fieldset>
          ))}
          <div className="field-row">
            <button
              disabled={busy || all.some((a) => !a.length)}
              onClick={() =>
                void reply("/v1/questions/reply", { answers: all })
              }
            >
              Send answers
            </button>
            <button
              disabled={busy}
              onClick={() => void reply("/v1/questions/reject", {})}
            >
              Dismiss question
            </button>
          </div>
        </>
      )}
    </section>
  );
}
