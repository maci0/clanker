// Vanilla, no bundler. Image attachment plumbing for the composer.
export var pendingImages = [];
export var max_image_bytes = 4 * 1024 * 1024;
export var max_images = 4;

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
      els.hint.textContent = "";
    });
    wrap.appendChild(rm);
    els.attachments.appendChild(wrap);
  });
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
    pendingImages.push({ mime: file.type, b64: b64, bytes: bytes });
    renderAttachments(els, iconFn, fmtBytesFn);
    els.hint.textContent = pendingImages.length + (pendingImages.length === 1 ? " image attached." : " images attached.");
  };
  reader.readAsDataURL(file);
}
