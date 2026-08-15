// Vanilla, no bundler. Image/video attachment plumbing for the composer.
export var pendingImages = [];
export var max_image_bytes = 4 * 1024 * 1024;
export var max_images = 4;

// Video input (Kimi Code parity: "drop a screen recording into the chat").
// The run's image path is the channel — a video is sampled to up to
// `max_video_frames` JPEG frames, evenly spaced, each well under the
// per-image cap, and rides the same pendingImages list the server already
// accepts. Nothing server-side changes.
export var max_video_frames = 4;
export var max_video_bytes = 256 * 1024 * 1024;
export var video_frame_width = 640;

export function clearAttachments() { pendingImages.length = 0; }

export function renderAttachments(els, iconFn, fmtBytesFn) {
  els.attachments.textContent = "";
  els.attachments.hidden = pendingImages.length === 0;
  pendingImages.forEach(function (img, i) {
    var wrap = document.createElement("div");
    wrap.className = "attachment";
    var thumb = document.createElement("img");
    thumb.src = "data:" + img.mime + ";base64," + img.b64;
    thumb.alt = "Attached image " + (i + 1) + ", " + fmtBytesFn(img.bytes);
    wrap.appendChild(thumb);
    var rm = document.createElement("button");
    rm.type = "button";
    rm.appendChild(iconFn("strike", 14));
    rm.setAttribute("aria-label", "Remove attached image " + (i + 1));
    rm.addEventListener("click", function () {
      pendingImages.splice(i, 1);
      renderAttachments(els, iconFn, fmtBytesFn);
    });
    wrap.appendChild(rm);
    els.attachments.appendChild(wrap);
  });
  if (typeof els.onAttachmentsChange === "function") els.onAttachmentsChange();
}

export function addImageFile(file, els, iconFn, fmtBytesFn) {
  if (!file) return;
  if (pendingImages.length >= max_images) {
    els.sessionStatus.textContent = "At most " + max_images + " images can be attached to one message.";
    return;
  }
  if (file.type.indexOf("image/") !== 0) {
    els.sessionStatus.textContent = "Only images can be attached; " + (file.type || "that file") + " was ignored.";
    return;
  }
  var reader = new FileReader();
  reader.onload = function () {
    var comma = String(reader.result).indexOf(",");
    if (comma === -1) return;
    var b64 = String(reader.result).slice(comma + 1);
    var bytes = Math.floor(b64.length * 3 / 4);
    if (bytes > max_image_bytes) {
      els.sessionStatus.textContent = "That image is " + fmtBytesFn(bytes) + "; the limit is " + fmtBytesFn(max_image_bytes) + ".";
      return;
    }
    // Checked again here, not only on the way in. A drop or a paste hands
    // over every file at once, so N synchronous calls all read a length of 0
    // before any FileReader has finished and all N pass the check above; six
    // dropped images became six attachments, and the server then refused the
    // whole run with "at most 4 images may be attached". This is the same
    // push-time test the video sampler already makes for its frames.
    if (pendingImages.length >= max_images) {
      els.sessionStatus.textContent = "At most " + max_images + " images can be attached to one message.";
      return;
    }
    pendingImages.push({ mime: file.type, b64: b64, bytes: bytes });
    renderAttachments(els, iconFn, fmtBytesFn);
  };
  reader.readAsDataURL(file);
}

/// Routes a dropped or pasted file to the right sampler: images ride through
/// untouched, videos are sampled to JPEG frames, anything else is refused.
export function addMediaFile(file, els, iconFn, fmtBytesFn) {
  if (!file) return false;
  if (file.type.indexOf("image/") === 0) {
    addImageFile(file, els, iconFn, fmtBytesFn);
    return true;
  }
  if (file.type.indexOf("video/") === 0) return addVideoFile(file, els, iconFn, fmtBytesFn);
  els.sessionStatus.textContent = "Only images and videos can be attached; " + (file.type || "that file") + " was ignored.";
  return false;
}

/// Sampled a video to `max_video_frames` evenly spaced JPEG frames (one per
/// second up to the cap, `max_images` total with anything already attached).
/// Frames are drawn to a canvas at most `video_frame_width` wide and encoded
/// at jpeg 0.72 — a screen recording's frames land at tens of KB, far under
/// the 4 MB per-image cap, so four frames fit comfortably.
export function addVideoFile(file, els, iconFn, fmtBytesFn) {
  if (!file) return false;
  if (file.type.indexOf("video/") !== 0) return false;
  if (file.size > max_video_bytes) {
    els.sessionStatus.textContent = "That video is " + fmtBytesFn(file.size) + "; the limit is " + fmtBytesFn(max_video_bytes) + ".";
    return true;
  }
  var url = URL.createObjectURL(file);
  var video = document.createElement("video");
  video.muted = true;
  video.playsInline = true;
  video.preload = "auto";
  video.src = url;
  var done = false;
  function cleanup() {
    if (done) return;
    done = true;
    try { URL.revokeObjectURL(url); } catch (_) {}
    video.removeAttribute("src");
  }
  video.onerror = function () {
    cleanup();
    els.sessionStatus.textContent = "Could not read that video file.";
  };
  video.onloadedmetadata = function () {
    var duration = video.duration;
    if (!isFinite(duration) || duration <= 0) {
      cleanup();
      els.sessionStatus.textContent = "Could not read that video's duration.";
      return;
    }
    var want = Math.min(max_video_frames, Math.max(1, Math.ceil(duration)));
    var times = [];
    for (var i = 0; i < want; i++) times.push((i + 0.5) * duration / want);
    var canvas = document.createElement("canvas");
    var ctx = canvas.getContext("2d");
    var idx = 0;
    var pushed = 0;
    function grab() {
      if (idx >= times.length) {
        cleanup();
        renderAttachments(els, iconFn, fmtBytesFn);
        if (els.sessionStatus) {
          els.sessionStatus.textContent = pushed > 0
            ? "video sampled to " + pushed + (pushed === 1 ? " frame." : " frames.")
            : "No frames could be read from that video.";
        }
        return;
      }
      video.onseeked = function () {
        try {
          var w = video.videoWidth || 0;
          var h = video.videoHeight || 0;
          if (w > 0 && h > 0) {
            var scale = Math.min(1, video_frame_width / w);
            canvas.width = Math.max(1, Math.round(w * scale));
            canvas.height = Math.max(1, Math.round(h * scale));
            ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
            var dataUrl = canvas.toDataURL("image/jpeg", 0.72);
            var comma = dataUrl.indexOf(",");
            if (comma !== -1) {
              var b64 = dataUrl.slice(comma + 1);
              var bytes = Math.floor(b64.length * 3 / 4);
              if (bytes <= max_image_bytes && pendingImages.length < max_images) {
                pendingImages.push({ mime: "image/jpeg", b64: b64, bytes: bytes });
                pushed += 1;
              }
            }
          }
        } catch (_) {}
        idx += 1;
        grab();
      };
      video.currentTime = times[idx];
    }
    grab();
  };
  return true;
}
