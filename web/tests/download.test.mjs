import assert from "node:assert/strict";
import { after, test } from "node:test";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";

const mf = new Miniflare(convertV4MiniflareOptions({
  modules: true,
  scriptPath: ".data/worker-test.mjs",
  compatibilityDate: "2026-10-13",
  r2Buckets: ["DOWNLOADS"],
  serviceBindings: { ASSETS: () => new Response("site asset", { headers: { "Content-Type": "text/html" } }) },
}));
after(() => mf.dispose());
const fetch = (path, init) => mf.dispatchFetch(`https://appea.rs${path}`, init);

for (const [path, markdownPath, title] of [
  ["/guides/", "/guides/index.md", "Search guides"],
  ["/guides/search-imessage-on-mac/", "/guides/search-imessage-on-mac.md", "Messages guide"],
]) {
test(`${path} negotiates its own Markdown without losing HTTP semantics`, async (t) => {
  const assets = new Map([[path, `<h1>${title}</h1>`], [markdownPath, `# ${title}\n`]]);
  const guideWorker = new Miniflare(convertV4MiniflareOptions({
    modules: true,
    scriptPath: ".data/worker-test.mjs",
    compatibilityDate: "2026-10-13",
    r2Buckets: ["DOWNLOADS"],
    serviceBindings: { ASSETS: (request) => {
      const body = assets.get(new URL(request.url).pathname);
      if (!body) return new Response("Missing", { status: 404 });
      const headers = { "content-type": new URL(request.url).pathname.endsWith(".md") ? "text/plain" : "text/html", etag: '"guide-v1"', vary: "Accept-Encoding" };
      if (request.headers.get("if-none-match") === '"guide-v1"') return new Response(null, { status: 304, headers });
      if (request.headers.has("range")) return new Response(body.slice(0, 4), { status: 206, headers: { ...headers, "content-range": `bytes 0-3/${body.length}` } });
      return new Response(request.method === "HEAD" ? null : body, { headers });
    } },
  }));
  try {
    const get = (url, init) => guideWorker.dispatchFetch(`https://appea.rs${url}`, init);
    await t.test("browser requests keep the HTML page", async () => {
      const response = await get(path, { headers: { Accept: "text/html" } });
      assert.equal(await response.text(), assets.get(path));
      assert.match(response.headers.get("vary"), /Accept-Encoding, Accept/);
    });
    await t.test("explicit and negotiated Markdown have the guide's canonical", async () => {
      for (const url of [path, markdownPath]) {
        const response = await get(url, { headers: { Accept: "text/markdown, text/html" } });
        assert.equal(await response.text(), assets.get(markdownPath));
        assert.equal(response.headers.get("content-type"), "text/markdown; charset=utf-8");
        assert.equal(response.headers.get("link"), `<https://appea.rs${path}>; rel="canonical"`);
        assert.match(response.headers.get("vary"), /Accept-Encoding, Accept/);
      }
    });
    await t.test("HEAD has no body and a matching validator stays 304", async () => {
      const head = await get(path, { method: "HEAD", headers: { Accept: "text/markdown" } });
      assert.equal(head.status, 200);
      assert.equal(await head.text(), "");
      const cached = await get(path, { headers: { Accept: "text/markdown", "If-None-Match": '"guide-v1"' } });
      assert.equal(cached.status, 304);
      assert.equal(await cached.text(), "");
      assert.equal(cached.headers.get("etag"), '"guide-v1"');
    });
    await t.test("partial responses retain their status and range", async () => {
      const response = await get(markdownPath, { headers: { Range: "bytes=0-3" } });
      assert.equal(response.status, 206);
      assert.equal(response.headers.get("content-range"), `bytes 0-3/${assets.get(markdownPath).length}`);
      assert.equal(await response.text(), assets.get(markdownPath).slice(0, 4));
    });
    await t.test("unknown guide paths remain 404", async () => {
      for (const url of ["/guides/missing/", "/guides/missing.md"]) {
        assert.equal((await get(url, { headers: { Accept: "text/markdown" } })).status, 404);
      }
    });
  } finally {
    await guideWorker.dispose();
  }
});
}

