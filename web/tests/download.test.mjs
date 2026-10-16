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
