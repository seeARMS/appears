import type { R2Bucket } from "@cloudflare/workers-types";

/** The bucket stays private. Only these release objects are exposed by the Worker. */
export async function download(request: Request, bucket: R2Bucket): Promise<Response> {
  const path = new URL(request.url).pathname;
  const reading = request.method === "GET" || request.method === "HEAD";
  if (!reading) return new Response(null, { status: 405, headers: { Allow: "GET, HEAD" } });

  if (path === "/app.dmg") {
    const latest = await bucket.get("latest.json");
    if (!latest) return unavailable(request);
    const { version } = await latest.json<{ version?: string }>();
    if (!version || !/^\d+\.\d+\.\d+$/.test(version)) return unavailable(request);
    // Never cache the alias. A download resolves once, then stays on that version
    // even if another release is published while the download is paused.
    return new Response(null, {
      status: 302,
      headers: { Location: `/downloads/v${version}/Appears.dmg`, "Cache-Control": "no-store" },
    });
  }

  const match = /^\/downloads\/(v\d+\.\d+\.\d+)\/(Appears\.dmg(?:\.sha256)?)$/.exec(path);
  const model = /^\/models\/(embeddinggemma-2-[a-f0-9]{12})\/([a-zA-Z0-9_-]+\.(?:safetensors|json|jinja|model))$/.exec(path);
  if (!match && !model) return new Response(null, { status: 404 });
  const key = match ? `releases/${match[1]}/${match[2]}` : `models/${model![1]}/${model![2]}`;
  const filename = (match ?? model)![2];
  const head = await bucket.head(key);
  if (!head) return new Response(null, { status: 404, headers: { "Cache-Control": "no-store" } });
  const headers = new Headers({
    "Content-Type": model ? "application/octet-stream" : filename.endsWith(".sha256") ? "text/plain; charset=utf-8" : "application/x-apple-diskimage",
    "Content-Disposition": `attachment; filename="${filename}"`,
    "Content-Length": String(head.size),
    "Cache-Control": "public, max-age=31536000, immutable",
    "ETag": head.httpEtag,
    "Last-Modified": head.uploaded.toUTCString(),
    "Accept-Ranges": "bytes",
    "X-Content-Type-Options": "nosniff",
  });
  const noneMatch = request.headers.get("if-none-match");
  const modifiedSince = request.headers.get("if-modified-since");
  if (
    (noneMatch && noneMatch.split(",").some((tag) => tag.trim().replace(/^W\//, "") === head.httpEtag || tag.trim() === "*")) ||
    (!noneMatch && modifiedSince && Date.parse(modifiedSince) >= Math.floor(head.uploaded.getTime() / 1000) * 1000)
  ) {
    headers.delete("Content-Length");
    return new Response(null, { status: 304, headers });
  }

  let range: { offset: number; length: number } | undefined;
  const rangeHeader = request.headers.get("range");
  const ifRange = request.headers.get("if-range");
  const mayRange = !ifRange || ifRange === head.httpEtag || Date.parse(ifRange) >= Math.floor(head.uploaded.getTime() / 1000) * 1000;
  // Ignore malformed or multipart ranges; support resumable single-range downloads.
  const parts = reading && mayRange && rangeHeader && /^bytes=(\d*)-(\d*)$/.exec(rangeHeader);
  if (parts && (parts[1] || parts[2])) {
    const offset = parts[1] ? Number(parts[1]) : Math.max(0, head.size - Number(parts[2]));
    const end = parts[1] && parts[2] ? Math.min(Number(parts[2]), head.size - 1) : head.size - 1;
    if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(end) || offset > end) {
      headers.set("Content-Range", `bytes */${head.size}`);
      headers.set("Content-Length", "0");
      return new Response(null, { status: 416, headers });
    }
    range = { offset, length: end - offset + 1 };
    headers.set("Content-Range", `bytes ${offset}-${end}/${head.size}`);
    headers.set("Content-Length", String(range.length));
  }
  if (request.method === "HEAD") return new Response(null, { status: range ? 206 : 200, headers });
  const object = await bucket.get(key, range ? { range } : undefined);
  if (!object) return new Response(null, { status: 404, headers: { "Cache-Control": "no-store" } });
  // Stream the body: the model is larger than both Worker memory and the standard
  // CDN cache limit. R2 has no egress charge; browsers can cache immutable versions.
  // R2 and the DOM library describe the same native stream with different
  // async-iterator types (the DOM type also has async-disposal methods).
  return new Response(object.body as unknown as ReadableStream<Uint8Array>, { status: range ? 206 : 200, headers });
}

function unavailable(request: Request): Response {
  return new Response(request.method === "HEAD" ? null : "The first download is not available yet. Please check back soon.", {
    status: 503,
    headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store", "Retry-After": "300" },
  });
}
