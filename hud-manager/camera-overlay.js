// Injected into the JTs Hud Manager overlay window by auto-overlay.patch.
//
// Kept as a self-contained IIFE appended to document.body rather than a change
// to the HUD's own markup: the HUD is upstream and its DOM is not ours to
// restructure, so this only ever adds one element of its own.
//
// The spectated player comes from the spec-server, which already tracks it from
// GSI, so the camera always follows what viewers are actually watching. The
// SDP exchange is proxied by that same server because it holds the pod's match
// credentials and this page must not.
//
// The feed takes over the spectated player's avatar rather than floating in a
// corner. JTs Hud's own camera pipeline is not reusable here -- it renders from
// simple-peer connections held in the hud-manager process, keyed off players who
// joined through its camera hub -- so we mount into the slot its markup already
// provides and hide the avatar image behind it.
(() => {
  // Injection is wired to did-finish-load, which fires again on any in-page
  // reload -- without this a second poll loop, observer and peer connection
  // stack on top of the first.
  if (window.__FIVESTACK_CAMERA_DISPOSE__) {
    window.__FIVESTACK_CAMERA_DISPOSE__();
  }

  const SPEC_BASE = window.__FIVESTACK_SPEC_BASE__ || "http://127.0.0.1:1350";
  const POLL_MS = 2000;
  // A player with no camera fails every attempt; back off rather than
  // renegotiating a doomed peer connection every couple of seconds.
  const RETRY_BACKOFF_MS = 15000;
  // The spec-server's answer when the director cut away mid-negotiation. The
  // camera is fine, so the next poll follows the director instead.
  const NOT_SPECTATED = 409;
  // The 140x140 box the HUD floats above the spectated player's bar. Present in
  // both hud variants -- `.observed` is not scoped to `.layout-*`.
  const AVATAR_SELECTOR = ".observed .avatar_container .avatar";

  const video = document.createElement("video");
  video.autoplay = true;
  video.muted = true;
  video.playsInline = true;
  video.id = "fivestack-camera";

  // The hud's avatar box is a 140px square while a webcam is 16:9, so filling it
  // exactly crops away most of the shot. Overflowing the box horizontally keeps
  // the same height but shows noticeably more of the frame -- `.observed` is
  // 380px wide and sets overflow:visible, so nothing clips it.
  const AVATAR_WIDTH_PX = 200;

  const AVATAR_STYLE = {
    position: "absolute",
    inset: "auto",
    top: "0",
    left: "50%",
    transform: `translateX(-50%)`,
    width: `${AVATAR_WIDTH_PX}px`,
    height: "100%",
    borderRadius: "4px",
    border: "none",
    boxShadow: "0 4px 15px rgba(0,0,0,0.5)",
    background: "#000",
    zIndex: "9",
    opacity: "0",
    transition: "opacity 220ms ease",
    pointerEvents: "none",
    objectFit: "cover",
  };

  // Only reached on a hud whose markup has no observed-player avatar. Keeping a
  // corner box means the feature degrades rather than silently disappearing.
  const CORNER_STYLE = {
    position: "fixed",
    inset: "auto",
    right: "24px",
    bottom: "96px",
    width: "260px",
    height: "auto",
    borderRadius: "6px",
    border: "2px solid rgba(0,0,0,0.55)",
    boxShadow: "0 8px 28px rgba(0,0,0,0.55)",
    background: "#000",
    zIndex: "2147483000",
    opacity: "0",
    transition: "opacity 220ms ease",
    pointerEvents: "none",
    objectFit: "cover",
  };

  let currentSteamId = null;
  let pc = null;
  const failedUntil = new Map();

  let mode = null;
  let visible = false;
  let hiddenImage = null;

  function restoreAvatarImage() {
    if (hiddenImage) {
      hiddenImage.style.removeProperty("visibility");
      hiddenImage = null;
    }
  }

  // React owns this subtree and rebuilds it whenever the spectated player
  // changes, which both drops our video and restores the avatar it replaced --
  // so re-attaching is a steady-state operation, not just a startup one.
  function attach() {
    const anchor = document.querySelector(AVATAR_SELECTOR);
    const parent = anchor ?? document.body;
    const nextMode = anchor ? "avatar" : "corner";

    if (video.parentElement !== parent) {
      parent.appendChild(video);
    }

    if (mode !== nextMode) {
      mode = nextMode;
      video.removeAttribute("style");
      Object.assign(video.style, nextMode === "avatar" ? AVATAR_STYLE : CORNER_STYLE);
      video.style.opacity = visible ? "1" : "0";
    }

    const image = anchor?.querySelector("img") ?? null;

    if (visible && anchor && image) {
      if (hiddenImage !== image) {
        restoreAvatarImage();
        hiddenImage = image;
      }
      image.style.visibility = "hidden";
      return;
    }

    restoreAvatarImage();
  }

  let attachQueued = false;
  const observer = new MutationObserver(() => {
    if (attachQueued) {
      return;
    }
    attachQueued = true;
    requestAnimationFrame(() => {
      attachQueued = false;
      attach();
    });
  });
  observer.observe(document.body, { childList: true, subtree: true });

  attach();

  const show = (next) => {
    visible = next;
    video.style.opacity = next ? "1" : "0";
    attach();
  };

  function teardown() {
    show(false);

    if (pc) {
      pc.close();
      pc = null;
    }

    video.srcObject = null;
    currentSteamId = null;
  }

  async function connect(steamId) {
    const peer = new RTCPeerConnection({
      iceServers: [{ urls: "stun:stun.l.google.com:19302" }],
    });
    pc = peer;
    currentSteamId = steamId;

    peer.addTransceiver("video", { direction: "recvonly" });
    peer.ontrack = (event) => {
      video.srcObject = event.streams[0];
      void video.play().catch(() => {});
      // Only reveal once a track actually arrives, so a negotiated-but-silent
      // path never shows as a black box over the broadcast.
      show(true);
    };

    peer.addEventListener("connectionstatechange", () => {
      if (["failed", "disconnected", "closed"].includes(peer.connectionState)) {
        if (pc === peer) {
          teardown();
        }
      }
    });

    const offer = await peer.createOffer();
    await peer.setLocalDescription(offer);

    await new Promise((resolve) => {
      if (peer.iceGatheringState === "complete") {
        resolve();
        return;
      }
      peer.addEventListener("icegatheringstatechange", () => {
        if (peer.iceGatheringState === "complete") resolve();
      });
      setTimeout(resolve, 1500);
    });

    const response = await fetch(`${SPEC_BASE}/camera/${steamId}/whep`, {
      method: "POST",
      headers: { "Content-Type": "application/sdp" },
      body: peer.localDescription?.sdp ?? "",
    });

    if (!response.ok) {
      const error = new Error(String(response.status));
      error.status = response.status;
      throw error;
    }

    await peer.setRemoteDescription({
      type: "answer",
      sdp: await response.text(),
    });
  }

  async function tick() {
    try {
      const response = await fetch(`${SPEC_BASE}/camera/state`);
      const state = response.ok ? await response.json() : null;
      const steamId = state?.enabled ? state.steam_id : null;

      if (!steamId) {
        if (currentSteamId) teardown();
        return;
      }

      if (steamId === currentSteamId) {
        return;
      }

      const backoff = failedUntil.get(steamId) ?? 0;
      if (Date.now() < backoff) {
        return;
      }

      teardown();

      try {
        await connect(steamId);
        failedUntil.delete(steamId);
      } catch (error) {
        if (error?.status !== NOT_SPECTATED) {
          failedUntil.set(steamId, Date.now() + RETRY_BACKOFF_MS);
        }
        teardown();
      }
    } catch {
      // spec-server not up yet, or mid-restart. Try again next tick.
    }
  }

  const timer = setInterval(tick, POLL_MS);
  void tick();

  window.__FIVESTACK_CAMERA_DISPOSE__ = () => {
    clearInterval(timer);
    observer.disconnect();
    teardown();
    video.remove();
  };
})();
