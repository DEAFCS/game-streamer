// The chip renders in headless Chromium inside the render pod, which fetches
// any src it is handed, so only web URLs reach <Img>.
export const renderableAvatarUrl = (url: string | null): string | null => {
  if (!url) {
    return null;
  }
  try {
    const { protocol } = new URL(url);
    return protocol === "https:" || protocol === "http:" ? url : null;
  } catch {
    return null;
  }
};
