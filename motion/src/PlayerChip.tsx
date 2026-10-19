import {
  AbsoluteFill,
  Img,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { z } from "zod";
import { renderableAvatarUrl } from "./avatar-url";
import { BRAND, FONT_STACK } from "./brand";

const CrosshairIcon: React.FC<{ size: number; color: string }> = ({
  size,
  color,
}) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    stroke={color}
    strokeWidth={2.5}
    strokeLinecap="round"
    strokeLinejoin="round"
    style={{ flexShrink: 0 }}
  >
    <circle cx="12" cy="12" r="10" />
    <line x1="22" y1="12" x2="18" y2="12" />
    <line x1="6" y1="12" x2="2" y2="12" />
    <line x1="12" y1="6" x2="12" y2="2" />
    <line x1="12" y1="22" x2="12" y2="18" />
  </svg>
);

export const CHIP_DURATION_S = 3.5;

export const playerChipSchema = z.object({
  name: z.string().default("Player"),
  kills: z.number().int().nonnegative().default(0),
  map: z.string().nullable().default(null),
  round: z.number().int().nonnegative().nullable().default(null),
  avatarUrl: z.string().nullable().default(null),
  width: z.number().int().positive().default(1920),
  height: z.number().int().positive().default(1080),
  fps: z.number().int().positive().default(60),
});

export type PlayerChipProps = z.infer<typeof playerChipSchema>;

export const DEFAULT_CHIP_PROPS: PlayerChipProps = {
  name: "rawr",
  kills: 3,
  map: "DE_INFERNO",
  round: 4,
  avatarUrl: null,
  width: 1920,
  height: 1080,
  fps: 60,
};

export const PlayerChip: React.FC<PlayerChipProps> = ({
  name,
  kills,
  map,
  round,
  avatarUrl,
}) => {
  const frame = useCurrentFrame();
  const { fps, width, height } = useVideoConfig();
  const t = frame / fps;
  const total = CHIP_DURATION_S;

  // ~25% smaller than v1; tuned for visibility without crowding the
  // game footage. All sizes scale off frame height so 720p clips get
  // a proportional chip.
  const padX = Math.round(width * 0.015 + 12);
  const padY = Math.round(height * 0.026 + 10);
  const avSize = Math.round(height * 0.065 + 20);
  const nameSize = Math.round(height * 0.024 + 8);
  const metaSize = Math.round(height * 0.014 + 5);
  const killH = Math.round(height * 0.024 + 10);
  const killFontSize = Math.round(killH * 0.6);
  const killPadX = Math.round(killH * 0.45);

  const inSpring = spring({
    frame,
    fps,
    config: { damping: 16, mass: 0.7, stiffness: 110 },
    from: 0,
    to: 1,
  });
  const slideY = (1 - inSpring) * 16;

  const opacity = interpolate(
    t,
    [0.0, 0.5, 2.6, total],
    [0, 1, 1, 0],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );

  const initial = (name?.[0] ?? "H").toUpperCase();
  const avatarSrc = renderableAvatarUrl(avatarUrl);

  return (
    <AbsoluteFill
      style={{
        background: "transparent",
        fontFamily: FONT_STACK,
        opacity,
        transform: `translateY(${slideY}px)`,
      }}
    >
      <div
        style={{
          position: "absolute",
          bottom: padY,
          left: padX,
          display: "flex",
          alignItems: "center",
          gap: Math.round(avSize * 0.22),
        }}
      >
        <div
          style={{
            width: avSize,
            height: avSize,
            borderRadius: Math.round(avSize * 0.12),
            border: `3px solid ${BRAND.amberBorder}`,
            background: BRAND.amberDim,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            overflow: "hidden",
            boxShadow: "0 6px 18px rgba(0,0,0,0.45)",
          }}
        >
          {avatarSrc ? (
            <Img
              src={avatarSrc}
              style={{ width: "100%", height: "100%", objectFit: "cover" }}
            />
          ) : (
            <span
              style={{
                fontSize: Math.round(avSize * 0.55),
                fontWeight: 900,
                color: BRAND.amber,
                lineHeight: 1,
              }}
            >
              {initial}
            </span>
          )}
        </div>

        <div
          style={{
            display: "flex",
            flexDirection: "column",
            gap: Math.round(metaSize * 0.35),
          }}
        >
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: Math.round(killH * 0.45),
            }}
          >
            <span
              style={{
                fontSize: nameSize,
                fontWeight: 800,
                color: BRAND.textPrimary,
                textShadow: "0 2px 6px rgba(0,0,0,0.7)",
                letterSpacing: "0.01em",
                whiteSpace: "nowrap",
                maxWidth: width * 0.4,
                overflow: "hidden",
                textOverflow: "ellipsis",
              }}
            >
              {name}
            </span>
            {kills > 0 && (
              <span
                style={{
                  display: "inline-flex",
                  alignItems: "center",
                  gap: Math.round(killH * 0.22),
                  height: killH,
                  paddingLeft: Math.round(killPadX * 0.85),
                  paddingRight: killPadX,
                  borderRadius: Math.round(killH * 0.25),
                  background: BRAND.destructive,
                  color: BRAND.textPrimary,
                  fontSize: killFontSize,
                  fontWeight: 900,
                  fontFamily: FONT_STACK,
                  letterSpacing: "0.02em",
                  boxShadow: "0 0 12px rgba(220, 38, 38, 0.45)",
                }}
              >
                <CrosshairIcon
                  size={Math.round(killFontSize * 1.1)}
                  color={BRAND.textPrimary}
                />
                {kills}K
              </span>
            )}
          </div>

          {(map || round != null) && (
            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: Math.round(metaSize * 0.55),
                fontFamily: FONT_STACK,
                fontSize: metaSize,
                fontWeight: 700,
                color: "rgba(255,255,255,0.55)",
                letterSpacing: "0.22em",
                textTransform: "uppercase",
                whiteSpace: "nowrap",
              }}
            >
              {map && <span>{map}</span>}
              {map && round != null && <span>·</span>}
              {round != null && <span>R{round}</span>}
            </div>
          )}
        </div>
      </div>
    </AbsoluteFill>
  );
};
