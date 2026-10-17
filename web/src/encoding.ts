export function inputChunks(text: string, limit = 8192): Uint8Array[] {
  const bytes = new TextEncoder().encode(text),
    chunks: Uint8Array[] = [];
  for (let start = 0; start < bytes.length; ) {
    let end = Math.min(start + limit, bytes.length);
    while (end < bytes.length && (bytes[end] & 0xc0) === 0x80) end--;
    if (end === start)
      throw new Error("Input chunk size cannot hold a character.");
    chunks.push(bytes.slice(start, end));
    start = end;
  }
  return chunks;
}
