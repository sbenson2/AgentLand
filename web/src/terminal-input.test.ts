import { expect, it } from "vitest";
import { inputChunks } from "./encoding";
it("splits large pastes at UTF-8 boundaries within the host limit", () => {
  const input = "a".repeat(8191) + "日本語😀".repeat(2500),
    decoder = new TextDecoder("utf-8", { fatal: true });
  const chunks = inputChunks(input);
  expect(chunks.every((c) => c.length <= 8192)).toBe(true);
  expect(chunks.map((c) => decoder.decode(c)).join("")).toBe(input);
});
