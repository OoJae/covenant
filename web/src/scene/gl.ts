// A minimal WebGL2 renderer for the die scene, no library: one instanced box draw (every cell, the 64 seal
// targets, the seal plate, its pin-1 square and the substrate), one additive LINES draw for the wires and one
// additive POINTS draw for the glow. All animation happens in the vertex shaders from a handful of uniforms,
// so a frame uploads no buffers and allocates nothing.
//
// The canvas is transparent and the page's background shows through it. Additive draws write colour only
// (alpha is kept), so the glow adds light to whatever is behind the canvas.

import { STRIDE, WSTRIDE, type SceneData } from './data.ts';
import type { M4 } from './math.ts';

/** Uniform pack slots: D (cols, rows, maxLevel, portrait), T (power, input, wave, relight), U (fly, flip, route,
 * press), S (seal x, y, z, pitch), E (eye x, y, z, camera distance), K (pixels per world unit at w = 1). */
export const PACK = 21;

const HEAD = `#version 300 es
precision highp float;
uniform mat4 V;uniform vec4 D,T,U,S,E;
const vec3 GOLD=vec3(.902,.706,.314),QZ=vec3(.91,.894,.855),Q2=vec3(.557,.58,.612),OFF=vec3(.12,.138,.165),ALW=vec3(.478,.655,1.),RES=vec3(.247,.827,.753);
float r(float w,float l,float s){return clamp((w-l)/s+1.,0.,1.);}
vec2 rot(vec2 c){return D.w>.5?vec2(c.y,-c.x):c;}
`;

// cell(): P = centre of the box's base (world), Z = size (x, y, height), C = colour, H and G = glow colour and strength.
const CELL = `${HEAD}layout(location=2) in vec4 a;layout(location=3) in vec4 b;
vec3 P,Z,C,H;float G;
void cell(){
float k=a.w,lv=a.z,i=b.z,cw=5./7.;
vec2 c=rot(vec2(a.x+cw*.5-D.x*.5,D.y*.5-a.y-cw*.5));
float on=r(T.x,lv,6.),pf=on*exp(-max(T.x-lv,0.)*.3),re=r(T.z,lv,3.),rl=r(T.w,lv,3.),v=mix(b.x,b.y,rl),
fr=re*exp(-max(T.z-lv,0.)*.16),fb=rl*exp(-max(T.w-lv,0.)*.3)*abs(b.y-b.x),
vis=smoothstep(0.,.3,U.x);
vec2 sp=S.xy+vec2(mod(i,8.)-3.5,3.5-floor(i/8.))*S.w;
P=vec3(c,0.);Z=vec3(cw,cw,.1*on);C=OFF;H=QZ;G=pf*.25;
if(k<.5){C=mix(OFF,Q2,b.x);Z.z=.16*on;}
else if(k<1.5){float l=b.x*r(T.y*112.-8.,i,8.);C=mix(OFF*1.5,GOLD,l);Z.z=(.16+l*.55)*on;H=GOLD;G+=l*.8;}
else if(k<2.5||(k>3.5&&k<4.5)){float l=v*re;C=mix(OFF,GOLD*(.8+.2*fr+.2*fb),l);Z.z+=l*(.45+.9*fr+.6*fb);H=GOLD;G+=l*(.1+.9*fr)+fb;}
else if(k<3.5){
float f=clamp(U.x*1.5-i/63.*.5,0.,1.);f=f*f*(3.-2.*f);
float q=clamp(U.y*1.6-(mod(i,8.)+floor(i/8.))/14.*.6,0.,1.),w=q<.5?b.x:b.y,s=mix(cw,S.w*.8,f);
P=mix(P,vec3(sp,S.z+.3),f);P.z+=sin(f*3.1416)*6.;
Z=vec3(s,s,mix(.3*on,.55,f)*max(abs(cos(q*3.1416)),.08));
C=mix(Q2*.3,QZ,w);G+=w*(f*(1.-f)*2.+sin(q*3.1416)*.9);}
else if(k<5.5){
float s=r(U.z*136.-12.,i,12.),l=v*re;
vec3 h=b.w<.5?QZ:b.w<1.5?GOLD:b.w<2.5?ALW:RES;
C=mix(mix(OFF*1.5,Q2,l*.7),h*(.32+.68*v),s);Z.z=(.16+s*v*.5)*on;H=h;G+=s*v*(.35+.65*exp(-max(U.z*136.-12.-i,0.)*.08));}
else if(k<6.5){P=vec3(sp,S.z+.3);Z=vec3(vec2(S.w*.9*vis),.03);C=vec3(.025,.028,.034);G=0.;}
else if(k<7.5){P=vec3(S.xy,S.z);Z=vec3(vec2(8.9*S.w*vis),.3*vis);C=vec3(.13,.145,.17);G=0.;}
else if(k<8.5){P=vec3(S.xy+vec2(-4.2,4.2)*S.w,S.z);Z=vec3(vec2(.32*S.w*vis),.38*vis);C=GOLD;G=0.;}
else{P=vec3(c,-.14);Z=vec3(D.w>.5?D.yx+1.:D.xy+1.,.14);C=vec3(.058,.068,.084);G=0.;}
}
`;

