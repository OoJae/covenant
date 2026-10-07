// The little matrix arithmetic the scene needs: column-major 4x4 matrices in preallocated Float32Arrays
// (WebGL's layout), a perspective projection, a look-at view and a point projection. Nothing allocates.

export type M4 = Float32Array;

export const m4 = (): M4 => new Float32Array(16);

export const clamp01 = (x: number): number => (x < 0 ? 0 : x > 1 ? 1 : x);

/** 0 before `a`, 1 after `b`, linear in between. */
export const span = (t: number, a: number, b: number): number => clamp01((t - a) / (b - a));

/** Ease in and out (cubic). */
export const ease = (x: number): number => (x < 0.5 ? 4 * x * x * x : 1 - (-2 * x + 2) ** 3 / 2);

export function perspective(o: M4, fovy: number, aspect: number, near: number, far: number): M4 {
  const f = 1 / Math.tan(fovy / 2);
  const nf = 1 / (near - far);
  o.fill(0);
  o[0] = f / aspect;
  o[5] = f;
  o[10] = (far + near) * nf;
  o[11] = -1;
  o[14] = 2 * far * near * nf;
  return o;
}

/** View matrix of a camera at c[0..2] looking at c[3..5], c[6..8] pointing up. */
export function lookAt(o: M4, c: ArrayLike<number>): M4 {
  const e0 = c[0];
  const e1 = c[1];
  const e2 = c[2];
  let zx = e0 - c[3];
  let zy = e1 - c[4];
  let zz = e2 - c[5];
  const u0 = c[6];
  const u1 = c[7];
  const u2 = c[8];
  let l = Math.hypot(zx, zy, zz) || 1;
  zx /= l;
  zy /= l;
  zz /= l;
  let xx = u1 * zz - u2 * zy;
  let xy = u2 * zx - u0 * zz;
  let xz = u0 * zy - u1 * zx;
  l = Math.hypot(xx, xy, xz) || 1;
  xx /= l;
  xy /= l;
  xz /= l;
  const yx = zy * xz - zz * xy;
  const yy = zz * xx - zx * xz;
  const yz = zx * xy - zy * xx;
  o[0] = xx;
  o[1] = yx;
  o[2] = zx;
  o[3] = 0;
  o[4] = xy;
  o[5] = yy;
  o[6] = zy;
  o[7] = 0;
  o[8] = xz;
  o[9] = yz;
  o[10] = zz;
  o[11] = 0;
  o[12] = -(xx * e0 + xy * e1 + xz * e2);
  o[13] = -(yx * e0 + yy * e1 + yz * e2);
  o[14] = -(zx * e0 + zy * e1 + zz * e2);
  o[15] = 1;
  return o;
}

/** o = a * b. `o` must be neither `a` nor `b`. */
export function mul(o: M4, a: M4, b: M4): M4 {
  for (let c = 0; c < 4; c++) {
    for (let r = 0; r < 4; r++) {
      o[c * 4 + r] = a[r] * b[c * 4] + a[4 + r] * b[c * 4 + 1] + a[8 + r] * b[c * 4 + 2] + a[12 + r] * b[c * 4 + 3];
    }
  }
  return o;
}

/** Projects a world point through `m` into normalised device coordinates in out[0..1]; false if behind the eye. */
export function project(m: M4, x: number, y: number, z: number, out: Float32Array): boolean {
  const w = m[3] * x + m[7] * y + m[11] * z + m[15];
  if (w <= 1e-6) return false;
  out[0] = (m[0] * x + m[4] * y + m[8] * z + m[12]) / w;
  out[1] = (m[1] * x + m[5] * y + m[9] * z + m[13]) / w;
  return true;
}
