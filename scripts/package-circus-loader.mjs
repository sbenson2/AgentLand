#!/usr/bin/env node
// Package the circus loader (owner's request, 2026-10-04): ten 3D circus objects, ray-marched from signed
// distance fields and drawn as pixel art in the riders' five day tones, that melt into one another with
// rubber-hose timing. The owner approved this renderer on the prototype page
// (branding/candidates/circus-loader-20261004/circus-morphs.html); this script is that renderer, without the
// page, writing the frames the app plays:
//
//   CircusLoaderIdle-<object>.png         one bounce at rest, `idleFrames` frames, looped while it waits
//   CircusLoaderChange-<from>-<to>.png    the melt from one object into another, `changeFrames` frames
//   CircusLoaderNight…                    the same strips in the night tones
//   CircusLoader.json                     the objects, frame rate and frame counts
//
// Every pixel is transparent or one of the riders' five tones, day or night; the doorway uses the outline
// tone. The night strips are packaged too, rather than recoloured at launch, so the loading cover shows the
// loader at once. Frames are 96 x 96, objects about 64 tall.
// Run from the repository root: node scripts/package-circus-loader.mjs

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(ROOT, 'shared/AgentLandBranding/Sources/AgentLandBranding/Resources');
const DAY_TONES = [[0x11, 0x16, 0x1D], [0x35, 0x40, 0x52], [0x66, 0x72, 0x8A], [0xB3, 0xBD, 0xCA], [0xFF, 0xFF, 0xFF]];
const NIGHT_TONES = [[0x0F, 0x14, 0x1B], [0x62, 0x70, 0x8A], [0x90, 0x9D, 0xB3], [0xC7, 0xD0, 0xDC], [0xFF, 0xFF, 0xFF]];

const R = 96, H = R / 2, VH = 1.5;
const FPS = 15, IDLE_FRAMES = 8, CHANGE_FRAMES = 20;
const K = 0, D = 1, M = 2, L = 3, W = 4;

// Signed distance primitives (after Inigo Quilez). y is up; the camera looks down -z.
const len3 = (x, y, z) => Math.sqrt(x * x + y * y + z * z);
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const sphere = (x, y, z, r) => len3(x, y, z) - r;
const ellipsoid = (x, y, z, a, b, c) => { const k0 = len3(x / a, y / b, z / c), k1 = len3(x / (a * a), y / (b * b), z / (c * c)); return k0 * (k0 - 1) / k1; };
const capsule = (x, y, z, ax, ay, az, bx, by, bz, r) => {
  const px = x - ax, py = y - ay, pz = z - az, ux = bx - ax, uy = by - ay, uz = bz - az;
  const h = clamp((px * ux + py * uy + pz * uz) / (ux * ux + uy * uy + uz * uz), 0, 1);
  return len3(px - ux * h, py - uy * h, pz - uz * h) - r;
};
const torusZ = (x, y, z, Rr, r) => Math.hypot(Math.hypot(x, y) - Rr, z) - r;
const cylinderY = (x, y, z, h, r) => { const dx = Math.hypot(x, z) - r, dy = Math.abs(y) - h; return Math.min(Math.max(dx, dy), 0) + Math.hypot(Math.max(dx, 0), Math.max(dy, 0)); };
const roundBox = (x, y, z, bx, by, bz, r) => {
  const qx = Math.abs(x) - bx + r, qy = Math.abs(y) - by + r, qz = Math.abs(z) - bz + r;
  return len3(Math.max(qx, 0), Math.max(qy, 0), Math.max(qz, 0)) + Math.min(Math.max(qx, qy, qz), 0) - r;
};
const cone = (x, y, z, h, r1, r2) => {
  const qx = Math.hypot(x, z), qy = y, k2x = r2 - r1, k2y = 2 * h;
  const cax = qx - Math.min(qx, qy < 0 ? r1 : r2), cay = Math.abs(qy) - h;
  const t = clamp(((r2 - qx) * k2x + (h - qy) * k2y) / (k2x * k2x + k2y * k2y), 0, 1);
  const cbx = qx - r2 + k2x * t, cby = qy - h + k2y * t;
  const s = cbx < 0 && cay < 0 ? -1 : 1;
  return s * Math.sqrt(Math.min(cax * cax + cay * cay, cbx * cbx + cby * cby));
};
const star5 = (px, py, r, rf) => {
  const k1x = 0.809016994375, k1y = -0.587785252292, k2x = -k1x, k2y = k1y;
  px = Math.abs(px);
  let d = Math.max(k1x * px + k1y * py, 0); px -= 2 * d * k1x; py -= 2 * d * k1y;
  d = Math.max(k2x * px + k2y * py, 0); px -= 2 * d * k2x; py -= 2 * d * k2y;
  px = Math.abs(px); py -= r;
  const bax = rf * -k1y, bay = rf * k1x - 1;
  const h = clamp((px * bax + py * bay) / (bax * bax + bay * bay), 0, r);
  return Math.hypot(px - bax * h, py - bay * h) * Math.sign(py * bax - px * bay);
};
const stripes = (a, n) => Math.floor((a + Math.PI) / (Math.PI / n)) % 2 ? M : W;
const popcornPuffs = (x, y, z) => Math.min(sphere(x + 0.25, y - 0.28, z - 0.05, 0.19), sphere(x, y - 0.36, z - 0.08, 0.21),
  sphere(x - 0.25, y - 0.28, z, 0.19), sphere(x + 0.12, y - 0.52, z, 0.17), sphere(x - 0.14, y - 0.5, z + 0.03, 0.17));

