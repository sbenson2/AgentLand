import { useEffect, useRef, useState } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import { api, APIError, post, query } from "./api";
import type { Tab } from "./types";
import { inputChunks } from "./encoding";

export function encodeInput(text: string) {
  return btoa(String.fromCharCode(...new TextEncoder().encode(text)));
}
export function decodeOutput(encoded: string) {
  return Uint8Array.from(atob(encoded), (c) => c.charCodeAt(0));
}

type Notice = { status: string; blocked: boolean };
type Output = {
  data: string;
  cursor: number;
  reset: boolean;
  status: string;
  exitCode?: number;
};

// Session ownership outlives React views. Changing tabs cannot create a new PTY.
class TerminalRuntime {
  readonly term = new Terminal({
    cursorBlink: true,
    scrollback: 5000,
    fontSize: 14,
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
    theme: { background: "#202935", foreground: "#d6dde7", cursor: "#93c4e6" },
    allowProposedApi: false,
  });
  private fit = new FitAddon();
  private opened = false;
  private poll?: AbortController;
  private resize?: ResizeObserver;
  private cursor = 0;
  private inputs: Array<{ data?: string; rows?: number; cols?: number }> = [];
  private inputBytes = 0;
  private sending = false;
  private disposed = false;
  private connected = false;
  private ended = false;
  private listener?: (notice: Notice) => void;
  notice: Notice = { status: "Connecting…", blocked: false };

  constructor(private tab: Tab) {
    this.term.loadAddon(this.fit);
    this.term.onData((data) => this.input(data));
    this.term.onResize((size) => {
      if (!this.notice.blocked && !this.disposed) {
        // Resizes share the ordered input queue; coalesce adjacent resizes.
        if (this.inputs.at(-1)?.data === undefined && this.inputs.length)
          this.inputs.pop();
        this.inputs.push({ rows: size.rows, cols: size.cols });
        void this.send();
      }
    });
  }
  private notify(patch: Partial<Notice>) {
    this.notice = { ...this.notice, ...patch };
    this.listener?.(this.notice);
  }
  mount(element: HTMLElement, listener: (notice: Notice) => void) {
    this.listener = listener;
    listener(this.notice);
    if (!this.opened) {
      this.term.open(element);
      this.opened = true;
    } else if (this.term.element) element.appendChild(this.term.element);
    this.fit.fit();
    this.term.focus();
    this.resize = new ResizeObserver(() => this.fit.fit());
    this.resize.observe(element);
    this.poll = new AbortController();
    void this.output(this.poll.signal);
  }
  unmount() {
    this.poll?.abort();
    this.resize?.disconnect();
    this.listener = undefined;
  }
  dispose() {
    this.disposed = true;
    this.unmount();
    this.term.dispose();
  }
  resume() {
    if (!this.connected || this.ended) return;
    this.notify({ blocked: false, status: "Running" });
    this.term.focus();
  }
  input(data: string) {
    if (this.notice.blocked || this.disposed || !this.connected || this.ended)
      return;
    const bytes = new TextEncoder().encode(data);
    if (this.inputBytes + bytes.length > 65536) {
      this.notify({
        blocked: true,
        status: "Input queue is full. Wait for the server, then resume typing.",
      });
      return;
    }
    for (const chunk of inputChunks(data)) {
      this.inputs.push({ data: btoa(String.fromCharCode(...chunk)) });
      this.inputBytes += chunk.length;
    }
    void this.send();
  }
  private async send() {
    if (this.sending || this.disposed) return;
    this.sending = true;
    try {
      while (this.inputs.length && !this.disposed) {
        const next = this.inputs.shift()!;
        if (next.data) this.inputBytes -= atob(next.data).length;
        try {
          const result = await api.request<{ accepted: boolean }>(
            next.data ? "/v1/terminal/input" : "/v1/terminal/resize",
            post({
              projectId: this.tab.projectId,
              terminalId: this.tab.resourceId,
              ...next,
            }),
          );
          if (!result.accepted)
            throw new APIError("Terminal did not confirm this input.");
        } catch (error) {
          this.inputs = [];
          this.inputBytes = 0;
          this.notify({
            blocked: true,
            status:
              error instanceof APIError && !error.uncertain
                ? `${error.message} Resume typing when ready.`
                : "Input delivery is uncertain. Check the terminal before resuming; queued input was cleared.",
          });
          break;
        }
      }
    } finally {
      this.sending = false;
    }
  }
  private async output(signal: AbortSignal) {
    let failures = 0;
    while (!signal.aborted && !this.disposed) {
      try {
        const out = await api.request<Output>(
          "/v1/terminal/output?" +
            query({
              projectId: this.tab.projectId,
              terminalId: this.tab.resourceId,
              cursor: this.cursor,
              wait: 1,
            }),
          { signal },
        );
        if (signal.aborted) return;
        if (out.reset) {
          this.term.reset();
          this.term.writeln("\r\n[Earlier output is no longer available.]\r\n");
        }
        if (out.data) this.term.write(decodeOutput(out.data));
        this.cursor = out.cursor;
        this.connected = true;
        failures = 0;
        if (!this.notice.blocked)
          this.notify({
            status: out.status === "running" ? "Running" : out.status,
          });
        if (out.status === "exited" || out.status === "disconnected") {
          this.ended = true;
          this.notify({
            blocked: true,
            status:
              out.status === "exited"
                ? `Exited${out.exitCode == null ? "" : ` (${out.exitCode})`}`
                : "Session disconnected. Start a new session.",
          });
          return;
        }
      } catch (error) {
        if (signal.aborted) return;
        this.connected = false;
        if (
          error instanceof APIError &&
          [401, 403, 404].includes(error.status)
        ) {
          this.notify({ blocked: true, status: error.message });
          return;
        }
        this.notify({ status: "Reconnecting…" });
        await new Promise((resolve) =>
          setTimeout(
            resolve,
            Math.min(8000, 500 * 2 ** Math.min(failures++, 4)),
          ),
        );
      }
    }
  }
}

