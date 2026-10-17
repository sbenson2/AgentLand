import { describe, expect, it } from "vitest";
import { applyEvent } from "./ChatPanel";

describe("chat event projection", () => {
  it("replaces snapshots and appends deltas to the addressed part", () => {
    let messages = applyEvent([], {
      type: "snapshot",
      messages: [
        {
          id: "m",
          role: "assistant",
          parts: [{ id: "p", kind: "text", text: "hel" }],
        },
      ],
    });
    messages = applyEvent(messages, {
      type: "part.delta",
      messageId: "m",
      partId: "p",
      field: "text",
      offset: 3,
      delta: "lo",
    });
    expect(messages[0].parts?.[0].text).toBe("hello");
  });
  it("removes messages when the host rewinds them", () => {
    expect(
      applyEvent([{ id: "m", role: "user" }], {
        type: "message.removed",
        messageId: "m",
      }),
    ).toEqual([]);
  });
});

it("rejects replayed or missing UTF-8 deltas and applies tool output to the tool", () => {
  const base: any[] = [
    {
      id: "m",
      role: "assistant",
      parts: [
        { id: "p", kind: "text", text: "日" },
        { id: "t", kind: "tool", tool: { name: "Read", output: "a" } },
      ],
    },
  ];
  expect(() =>
    applyEvent(base, {
      type: "part.delta",
      messageId: "m",
      partId: "p",
      field: "text",
      offset: 1,
      delta: "本",
    }),
  ).toThrow();
  const next = applyEvent(base, {
    type: "part.delta",
    messageId: "m",
    partId: "p",
    field: "text",
    offset: 3,
    delta: "本",
  });
  expect(next[0].parts?.[0].text).toBe("日本");
  expect(() =>
    applyEvent(next, {
      type: "part.delta",
      messageId: "m",
      partId: "p",
      field: "text",
      offset: 3,
      delta: "本",
    }),
  ).toThrow();
  expect(
    applyEvent(base, {
      type: "part.delta",
      messageId: "m",
      partId: "t",
      field: "output",
      offset: 1,
      delta: "b",
    })[0].parts?.[1].tool?.output,
  ).toBe("ab");
});
