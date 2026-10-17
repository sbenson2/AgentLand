export class APIError extends Error {
  constructor(
    message: string,
    public status = 0,
    public code = "",
    public details: unknown = null,
  ) {
    super(message);
  }
  get uncertain() {
    return (
      !this.status ||
      this.status >= 500 ||
      ["delivery_uncertain", "upstream_error", "timeout"].includes(this.code)
    );
  }
}

export class HostAPI {
  private token = "";
  private key = "agentland.web-session";

  async bootstrap() {
    const grant = new URLSearchParams(location.hash.slice(1)).get("launch");
    if (location.hash) history.replaceState(null, "", location.pathname);
    if (grant) {
      sessionStorage.removeItem(this.key);
      const response = await fetch("/web/session", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ grant }),
        signal: AbortSignal.timeout(15000),
        credentials: "omit",
      });
      if (!response.ok)
        throw new APIError(
          "This launch link expired. Choose Open AgentLand in the Mac menu bar.",
          response.status,
        );
      const session = await response.json();
      if (
        typeof session.token !== "string" ||
        typeof session.expiresAt !== "string"
      )
        throw new APIError("Invalid browser session response.");
      sessionStorage.setItem(this.key, JSON.stringify(session));
    }
    let session;
    try {
      session = JSON.parse(sessionStorage.getItem(this.key) || "null");
    } catch {
      session = null;
    }
    if (
      typeof session?.token !== "string" ||
      !Number.isFinite(Date.parse(session.expiresAt)) ||
      Date.parse(session.expiresAt) <= Date.now()
    ) {
      sessionStorage.removeItem(this.key);
      throw new APIError(
        "Choose Open AgentLand in the Mac menu bar to connect this browser.",
        401,
      );
    }
    this.token = session.token;
  }

  async response(path: string, init: RequestInit = {}) {
    if (!path.startsWith("/v1/") && !path.startsWith("/web/"))
      throw new APIError("Invalid local request.");
    const headers = new Headers(init.headers);
    headers.set("Authorization", `Bearer ${this.token}`);
    if (
      init.body &&
      !(init.body instanceof FormData) &&
      !headers.has("Content-Type")
    )
      headers.set("Content-Type", "application/json");
    let response: Response;
    try {
      response = await fetch(path.startsWith("/v1/") ? "/api" + path : path, {
        ...init,
        headers,
        credentials: "omit",
        cache: "no-store",
        signal: init.signal || AbortSignal.timeout(130000),
      });
    } catch (error) {
      if (init.signal?.aborted) throw error;
      throw new APIError(
        "The server did not answer. The outcome of a sent action may be unknown.",
      );
    }
    if (!response.ok) {
      const body = await response.json().catch(() => null);
      if (response.status === 401) {
        sessionStorage.removeItem(this.key);
        window.dispatchEvent(new Event("agentland-auth-expired"));
      }
      throw new APIError(
        body?.error?.message ||
          (response.status === 401
            ? "Session expired. Choose Open AgentLand in the Mac menu bar."
            : `Request failed (${response.status}).`),
        response.status,
        body?.error?.code || "",
        body,
      );
    }
    return response;
  }

  async request<T = any>(path: string, init: RequestInit = {}): Promise<T> {
    const response = await this.response(path, init);
    return response.status === 204 ? (undefined as T) : response.json();
  }
}

export const api = new HostAPI();
export const query = (values: Record<string, string | number>) =>
  new URLSearchParams(
    Object.fromEntries(
      Object.entries(values).map(([key, value]) => [key, String(value)]),
    ),
  ).toString();
export const post = (body: unknown): RequestInit => ({
  method: "POST",
  body: JSON.stringify(body),
});