test("R2 downloads, redirects and resumable transfers", async (t) => {
  const bucket = await mf.getR2Bucket("DOWNLOADS");
  await t.test("first release is unavailable without caching the error", async () => {
    const response = await fetch("/app.dmg");
    assert.equal(response.status, 503);
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.match(await response.text(), /not available yet/);
    const head = await fetch("/app.dmg", { method: "HEAD" });
    assert.equal(head.status, 503);
    assert.equal(await head.text(), "");
  });

  await bucket.put("latest.json", JSON.stringify({ version: "0.1.0" }));
  await t.test("signed appcast is served byte for byte with a short cache", async () => {
    assert.equal((await fetch("/appcast.xml")).status, 503);
    const signed = '<?xml version="1.0"?><rss/>\n<!-- sparkle-signatures: example -->\n';
    await bucket.put("appcast.xml", signed);
    const response = await fetch("/appcast.xml");
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "application/rss+xml; charset=utf-8");
    assert.equal(response.headers.get("cache-control"), "public, max-age=300");
    assert.equal(await response.text(), signed);
    assert.equal(await (await fetch("/appcast.xml", { method: "HEAD" })).text(), "");
    assert.equal((await fetch("/appcast.xml", { method: "POST" })).status, 405);
  });
  const content = "0123456789";
  const object = await bucket.put("releases/v0.1.0/Appears.dmg", content);
  await bucket.put("releases/v0.1.0/Appears.dmg.sha256", "example checksum");
  await t.test("latest redirects to an immutable version without caching", async () => {
    const response = await fetch("/app.dmg", { redirect: "manual" });
    assert.equal(response.status, 302);
    assert.equal(response.headers.get("location"), "/downloads/v0.1.0/Appears.dmg");
    assert.equal(response.headers.get("cache-control"), "no-store");
  });
  await t.test("GET streams the object with download headers", async () => {
    const response = await fetch("/downloads/v0.1.0/Appears.dmg");
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-length"), "10");
    assert.equal(response.headers.get("content-type"), "application/x-apple-diskimage");
    assert.equal(response.headers.get("content-disposition"), 'attachment; filename="Appears.dmg"');
    assert.equal(response.headers.get("etag"), object.httpEtag);
    assert.match(response.headers.get("cache-control"), /immutable/);
    assert.equal(await response.text(), content);
  });
  await t.test("HEAD never returns a body", async () => {
    const response = await fetch("/downloads/v0.1.0/Appears.dmg", { method: "HEAD" });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-length"), "10");
    assert.equal(await response.text(), "");
  });
  await t.test("bounded, open-ended and suffix ranges return the requested bytes", async () => {
    for (const [range, result, contentRange] of [
      ["bytes=2-5", "2345", "bytes 2-5/10"],
      ["bytes=7-", "789", "bytes 7-9/10"],
      ["bytes=-3", "789", "bytes 7-9/10"],
      ["bytes=8-100", "89", "bytes 8-9/10"],
    ]) {
      const response = await fetch("/downloads/v0.1.0/Appears.dmg", { headers: { Range: range } });
      assert.equal(response.status, 206);
      assert.equal(response.headers.get("content-range"), contentRange);
      assert.equal(response.headers.get("content-length"), String(result.length));
      assert.equal(await response.text(), result);
    }
  });
  await t.test("unsatisfiable ranges return 416", async () => {
    for (const range of ["bytes=10-", "bytes=8-2", "bytes=-0"]) {
      const response = await fetch("/downloads/v0.1.0/Appears.dmg", { headers: { Range: range } });
      assert.equal(response.status, 416);
      assert.equal(response.headers.get("content-range"), "bytes */10");
      assert.equal(await response.text(), "");
    }
  });
  await t.test("matching validators return 304 without a body", async () => {
    for (const headers of [
      { "If-None-Match": object.httpEtag },
      { "If-None-Match": `W/${object.httpEtag}` },
      { "If-Modified-Since": object.uploaded.toUTCString() },
    ]) {
      const response = await fetch("/downloads/v0.1.0/Appears.dmg", { headers });
      assert.equal(response.status, 304);
      assert.equal(await response.text(), "");
    }
  });
  await t.test("If-Range mismatch restarts; matching ETag resumes", async () => {
    const response = await fetch("/downloads/v0.1.0/Appears.dmg", { headers: { Range: "bytes=5-", "If-Range": '"old"' } });
    assert.equal(response.status, 200);
    assert.equal(await response.text(), content);
    const resumed = await fetch("/downloads/v0.1.0/Appears.dmg", { headers: { Range: "bytes=5-", "If-Range": object.httpEtag } });
    assert.equal(resumed.status, 206);
    assert.equal(await resumed.text(), "56789");
  });
  await t.test("new pointer leaves old downloads intact", async () => {
    await bucket.put("releases/v0.2.0/Appears.dmg", "new version");
    await bucket.put("latest.json", JSON.stringify({ version: "0.2.0" }));
    const latest = await fetch("/app.dmg", { redirect: "manual" });
    assert.equal(latest.headers.get("location"), "/downloads/v0.2.0/Appears.dmg");
    assert.equal(await (await fetch("/downloads/v0.1.0/Appears.dmg")).text(), content);
  });
  await t.test("checksums are downloadable; arbitrary bucket keys stay private", async () => {
    const checksum = await fetch("/downloads/v0.1.0/Appears.dmg.sha256");
    assert.equal(checksum.status, 200);
    assert.equal(await checksum.text(), "example checksum");
    assert.equal((await fetch("/downloads/latest.json")).status, 404);
    assert.equal((await fetch("/downloads/v9.9.9/Appears.dmg")).status, 404);
    assert.equal((await fetch("/app.dmg", { method: "POST" })).status, 405);
  });
  await t.test("page assets and Markdown negotiation still work", async () => {
    const response = await fetch("/");
    assert.equal(await response.text(), "site asset");
    assert.equal(response.headers.get("vary"), "Accept");
    const markdown = await fetch("/", { headers: { Accept: "text/markdown" } });
    assert.match(markdown.headers.get("content-type"), /text\/markdown/);
    assert.equal(await markdown.text(), "site asset");
  });
  await t.test("pinned model URLs stream and resume without exposing other keys", async () => {
    const path = "/models/embeddinggemma-2-914f7f89142e/model.safetensors";
    await bucket.put(path.slice(1), "made-up model bytes");
    const response = await fetch(path, { headers: { Range: "bytes=0-6" } });
    assert.equal(response.status, 206);
    assert.equal(await response.text(), "made-up");
    assert.equal((await fetch("/models/other/private.json")).status, 404);
  });
  await t.test("model license files are downloadable without exposing arbitrary text files", async () => {
    const prefix = "/models/embeddinggemma-2-914f7f89142e-licenses1/";
    for (const name of ["LICENSE.txt", "NOTICE.txt"]) {
      await bucket.put((prefix + name).slice(1), "made-up license fixture");
      const response = await fetch(prefix + name);
      assert.equal(response.status, 200);
      assert.equal(await response.text(), "made-up license fixture");
    }
    await bucket.put((prefix + "private.txt").slice(1), "private fixture");
    assert.equal((await fetch(prefix + "private.txt")).status, 404);
    assert.equal((await fetch(prefix + "../private.txt")).status, 404);
  });
  await t.test("small immutable downloads are served from the Worker cache", async () => {
    const key = "releases/v3.0.0/Appears.dmg";
    await bucket.put(key, "small cached download");
    assert.equal(await (await fetch("/downloads/v3.0.0/Appears.dmg")).text(), "small cached download");
    await bucket.delete(key);
    const cached = await fetch("/downloads/v3.0.0/Appears.dmg");
    assert.equal(cached.status, 200);
    assert.equal(await cached.text(), "small cached download");
  });
});
