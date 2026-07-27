import {
  AbsoluteFill,
  Audio,
  Img,
  interpolate,
  random,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { z } from "zod";
import { BRAND, FONT_STACK } from "./brand";

// TIME_SCALE compresses the whole composition uniformly. To
// change total duration, update DEFAULT_OUTRO_PROPS.durationS,
// match this scale (TIME_SCALE = newDuration / 3.0), and run
// scripts/build-audio.sh to regenerate the audio at matching
// timings. Default: 3.0s Ã· 3.0s = 1.
const TIME_SCALE = 1;

// FLASH_S is the impact beat; keep in sync with IMPACT_S in
// motion/scripts/build-audio.sh.
const FLASH_S = 0.5 * TIME_SCALE;
const PARTICLE_COUNT = 42;

// Shared glyph pool used by the 5STACK and .gg decrypt shimmer â€”
// uppercase letters, digits and tactical-looking symbols.
const GLYPH_POOL =
  "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZâ–£â—ˆâ—†â—‡â–¤â–¥âŠ âŠžâŠŸâŠ¡â€»â€¡â€ â—¢â—£â—¤â—¥â–°â–±";

export const outroSchema = z.object({
  width: z.number().int().positive().default(1920),
  height: z.number().int().positive().default(1080),
  fps: z.number().int().positive().default(60),
  durationS: z.number().positive().default(3),
});

export type OutroProps = z.infer<typeof outroSchema>;

export const DEFAULT_OUTRO_PROPS: OutroProps = {
  width: 1920,
  height: 1080,
  fps: 60,
  durationS: 3,
};

const easeOutCubic = (x: number) => 1 - Math.pow(1 - x, 3);

export const Outro: React.FC<OutroProps> = ({ durationS }) => {
  const frame = useCurrentFrame();
  const { fps, width, height } = useVideoConfig();
  const t = frame / fps;
  const totalFrames = Math.round(durationS * fps);

  const logoSize = Math.round(height * 0.34);
  const titleSize = Math.round(height * 0.115);
  const centerY = height * 0.46;
  const logoY = centerY - logoSize * 0.55;
  const titleY = centerY + logoSize * 0.55;
  // Reference Y for the subtitle line â€” anchors where "THE
  // SYSTEM BEHIND THE GAME" sits beneath the wordmark.
  const subtitleTop = titleY + titleSize * 1.45;
  const yoursTop = subtitleTop + Math.round(titleSize * 0.6);

  const cinematicZoom = 1 + (t / durationS) * 0.04;

  const bgFade = interpolate(t, [0, 0.2 * TIME_SCALE], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const radialPulse =
    0.5 +
    0.5 *
      Math.sin(
        (Math.max(0, t - 1 * TIME_SCALE) * Math.PI) /
          Math.max(0.1, durationS - 1 * TIME_SCALE),
      );

  const bladeSweep = interpolate(
    t,
    [0.15 * TIME_SCALE, FLASH_S],
    [0, 1],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: easeOutCubic },
  );
  const bladeRetract = interpolate(
    t,
    [FLASH_S, FLASH_S + 0.35 * TIME_SCALE],
    [0, 1],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: easeOutCubic },
  );
  const bladeOpacity = interpolate(
    t,
    [
      0.15 * TIME_SCALE,
      0.35 * TIME_SCALE,
      0.75 * TIME_SCALE,
      1.0 * TIME_SCALE,
    ],
    [0, 1, 1, 0],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );
  const bladeY = centerY;
  const bladeH = Math.max(2, Math.round(height * 0.0035));
  const bladeReach = bladeSweep * 0.46 * width * (1 + bladeRetract * 0.4);
  const bladeSplitOffset = bladeRetract * width * 0.18;
  const leftBladeWidth = bladeReach;
  const leftBladeX = width / 2 - bladeReach - bladeSplitOffset;
  const rightBladeWidth = bladeReach;
  const rightBladeX = width / 2 + bladeSplitOffset;

  const flareOpacity = interpolate(
    t,
    [
      FLASH_S - 0.03 * TIME_SCALE,
      FLASH_S + 0.05 * TIME_SCALE,
      FLASH_S + 0.18 * TIME_SCALE,
    ],
    [0, 1, 0],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );

  const flashOpacity = interpolate(
    t,
    [
      FLASH_S - 0.02 * TIME_SCALE,
      FLASH_S + 0.04 * TIME_SCALE,
      FLASH_S + 0.3 * TIME_SCALE,
    ],
    [0, 1, 0],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );
  const flashRadius = interpolate(
    t,
    [FLASH_S, FLASH_S + 0.35 * TIME_SCALE],
    [0, 1],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: easeOutCubic },
  );

  const logoSpring = spring({
    frame: frame - Math.round(fps * (FLASH_S + 0.05 * TIME_SCALE)),
    fps,
    config: { damping: 13, mass: 0.55, stiffness: 110 },
    from: 0,
    to: 1,
  });
  const logoScale = 0.55 + 0.45 * logoSpring;
  const logoOpacity = interpolate(
    t,
    [FLASH_S, FLASH_S + 0.25 * TIME_SCALE],
    [0, 1],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );
  const logoPulse =
    1 +
    0.012 *
      Math.sin(Math.max(0, (t - 1.2 * TIME_SCALE) * Math.PI * 1.5));
  const logoFinalScale = logoScale * logoPulse;

  const wordmarkBreath =
    1 +
    0.008 *
      Math.sin(Math.max(0, (t - 1.5 * TIME_SCALE) * Math.PI * 1.2));
  const rimGlow = Math.max(0.35, flashOpacity);

  // ---- Wordmark decrypt timings --------------------------------
  const STACK_CHARS = ["D", "E", "A", "F", "C", "S"];
  const WORDMARK_START = 0.95 * TIME_SCALE;
  const LETTER_STAGGER = 0.03 * TIME_SCALE;
  const LETTER_DURATION = 0.22 * TIME_SCALE;
  // Letters start cycling earlier than they resolve so the
  // shimmer reads as a decryption process, not a snap-in.
  const DECRYPT_PRE_T = 0.25 * TIME_SCALE;
  const STACK_END_T = WORDMARK_START + STACK_CHARS.length * LETTER_STAGGER;

  // ---- .gg decrypt timings (LONG cycle) ------------------------
  // ".", "g", "g" each cycle independently; the final 'g' is the
  // LOCK moment.
  const ACCENT_START = STACK_END_T + 0.05 * TIME_SCALE;
  const GG_TRIGGER_T = ACCENT_START + 0.28 * TIME_SCALE; // bullet impact
  const GG_RESOLVE_TIMES = [
    GG_TRIGGER_T + 0.22 * TIME_SCALE, // "."
    GG_TRIGGER_T + 0.38 * TIME_SCALE, // first "g"
    GG_TRIGGER_T + 0.54 * TIME_SCALE, // "e"
    GG_TRIGGER_T + 0.70 * TIME_SCALE, // "t" - LOCK
  ];
  const GG_LOCK_T = GG_RESOLVE_TIMES[3];

  const ggSpring = spring({
    frame: frame - Math.round(fps * GG_TRIGGER_T),
    fps,
    config: { damping: 11, mass: 0.45, stiffness: 170 },
    from: 0,
    to: 1,
  });
  const ggOpacity = interpolate(
    t,
    [GG_TRIGGER_T - 0.02 * TIME_SCALE, GG_TRIGGER_T + 0.1 * TIME_SCALE],
    [0, 1],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );
  const bulletFlashOpacity = interpolate(
    t,
    [
      GG_TRIGGER_T - 0.02 * TIME_SCALE,
      GG_TRIGGER_T + 0.03 * TIME_SCALE,
      GG_TRIGGER_T + 0.22 * TIME_SCALE,
    ],
    [0, 1, 0],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );

  const lineFullW = titleSize * 6.4;
  const lineLeftX = (width - lineFullW) / 2;
  // .gg sits roughly 66% along the wordmark width â€” origin for
  // the bullet impact + grenade effects.
  const sparkX = lineLeftX + lineFullW * 0.66;
  const sparkY = titleY + titleSize * 0.5;

  const fadeOut = interpolate(
    frame,
    [totalFrames - Math.round(fps * 0.45 * TIME_SCALE), totalFrames],
    [1, 0],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );

  const particles = Array.from({ length: PARTICLE_COUNT }, (_, i) => {
    const seed = `p-${i}`;
    const px = random(`${seed}-x`) * width;
    const baseY = random(`${seed}-y`) * height;
    const speed = 14 + random(`${seed}-s`) * 24;
    const size = 1 + random(`${seed}-z`) * 2.5;
    const phase = random(`${seed}-p`) * Math.PI * 2;
    const driftX = Math.sin(t * 0.5 + phase) * 14;
    const y = baseY - speed * Math.max(0, t - FLASH_S);
    const wrapY = ((y % height) + height) % height;
    const opacity =
      0.18 +
      0.4 *
        (0.5 + 0.5 * Math.sin(t * 1.4 + phase)) *
        interpolate(
          t,
          [
            0.3 * TIME_SCALE,
            0.9 * TIME_SCALE,
            durationS - 0.5 * TIME_SCALE,
            durationS,
          ],
          [0, 1, 1, 0],
          { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
        );
    return { px, py: wrapY, size, opacity, driftX };
  });

  // ---- Tagline (split across the line) -------------------------
  // "The System Behind the Game" above the line â€” sets context
  // while the wordmark decrypts. "Yours." below the line â€”
  // arrives just after .gg locks as the punctuation.
  const TOP_TAGLINE_T = 1.3 * TIME_SCALE;
  // Slight delay after .gg renders so YOURS feels like a
  // deliberate follow-beat, not a simultaneous flash.
  const BOTTOM_TAGLINE_T = GG_LOCK_T + 0.18 * TIME_SCALE;

  // The "." in "Yours." pulses + glows when YOURS arrives â€”
  // the tagline's own climax beat keyed to BOTTOM_TAGLINE_T.
  const periodPulse = interpolate(
    t,
    [
      BOTTOM_TAGLINE_T - 0.04 * TIME_SCALE,
      BOTTOM_TAGLINE_T + 0.06 * TIME_SCALE,
      BOTTOM_TAGLINE_T + 0.45 * TIME_SCALE,
    ],
    [1, 1.55, 1],
    {
      extrapolateLeft: "clamp",
      extrapolateRight: "clamp",
      easing: easeOutCubic,
    },
  );
  const periodGlow = interpolate(
    t,
    [
      BOTTOM_TAGLINE_T - 0.02 * TIME_SCALE,
      BOTTOM_TAGLINE_T + 0.05 * TIME_SCALE,
      BOTTOM_TAGLINE_T + 0.5 * TIME_SCALE,
    ],
    [0, 1, 0],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );

  const topTaglineO = interpolate(
    t,
    [TOP_TAGLINE_T, TOP_TAGLINE_T + 0.35 * TIME_SCALE],
    [0, 1],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );
  const topTaglineDy = interpolate(
    t,
    [TOP_TAGLINE_T, TOP_TAGLINE_T + 0.4 * TIME_SCALE],
    [10, 0],
    {
      extrapolateLeft: "clamp",
      extrapolateRight: "clamp",
      easing: easeOutCubic,
    },
  );

  const bottomTaglineO = interpolate(
    t,
    [BOTTOM_TAGLINE_T, BOTTOM_TAGLINE_T + 0.22 * TIME_SCALE],
    [0, 1],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );
  const bottomTaglineSpring = spring({
    frame: frame - Math.round(fps * BOTTOM_TAGLINE_T),
    fps,
    config: { damping: 11, mass: 0.4, stiffness: 180 },
    from: 0,
    to: 1,
  });

  return (
    <AbsoluteFill
      style={{
        background: BRAND.surface,
        fontFamily: FONT_STACK,
        opacity: fadeOut,
        overflow: "hidden",
      }}
    >
      <Audio src={staticFile("outro-audio.wav")} />

      <div
        style={{
          position: "absolute",
          inset: 0,
          transform: `scale(${cinematicZoom})`,
          transformOrigin: "center center",
        }}
      >
        {/* Volumetric god-ray cone */}
        <div
          style={{
            position: "absolute",
            left: width / 2 - logoSize * 0.8,
            top: logoY - logoSize * 0.4,
            width: logoSize * 1.6,
            height: logoSize * 1.6,
            background: `conic-gradient(from ${180 + Math.sin(t * 0.5) * 6}deg at 50% 0%, transparent 165deg, hsl(33, 94%, 58%, 0.18) 175deg, hsl(33, 94%, 58%, 0.32) 180deg, hsl(33, 94%, 58%, 0.18) 185deg, transparent 195deg)`,
            opacity: bgFade * 0.85,
            mixBlendMode: "screen",
            filter: "blur(14px)",
            pointerEvents: "none",
          }}
        />

        <div
          style={{
            position: "absolute",
            inset: 0,
            background: `radial-gradient(ellipse 60% 45% at 50% 46%, hsl(33, 94%, 58%, ${0.16 + radialPulse * 0.06}) 0%, transparent 70%)`,
            opacity: bgFade,
            mixBlendMode: "screen",
          }}
        />

        <div
          style={{
            position: "absolute",
            inset: 0,
            opacity: bgFade * 0.35,
            backgroundImage:
              "repeating-linear-gradient(90deg, rgba(255,255,255,0.025) 0 1px, transparent 1px 6px)",
            mixBlendMode: "screen",
          }}
        />

        {particles.map((p, i) => (
          <div
            key={i}
            style={{
              position: "absolute",
              left: p.px + p.driftX,
              top: p.py,
              width: p.size,
              height: p.size,
              borderRadius: "50%",
              background: BRAND.amber,
              opacity: p.opacity,
              boxShadow: `0 0 ${p.size * 4}px ${BRAND.amber}`,
              pointerEvents: "none",
            }}
          />
        ))}

        <div
          style={{
            position: "absolute",
            top: bladeY - bladeH / 2,
            left: leftBladeX,
            width: leftBladeWidth,
            height: bladeH,
            background: `linear-gradient(90deg, transparent 0%, hsl(33, 94%, 58%, 0.35) 35%, ${BRAND.amber} 92%, #fff 100%)`,
            boxShadow: `0 0 18px ${BRAND.amber}, 0 0 4px #fff`,
            opacity: bladeOpacity,
          }}
        />
        <div
          style={{
            position: "absolute",
            top: bladeY - bladeH / 2,
            left: rightBladeX,
            width: rightBladeWidth,
            height: bladeH,
            background: `linear-gradient(90deg, #fff 0%, ${BRAND.amber} 8%, hsl(33, 94%, 58%, 0.35) 65%, transparent 100%)`,
            boxShadow: `0 0 18px ${BRAND.amber}, 0 0 4px #fff`,
            opacity: bladeOpacity,
          }}
        />

        <div
          style={{
            position: "absolute",
            top: bladeY - bladeH,
            left: 0,
            width: "100%",
            height: bladeH * 2,
            background: `linear-gradient(90deg, transparent 0%, rgba(255,255,255,0.95) 50%, transparent 100%)`,
            boxShadow: `0 0 26px rgba(255,255,255,0.6)`,
            opacity: flareOpacity,
            pointerEvents: "none",
            mixBlendMode: "screen",
          }}
        />

        <div
          style={{
            position: "absolute",
            inset: 0,
            opacity: flashOpacity * 0.85,
            background: `radial-gradient(circle at 50% 46%, rgba(255,255,255,${0.95 - flashRadius * 0.6}) 0%, rgba(255,255,255,${0.4 - flashRadius * 0.4}) ${flashRadius * 35}%, transparent ${flashRadius * 70}%)`,
            pointerEvents: "none",
            mixBlendMode: "screen",
          }}
        />

        <div
          style={{
            position: "absolute",
            top: logoY,
            left: (width - logoSize) / 2,
            width: logoSize,
            height: logoSize,
            opacity: logoOpacity,
            transform: `scale(${logoFinalScale})`,
            transformOrigin: "center center",
            filter: `drop-shadow(0 0 ${24 * rimGlow}px hsl(33, 94%, 58%, ${0.55 * rimGlow})) drop-shadow(0 12px 28px rgba(0,0,0,0.6))`,
          }}
        >
          <Img
            src={staticFile("5stack-logo.png")}
            style={{ width: "100%", height: "100%" }}
          />
        </div>

        {/* ============================================================
            WORDMARK â€” "5STACK.gg" with decrypt shimmer
            ============================================================ */}
        <div
          style={{
            position: "absolute",
            top: titleY,
            left: 0,
            width: "100%",
            textAlign: "center",
            fontSize: titleSize,
            fontWeight: 900,
            letterSpacing: "0.08em",
            lineHeight: 1,
            fontFamily: FONT_STACK,
            transform: `scale(${wordmarkBreath})`,
            transformOrigin: "center center",
            textShadow:
              "0 6px 22px rgba(0,0,0,0.7), 0 0 28px hsl(33, 94%, 58%, 0.18)",
          }}
        >
          {STACK_CHARS.map((char, i) => {
            const start = WORDMARK_START + i * LETTER_STAGGER - DECRYPT_PRE_T;
            const resolve = WORDMARK_START + i * LETTER_STAGGER + LETTER_DURATION;
            const cycling = t >= start && t < resolve;
            const resolved = t >= resolve;
            // Inline-block so each char can carry its own
            // opacity/textShadow. Natural width â€” letter-spacing on
            // the parent gives consistent visual gaps between
            // chars regardless of glyph width.
            const cellStyle: React.CSSProperties = {
              display: "inline-block",
            };
            if (!cycling && !resolved) {
              return (
                <span
                  key={i}
                  style={{ ...cellStyle, opacity: 0 }}
                >
                  {char}
                </span>
              );
            }
            let display: string;
            if (cycling) {
              const cycleIdx = Math.floor((t - start) * fps / 2);
              const idx = Math.floor(
                random(`decrypt-${i}-${cycleIdx}`) * GLYPH_POOL.length,
              );
              display = GLYPH_POOL[idx];
            } else {
              display = char;
            }
            const resolveFlash = interpolate(
              t,
              [resolve - 0.01, resolve + 0.02, resolve + 0.22],
              [0, 1, 0],
              { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
            );
            return (
              <span
                key={i}
                style={{
                  ...cellStyle,
                  color: resolved ? BRAND.textPrimary : BRAND.amber,
                  opacity: cycling ? 0.85 : 1,
                  textShadow:
                    resolveFlash > 0.001
                      ? `0 0 ${30 * resolveFlash}px ${BRAND.amber}, 0 0 ${60 * resolveFlash}px hsl(33, 94%, 58%, ${0.7 * resolveFlash})`
                      : cycling
                        ? `0 0 12px hsl(33, 94%, 58%, 0.6)`
                        : undefined,
                }}
              >
                {display}
              </span>
            );
          })}

          {/* .gg â€” bullets in scaled, then each char decrypts in
              sequence. The last 'g' is the LOCK moment. */}
          <span
            style={{
              display: "inline-block",
              opacity: ggOpacity,
              transform: `scale(${0.3 + 0.7 * ggSpring})`,
              transformOrigin: "left center",
            }}
          >
            {[".", "n", "e", "t"].map((char, i) => {
              const resolve = GG_RESOLVE_TIMES[i];
              const cycling = t >= GG_TRIGGER_T && t < resolve;
              const resolved = t >= resolve;
              // Default to the natural char so the layout box is
              // always reserved â€” prevents "5STACK" from snapping
              // leftward when .gg first appears. The parent span's
              // opacity/scale handle the visual entry.
              let display: string = char;
              if (cycling) {
                const cycleIdx = Math.floor((t - GG_TRIGGER_T) * fps / 2);
                const idx = Math.floor(
                  random(`gg-${i}-${cycleIdx}`) * GLYPH_POOL.length,
                );
                display = GLYPH_POOL[idx];
              }
              const isLast = i === GG_RESOLVE_TIMES.length - 1;
              const resolveFlash = interpolate(
                t,
                [resolve - 0.01, resolve + 0.04, resolve + 0.3],
                [0, 1, 0],
                { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
              );
              const flashScale = isLast ? 2.0 : 1.0;
              // Narrower cell for the lowercase ".gg" chars,
              // and centred so the glyph swap doesn't jitter.
              return (
                <span
                  key={i}
                  style={{
                    display: "inline-block",
                    width: i === 0 ? "0.35em" : "0.55em",
                    textAlign: "center",
                    color: BRAND.amber,
                    textShadow:
                      resolveFlash > 0.001
                        ? `0 0 ${36 * resolveFlash * flashScale}px ${BRAND.amber}, 0 0 ${80 * resolveFlash * flashScale}px hsl(33, 94%, 58%, ${0.75 * resolveFlash})`
                        : cycling
                          ? `0 0 18px hsl(33, 94%, 58%, 0.7), 0 0 36px hsl(33, 94%, 58%, 0.35)`
                          : `0 0 28px hsl(33, 94%, 58%, ${0.55 + 0.45 * bulletFlashOpacity}), 0 0 12px hsl(33, 94%, 58%, ${0.4 + 0.6 * bulletFlashOpacity})`,
                  }}
                >
                  {display}
                </span>
              );
            })}
          </span>
        </div>

        {/* Bullet impact glow at GG_TRIGGER_T */}
        {bulletFlashOpacity > 0.001 && (
          <div
            style={{
              position: "absolute",
              top: sparkY - titleSize * 0.5,
              left: sparkX - titleSize * 0.5,
              width: titleSize,
              height: titleSize,
              background: `radial-gradient(circle, rgba(255,255,255,0.9) 0%, hsl(33, 94%, 58%, 0.55) 30%, transparent 65%)`,
              opacity: bulletFlashOpacity,
              mixBlendMode: "screen",
              pointerEvents: "none",
              filter: `blur(${titleSize * 0.04}px)`,
            }}
          />
        )}


      </div>
      {/* /stage */}

    </AbsoluteFill>
  );
};