const OBJECTS = [
  { id: 'ball', dist: (x, y, z) => sphere(x, y, z, 0.72), tone: (x, y) => Math.abs(y) < 0.11 ? M : L },
  { id: 'club',
    dist: (x, y, z) => Math.min(sphere(x, y - 0.82, z, 0.14), capsule(x, y, z, 0, 0.74, 0, 0, 0.2, 0, 0.085), ellipsoid(x, y + 0.3, z, 0.34, 0.6, 0.34)),
    tone: (x, y) => (y > 0.34 && y < 0.47) || (y < -0.6 && y > -0.74) ? D : W },
  { id: 'bigtop',
    dist: (x, y, z) => Math.min(cone(x, y - 0.33, z, 0.29, 0.82, 0.05), cylinderY(x, y + 0.37, z, 0.41, 0.66),
      capsule(x, y, z, 0, 0.58, 0, 0, 0.93, 0, 0.025), roundBox(x - 0.15, y - 0.86, z, 0.12, 0.05, 0.015, 0.012)),
    tone: (x, y, z) => {
      if (y > 0.8 && x > 0.03) return M;
      if (y > 0.6) return D;
      if (z > 0.3 && Math.abs(x) < 0.2 && y < -0.25) return K;
      if (y > -0.02 && y < 0.08) return L;
      return stripes(Math.atan2(z, x), 6);
    } },
  { id: 'star',
    dist: (x, y, z) => { const d2 = star5(x, y - 0.03, 0.9, 0.48) + 0.1, dz = Math.abs(z) - 0.12; return Math.min(Math.max(d2, dz), 0) + Math.hypot(Math.max(d2, 0), Math.max(dz, 0)) - 0.1; },
    tone: () => L },
  { id: 'balloon',
    dist: (x, y, z) => Math.min(ellipsoid(x, y - 0.15, z, 0.5, 0.6, 0.5), sphere(x, y + 0.5, z, 0.075), capsule(x, y, z, 0, -0.55, 0, 0.06, -0.95, 0, 0.022)),
    tone: (x, y) => y < -0.53 ? L : M },
  { id: 'hat',
    dist: (x, y, z) => Math.min(cylinderY(x, y - 0.17, z, 0.42, 0.4), cylinderY(x, y + 0.27, z, 0.03, 0.76) - 0.02),
    tone: (x, y, z) => y > -0.2 && y < -0.05 && Math.hypot(x, z) > 0.3 && Math.hypot(x, z) < 0.45 ? W : D },
  { id: 'hoop', dist: (x, y, z) => torusZ(x, y, z, 0.62, 0.14), tone: (x, y) => stripes(Math.atan2(y, x), 5) },
  { id: 'unicycle',
    dist: (x, y, z) => Math.min(torusZ(x, y + 0.5, z, 0.36, 0.075), sphere(x, y + 0.5, z, 0.07),
      capsule(x, y, z, -0.33, -0.5, 0, 0.33, -0.5, 0, 0.022), capsule(x, y, z, 0, -0.84, 0, 0, -0.5, 0, 0.022),
      capsule(x, y, z, 0, -0.5, 0, 0, 0.55, 0, 0.045), roundBox(x, y - 0.62, z, 0.24, 0.055, 0.11, 0.04)),
    tone: (x, y) => y > 0.55 ? M : Math.hypot(x, y + 0.5) > 0.29 ? D : L },
  { id: 'popcorn',
    dist: (x, y, z) => Math.min(cone(x, y + 0.35, z, 0.5, 0.34, 0.48), popcornPuffs(x, y, z)),
    tone: (x, y, z) => popcornPuffs(x, y, z) < cone(x, y + 0.35, z, 0.5, 0.34, 0.48) ? W : stripes(Math.atan2(z, x), 6) },
  { id: 'ticket',
    dist: (x, y, z) => Math.max(roundBox(x, y, z, 0.86, 0.42, 0.05, 0.03), -Math.min(Math.hypot(x - 0.86, y) - 0.15, Math.hypot(x + 0.86, y) - 0.15)),
    tone: (x, y) => {
      if (x > 0.48 && x < 0.55 && Math.floor((y + 1) * 12) % 2) return M;
      if (Math.abs(y) < 0.08 && x > -0.62 && x < 0.18) return D;
      return L;
    } },
];

