import { Config } from "@remotion/cli/config";

Config.setConcurrency(1);
// The font's delayRender handle is armed when the bundle loads and its clock
// runs for the whole render, so the budget must exceed the slowest render:
// the image build and the niced/pinned per-clip chip render both blow past 30s.
Config.setDelayRenderTimeoutInMilliseconds(300000);
Config.setVideoImageFormat("jpeg");
Config.setOverwriteOutput(true);