// vK: for the seal plate, x + 1 - y over the box's unit square (0 at its top-left corner, next to bit 0), so the
// fragment shader cuts the pin-1 chamfer, 14% of the side as on the brand's Seal; 2 on every other box.
const BOX_VS = `${CELL}layout(location=0) in vec3 p;layout(location=1) in vec3 n;out vec3 vC;out float vK;
void main(){cell();
vec3 w=P+vec3((p.xy-.5)*Z.xy,p.z*Z.z);
gl_Position=V*vec4(w,1.);
float d=max(dot(n,normalize(vec3(-.7,.35,.55))),0.),f=clamp(1.2-(distance(w,E.xyz)-E.w*.8)/(E.w*1.2),.45,1.);
vK=a.w>6.5&&a.w<7.5?p.x+1.-p.y:2.;
vC=(C*(.36+.8*d)+H*min(G,1.)*.2)*f;}`;

const BOX_FS = `#version 300 es
precision mediump float;in vec3 vC;in float vK;out vec4 o;void main(){if(vK<.14)discard;o=vec4(vC,1.);}`;

const GLOW_VS = `${CELL}uniform float K;out vec3 vG;
void main(){cell();
vec4 q=V*vec4(P+vec3(0.,0.,Z.z+.15),1.);
gl_Position=G>.02?q:vec4(2.,2.,2.,1.);
gl_PointSize=min(K*2.8/q.w,160.);
vG=H*min(G,1.6);}`;

const ADD_FS = `#version 300 es
precision mediump float;in vec3 vG;out vec4 o;
void main(){vec2 d=gl_PointCoord*2.-1.;float f=max(1.-dot(d,d),0.);o=vec4(vG*f*f*.5,0.);}`;

const WIRE_VS = `${HEAD}layout(location=0) in vec4 w;out vec3 vG;
void main(){
float f=w.w,lp=mod(f,2.),sa=mod(floor(f*.5),2.),sb=mod(floor(f*.25),2.);
gl_Position=V*vec4(rot(vec2(w.x-D.x*.5,D.y*.5-w.y)),.015,1.);
float lv=w.z,on=r(T.x,lv,6.),re=r(T.z,lv,3.),v=mix(sa,sb,r(T.w,lv,3.))*re,fr=re*exp(-max(T.z-lv,0.)*.2);
vG=((lp>.5?GOLD:QZ)*.08*on+GOLD*v*(.05+.35*fr))*(1.-lp*U.x);}`;

const WIRE_FS = `#version 300 es
precision mediump float;in vec3 vG;out vec4 o;void main(){o=vec4(vG,0.);}`;

// A unit box without its bottom face: positions and normals, four corners per face.
const BOX = new Float32Array([
  0, 0, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 1, 1, 1, 0, 0, 1, 0, 1, 1, 0, 0, 1,
  0, 0, 0, 0, -1, 0, 1, 0, 0, 0, -1, 0, 1, 0, 1, 0, -1, 0, 0, 0, 1, 0, -1, 0,
  1, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0,
  0, 1, 0, -1, 0, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, -1, 0, 0, 0, 1, 1, -1, 0, 0,
  1, 0, 0, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 1, 1, 1, 0, 0, 1, 0, 1, 1, 0, 0,
]);
const BOX_IDX = new Uint8Array(30).map((_, i) => 4 * Math.floor(i / 6) + [0, 1, 2, 0, 2, 3][i % 6]);

export interface Renderer {
  /** Draws one frame with view-projection `vp` and the uniform pack (PACK floats); `glow` false skips the glow. */
  draw(vp: M4, pack: Float32Array, glow: boolean): void;
  destroy(): void;
}

function program(gl: WebGL2RenderingContext, vs: string, fs: string): WebGLProgram | null {
  const p = gl.createProgram();
  const shaders: WebGLShader[] = [];
  for (const [type, src] of [
    [gl.VERTEX_SHADER, vs],
    [gl.FRAGMENT_SHADER, fs],
  ] as const) {
    const s = gl.createShader(type)!;
    gl.shaderSource(s, src);
    gl.compileShader(s);
    gl.attachShader(p, s);
    shaders.push(s);
  }
  gl.linkProgram(p);
  const ok = gl.getProgramParameter(p, gl.LINK_STATUS);
  if (!ok) for (const s of shaders) if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) console.error(gl.getShaderInfoLog(s));
  for (const s of shaders) gl.deleteShader(s);
  if (ok) return p;
  gl.deleteProgram(p);
  return null;
}