const rotX = a => [[1, 0, 0], [0, Math.cos(a), -Math.sin(a)], [0, Math.sin(a), Math.cos(a)]];
const rotY = a => [[Math.cos(a), 0, Math.sin(a)], [0, 1, 0], [-Math.sin(a), 0, Math.cos(a)]];
const rotZ = a => [[Math.cos(a), -Math.sin(a), 0], [Math.sin(a), Math.cos(a), 0], [0, 0, 1]];
const mul = (a, b) => a.map(r => [0, 1, 2].map(j => r[0] * b[0][j] + r[1] * b[1][j] + r[2] * b[2][j]));
const IDENTITY = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];

const FLOOR = -0.95;
const q = [0, 0, 0];
function objectPoint(px, py, pz, pose, out) {
  const x = px / pose.sx, y = (py - pose.hop - FLOOR) / pose.sy + FLOOR, z = pz / pose.sz;
  const m = pose.rot;
  const ox = m[0][0] * x + m[1][0] * y + m[2][0] * z, oy = m[0][1] * x + m[1][1] * y + m[2][1] * z, oz = m[0][2] * x + m[1][2] * y + m[2][2] * z;
  out[0] = ox - Math.sin(oy * 2.4 + pose.bendPhase) * pose.bendAmp; out[1] = oy; out[2] = oz;
  return out;
}
function scene(px, py, pz, pose) {
  objectPoint(px, py, pz, pose, q);
  const a = pose.w < 1 ? OBJECTS[pose.a].dist(q[0], q[1], q[2]) : 0;
  const b = pose.w > 0 ? OBJECTS[pose.b].dist(q[0], q[1], q[2]) : 0;
  const d = pose.w <= 0 ? a : pose.w >= 1 ? b : a + (b - a) * pose.w;
  return d * Math.min(pose.sx, pose.sy, pose.sz) * 0.7;
}

const BAYER = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map(v => (v + 0.5) / 16);
const ign = (x, y) => { const f = v => v - Math.floor(v); return f(52.9829189 * f(0.06711056 * x + 0.00583715 * y)); };
const LIGHT = (() => { const v = [-0.55, 0.65, 0.55], n = Math.hypot(...v); return v.map(c => c / n); })();