const runtimes = new Map<string, TerminalRuntime>();
export function forgetTerminal(id: string) {
  runtimes.get(id)?.dispose();
  runtimes.delete(id);
}
export function TerminalPanel({ tab, onEnd }: { tab: Tab; onEnd: () => void }) {
  const element = useRef<HTMLDivElement>(null);
  const [notice, setNotice] = useState<Notice>({
    status: "Connecting…",
    blocked: false,
  });
  const [error, setError] = useState("");
  const runtime = useRef<TerminalRuntime>();
  useEffect(() => {
    let owned = runtimes.get(tab.id);
    if (!owned) {
      owned = new TerminalRuntime(tab);
      runtimes.set(tab.id, owned);
    }
    runtime.current = owned;
    owned.mount(element.current!, setNotice);
    return () => owned.unmount();
  }, [tab.id]);
  const end = async () => {
    if (!confirm("End this terminal session? Its running process will stop."))
      return;
    try {
      const result = await api.request<{ accepted: boolean }>(
        "/v1/terminal/close",
        post({ projectId: tab.projectId, terminalId: tab.resourceId }),
      );
      if (!result.accepted)
        throw new APIError(
          "The server did not confirm termination. Check Running Sessions before retrying.",
        );
      forgetTerminal(tab.id);
      onEnd();
    } catch (e) {
      setError(
        e instanceof Error ? e.message : "Termination was not confirmed.",
      );
    }
  };
  return (
    <section className="terminal-panel" aria-label={tab.title}>
      <div className="surface-tools">
        <span role="status">{notice.status}</span>
        <span className="grow" />
        {notice.blocked &&
          !notice.status.startsWith("Exited") &&
          !notice.status.startsWith("Session disconnected") && (
            <button onClick={() => runtime.current?.resume()}>
              Resume typing
            </button>
          )}
        <button
          onClick={() => runtime.current?.input("\x03")}
          disabled={notice.blocked}
        >
          Interrupt (Ctrl+C)
        </button>
        <button onClick={() => void end()}>End Session</button>
      </div>
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      <div ref={element} className="terminal-canvas" />
    </section>
  );
}
