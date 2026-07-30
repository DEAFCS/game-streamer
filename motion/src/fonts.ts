import {
  cancelRender,
  continueRender,
  delayRender,
  staticFile,
} from "remotion";

// Oxanium — the 5stack brand font, copied from web/public/fonts.
// Variable weight 100-700, used across the web app via
// tailwind.config.js → fontFamily.sans.
const handle = delayRender("Loading Oxanium", { retries: 2 });

const font = new FontFace(
  "Oxanium",
  `url(${staticFile("fonts/Oxanium-VariableFont_wght.ttf")}) format("truetype")`,
  { weight: "100 700", style: "normal", display: "swap" },
);

font
  .load()
  .then((loaded) => {
    // TS DOM lib in this project doesn't surface FontFaceSet.add.
    (document.fonts as unknown as { add: (f: FontFace) => void }).add(loaded);
    continueRender(handle);
  })
  .catch((err) => {
    cancelRender(err);
  });