// One frame: tone indices per pixel (-1 empty), with the silhouette outline, inner outlines where a nearer
// part overlaps a farther one, and the floor shadow, all in the outline tone.
function render(pose) {
  const tone = new Int8Array(R * R).fill(-1), depth = new Float32Array(R * R);
  for (let v = 0; v < R; v++) for (let u = 0; u < R; u++) {
    const x = (u + 0.5 - H) / H * VH, y = -(v + 0.5 - H) / H * VH;
    let t = 0, hit = false;
    for (let i = 0; i < 70 && t < 4; i++) {
      const d = scene(x, y, 2 - t, pose);
      if (d < 0.003) { hit = true; break; }
      t += Math.max(d, 0.004);
    }
    if (!hit) continue;
    const z = 2 - t, e = 0.01;
    const nx = scene(x + e, y, z, pose) - scene(x - e, y, z, pose);
    const ny = scene(x, y + e, z, pose) - scene(x, y - e, z, pose);
    const nz = scene(x, y, z + e, pose) - scene(x, y, z - e, pose);
    const nl = Math.hypot(nx, ny, nz) || 1;
    const diffuse = Math.max(0, (nx * LIGHT[0] + ny * LIGHT[1] + nz * LIGHT[2]) / nl);
    objectPoint(x, y, z, pose, q);
    const which = pose.w <= 0 ? pose.a : pose.w >= 1 ? pose.b : (ign(u, v) < pose.w ? pose.b : pose.a);
    const base = OBJECTS[which].tone(q[0], q[1], q[2]);
    const i = v * R + u;
    depth[i] = t;
    if (base === K) { tone[i] = 0; continue; }
    tone[i] = clamp(Math.round(base + (diffuse - 0.6) * 2.6 + (BAYER[(u & 3) + (v & 3) * 4] - 0.5) * 0.9), 1, 4);
  }
  const out = new Int8Array(R * R).fill(-1);
  for (let i = 0; i < R * R; i++) {
    const x = i % R, y = (i / R) | 0;
    if (tone[i] >= 0) {
      out[i] = tone[i];
      for (const [ox, oy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        const xx = x + ox, yy = y + oy, j = yy * R + xx;
        if (xx >= 0 && yy >= 0 && xx < R && yy < R && tone[j] >= 0 && depth[i] - depth[j] > 0.3) { out[i] = 0; break; }
      }
      continue;
    }
    let outline = false;
    for (let oy = -2; oy <= 2 && !outline; oy++) for (let ox = -2; ox <= 2; ox++) {
      if (Math.abs(ox) + Math.abs(oy) > 2) continue;
      const xx = x + ox, yy = y + oy;
      if (xx >= 0 && yy >= 0 && xx < R && yy < R && tone[yy * R + xx] >= 0) { outline = true; break; }
    }
    if (!outline) {
      const sw = 19 * (1 - pose.hop * 1.6) * Math.sqrt(pose.sx), sy0 = H + (-FLOOR) / VH * H + 3;
      outline = ((x + 0.5 - H) / sw) ** 2 + ((y + 0.5 - sy0) / 2.6) ** 2 < 1;
    }
    if (outline) out[i] = 0;
  }
  return out;
}

// Rubber-hose timing. The squash keys start and end at the rest pose's squash, so a melt begins and ends
// exactly where the idle bounce touches down.
const SQUASH = [[0, 0.93], [0.12, 0.8], [0.22, 1.25], [0.45, 1.1], [0.62, 1.15], [0.74, 0.78], [0.84, 1.12], [0.92, 0.9], [1, 0.93]];
const keyed = (keys, t) => {
  for (let i = 1; i < keys.length; i++) if (t <= keys[i][0]) {
    const [t0, v0] = keys[i - 1], [t1, v1] = keys[i], f = (t - t0) / (t1 - t0);
    return v0 + (v1 - v0) * (0.5 - 0.5 * Math.cos(Math.PI * f));
  }
  return keys[keys.length - 1][1];
};
const smooth = (a, b, t) => { const x = clamp((t - a) / (b - a), 0, 1); return x * x * (3 - 2 * x); };
const easeInOut = t => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

function changePose(a, b, t, spinSign) {
  const w = smooth(0.25, 0.7, t), air = clamp((t - 0.12) / 0.62, 0, 1);
  const sy = keyed(SQUASH, t), sxz = 1 / Math.sqrt(sy);
  const rot = mul(mul(rotY(spinSign * easeInOut(air) * Math.PI * 2), rotZ(0.35 * Math.sin(2 * Math.PI * air))), rotX(0.25 * Math.sin(Math.PI * air)));
  return { a, b, w, hop: 0.3 * Math.sin(Math.PI * air), sx: sxz, sy, sz: sxz, rot,
           bendAmp: 0.14 * Math.sin(Math.PI * clamp((t - 0.1) / 0.7, 0, 1)), bendPhase: t * 9 };
}
// One bounce of the idle loop: touches down (the rest pose) at its first frame.
function idlePose(a, k) {
  const beat = Math.abs(Math.sin(Math.PI * k / IDLE_FRAMES));
  const sy = 1 - 0.07 * (1 - beat) + 0.03 * beat, sxz = 1 / Math.sqrt(sy);
  return { a, b: a, w: 0, hop: 0.05 * beat, sx: sxz, sy, sz: sxz, rot: IDENTITY, bendAmp: 0, bendPhase: 0 };
}

function png(width, height, rgba) {
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) rgba.copy(raw, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
  const chunk = (type, data) => {
    const length = Buffer.alloc(4); length.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(zlib.crc32(body));
    return Buffer.concat([length, body, crc]);
  };
  const header = Buffer.alloc(13); header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}

function writeStrip(name, frames, tones) {
  const width = R * frames.length, rgba = Buffer.alloc(width * R * 4);
  frames.forEach((frame, f) => {
    for (let i = 0; i < R * R; i++) {
      const t = frame[i];
      if (t < 0) continue;
      const x = f * R + (i % R), y = (i / R) | 0, o = (y * width + x) * 4, c = tones[t];
      rgba[o] = c[0]; rgba[o + 1] = c[1]; rgba[o + 2] = c[2]; rgba[o + 3] = 255;
    }
  });
  const file = path.join(OUT, `${name}.png`);
  fs.writeFileSync(file, png(width, R, rgba));
  return fs.statSync(file).size;
}

let bytes = 0;
const started = Date.now();
OBJECTS.forEach((object, a) => {
  const idle = Array.from({ length: IDLE_FRAMES }, (_, k) => render(idlePose(a, k)));
  bytes += writeStrip(`CircusLoaderIdle-${object.id}`, idle, DAY_TONES) + writeStrip(`CircusLoaderNightIdle-${object.id}`, idle, NIGHT_TONES);
  OBJECTS.forEach((other, b) => {
    if (a === b) return;
    const spin = (a + b) % 2 ? 1 : -1;
    const change = Array.from({ length: CHANGE_FRAMES }, (_, k) => render(changePose(a, b, k / CHANGE_FRAMES, spin)));
    bytes += writeStrip(`CircusLoaderChange-${object.id}-${other.id}`, change, DAY_TONES) + writeStrip(`CircusLoaderNightChange-${object.id}-${other.id}`, change, NIGHT_TONES);
  });
});
fs.writeFileSync(path.join(OUT, 'CircusLoader.json'), JSON.stringify({
  side: R, framesPerSecond: FPS, idleFrames: IDLE_FRAMES, changeFrames: CHANGE_FRAMES, objects: OBJECTS.map(o => o.id)
}, null, 2) + '\n');
console.log(`${OBJECTS.length} idle strips and ${OBJECTS.length * (OBJECTS.length - 1)} changes, day and night, ${(bytes / 1024).toFixed(0)} KB, in ${((Date.now() - started) / 1000).toFixed(1)} s`);