export function createRenderer(gl: WebGL2RenderingContext, d: SceneData): Renderer | null {
  const box = program(gl, BOX_VS, BOX_FS);
  const glow = program(gl, GLOW_VS, ADD_FS);
  const wire = program(gl, WIRE_VS, WIRE_FS);
  if (!box || !glow || !wire) return null;

  const buf = (target: number, data: AllowSharedBufferSource): WebGLBuffer => {
    const b = gl.createBuffer()!;
    gl.bindBuffer(target, b);
    gl.bufferData(target, data, gl.STATIC_DRAW);
    return b;
  };
  const attrib = (loc: number, size: number, stride: number, offset: number, divisor: number): void => {
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, size, gl.FLOAT, false, stride * 4, offset * 4);
    gl.vertexAttribDivisor(loc, divisor);
  };

  const vBox = gl.createVertexArray()!;
  gl.bindVertexArray(vBox);
  const bBox = buf(gl.ARRAY_BUFFER, BOX);
  attrib(0, 3, 6, 0, 0);
  attrib(1, 3, 6, 3, 0);
  const bInst = buf(gl.ARRAY_BUFFER, d.inst);
  attrib(2, 4, STRIDE, 0, 1);
  attrib(3, 4, STRIDE, 4, 1);
  const bIdx = buf(gl.ELEMENT_ARRAY_BUFFER, BOX_IDX);

  const vGlow = gl.createVertexArray()!;
  gl.bindVertexArray(vGlow);
  gl.bindBuffer(gl.ARRAY_BUFFER, bInst);
  attrib(2, 4, STRIDE, 0, 0);
  attrib(3, 4, STRIDE, 4, 0);

  const vWire = gl.createVertexArray()!;
  gl.bindVertexArray(vWire);
  const bWire = buf(gl.ARRAY_BUFFER, d.wires);
  attrib(0, 4, WSTRIDE, 0, 0);
  gl.bindVertexArray(null);
  const wireVerts = d.wires.length / WSTRIDE;

  // Uniform locations, and views of the pack made once (uniform4fv reads them without copying).
  const names = ['V', 'D', 'T', 'U', 'S', 'E'] as const;
  const locs = [box, glow, wire].map((p) => names.map((n) => gl.getUniformLocation(p, n)));
  const kLoc = gl.getUniformLocation(glow, 'K');
  let pack: Float32Array | null = null;
  const views: Float32Array[] = [];
  const setUniforms = (i: number, vp: M4): void => {
    const l = locs[i];
    gl.uniformMatrix4fv(l[0], false, vp);
    for (let k = 0; k < 5; k++) gl.uniform4fv(l[k + 1], views[k]);
  };

  return {
    draw(vp, p, glowOn) {
      if (p !== pack) {
        pack = p;
        views.length = 0;
        for (let k = 0; k < 5; k++) views.push(p.subarray(4 * k, 4 * k + 4));
      }
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

      gl.enable(gl.DEPTH_TEST);
      gl.depthMask(true);
      gl.disable(gl.BLEND);
      gl.useProgram(box);
      setUniforms(0, vp);
      gl.bindVertexArray(vBox);
      gl.drawElementsInstanced(gl.TRIANGLES, 30, gl.UNSIGNED_BYTE, 0, d.count);

      gl.depthMask(false);
      gl.enable(gl.BLEND);
      gl.blendFuncSeparate(gl.ONE, gl.ONE, gl.ZERO, gl.ONE);
      gl.useProgram(wire);
      setUniforms(2, vp);
      gl.bindVertexArray(vWire);
      gl.drawArrays(gl.LINES, 0, wireVerts);

      gl.disable(gl.DEPTH_TEST);
      if (glowOn) {
        gl.useProgram(glow);
        setUniforms(1, vp);
        gl.uniform1f(kLoc, p[20]);
        gl.bindVertexArray(vGlow);
        gl.drawArrays(gl.POINTS, 0, d.count);
      }
      gl.bindVertexArray(null);
    },
    destroy() {
      for (const b of [bBox, bInst, bIdx, bWire]) gl.deleteBuffer(b);
      for (const v of [vBox, vGlow, vWire]) gl.deleteVertexArray(v);
      for (const p of [box, glow, wire]) gl.deleteProgram(p);
    },
  };
}
