// Advance widths straight from a TrueType file (cmap + hmtx), so share cards
// can fit and wrap text before resvg draws it: resvg has no layout of its own.
// Kerning is ignored, which only ever overestimates, so text fits with room.

export interface FontMetrics {
  /** Advance of one character at 1px font size, or undefined when the font has no glyph for it. */
  advance(cp: number): number | undefined;
}

export function readMetrics(data: ArrayBuffer | Uint8Array): FontMetrics {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tables = new Map<string, number>();
  for (let i = 0, n = v.getUint16(4); i < n; i++) {
    const at = 12 + i * 16;
    tables.set(String.fromCharCode(v.getUint8(at), v.getUint8(at + 1), v.getUint8(at + 2), v.getUint8(at + 3)), v.getUint32(at + 8));
  }
  const table = (tag: string) => {
    const at = tables.get(tag);
    if (at === undefined) throw new Error(`Font has no ${tag} table`);
    return at;
  };

  const upm = v.getUint16(table("head") + 18);
  const metricCount = v.getUint16(table("hhea") + 34);
  const hmtx = table("hmtx");
  const width = (glyph: number) => v.getUint16(hmtx + Math.min(glyph, metricCount - 1) * 4) / upm;

  // Prefer the full-Unicode subtable (format 12), else the BMP one (format 4).
  const cmap = table("cmap");
  let format4 = -1;
  let format12 = -1;
  for (let i = 0, n = v.getUint16(cmap + 2); i < n; i++) {
    const rec = cmap + 4 + i * 8;
    const platform = v.getUint16(rec);
    const encoding = v.getUint16(rec + 2);
    const sub = cmap + v.getUint32(rec + 4);
    const format = v.getUint16(sub);
    if (format === 12 && (platform === 0 || (platform === 3 && encoding === 10))) format12 = sub;
    if (format === 4 && (platform === 0 || (platform === 3 && encoding === 1))) format4 = sub;
  }

  function glyphOf(cp: number): number {
    if (format12 >= 0) {
      const groups = v.getUint32(format12 + 12);
      let lo = 0;
      let hi = groups - 1;
      while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        const g = format12 + 16 + mid * 12;
        const start = v.getUint32(g);
        if (cp < start) hi = mid - 1;
        else if (cp > v.getUint32(g + 4)) lo = mid + 1;
        else return v.getUint32(g + 8) + (cp - start);
      }
      return 0;
    }
    if (format4 < 0 || cp > 0xffff) return 0;
    const segs = v.getUint16(format4 + 6) / 2;
    const ends = format4 + 14;
    const starts = ends + segs * 2 + 2;
    const deltas = starts + segs * 2;
    const ranges = deltas + segs * 2;
    for (let i = 0; i < segs; i++) {
      if (cp > v.getUint16(ends + i * 2)) continue;
      const start = v.getUint16(starts + i * 2);
      if (cp < start) return 0;
      const delta = v.getUint16(deltas + i * 2);
      const range = v.getUint16(ranges + i * 2);
      if (range === 0) return (cp + delta) & 0xffff;
      const g = v.getUint16(ranges + i * 2 + range + (cp - start) * 2);
      return g === 0 ? 0 : (g + delta) & 0xffff;
    }
    return 0;
  }

  const cache = new Map<number, number | undefined>();
  return {
    advance(cp) {
      if (cache.has(cp)) return cache.get(cp);
      const glyph = glyphOf(cp);
      const w = glyph === 0 ? undefined : width(glyph);
      cache.set(cp, w);
      return w;
    },
  };
}
