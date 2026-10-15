/** Orbit's approved 24-point drawing, shared by the site, share card and asset generator.
 * The Mac app uses the same coordinates in mac/App/Sources/Orbit.swift.
 */
const center = { x: 11.5, y: 12.8 };
const radius = 7.5;
const start = Math.PI / 18;
const point = (angle: number) =>
  `${+(center.x + radius * Math.cos(angle)).toFixed(6)} ${+(center.y + radius * Math.sin(angle)).toFixed(6)}`;

export const ORBIT = {
  arc: `M ${point(start)} A ${radius} ${radius} 0 1 1 ${point(Math.PI * 1.5)}`,
  indexingArc: `M ${point(start)} A ${radius} ${radius} 0 1 1 ${point(4.06)}`,
  lineWidth: 2.1,
  dot: { x: 17.5, y: 6.4, radius: 2.65 },
} as const;

/** The 48-point tile, with the symbol inset by 17% on each edge. */
export function orbitMarkArtwork(): string {
  return `<rect width="48" height="48" rx="11.28" fill="#18181B"/>
<g transform="translate(8.16 8.16) scale(1.32)">
  <path d="${ORBIT.arc}" fill="none" stroke="#FAFAFA" stroke-width="${ORBIT.lineWidth}" stroke-linecap="round"/>
  <circle cx="${ORBIT.dot.x}" cy="${ORBIT.dot.y}" r="${ORBIT.dot.radius}" fill="#2563EB"/>
</g>`;
}
