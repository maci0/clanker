#!/usr/bin/env python3
"""OpenCV image analysis for the clanker `opencv` WASM tool.

The WASM guest cannot link OpenCV, so the tool shells out to this script and
uv supplies cv2 in an ephemeral environment (nothing is installed on the host).

Usage:  opencv_tool.py <op> <image-path> [json-options]
Ops:    info | edges | faces | resize | grayscale | contours
Prints one JSON object on stdout. Failures print {"ok": false, "error": ...}
and exit non-zero.
"""

import json
import os
import sys

import cv2
import numpy as np

# Written files land here so a tool run cannot scatter images across the repo.
OUT_DIR = "state/opencv"


def _load(path):
    if not os.path.isfile(path):
        raise ValueError(f"no such file: {path}")
    image = cv2.imread(path, cv2.IMREAD_UNCHANGED)
    if image is None:
        raise ValueError(f"not a readable image: {path}")
    return image


def _write(image, stem, suffix):
    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, f"{stem}-{suffix}.png")
    if not cv2.imwrite(out, image):
        raise ValueError(f"could not write {out}")
    return out


def _stem(path):
    return os.path.splitext(os.path.basename(path))[0]


def op_info(image, _path, _opts):
    h, w = image.shape[:2]
    channels = 1 if image.ndim == 2 else image.shape[2]
    gray = image if image.ndim == 2 else cv2.cvtColor(image[:, :, :3], cv2.COLOR_BGR2GRAY)
    return {
        "width": w,
        "height": h,
        "channels": channels,
        "dtype": str(image.dtype),
        "mean_brightness": round(float(np.mean(gray)), 2),
        "std_brightness": round(float(np.std(gray)), 2),
        # A near-zero Laplacian variance is the standard blur signal.
        "sharpness": round(float(cv2.Laplacian(gray, cv2.CV_64F).var()), 2),
    }


def op_grayscale(image, path, _opts):
    gray = image if image.ndim == 2 else cv2.cvtColor(image[:, :, :3], cv2.COLOR_BGR2GRAY)
    return {"output": _write(gray, _stem(path), "gray")}


def op_edges(image, path, opts):
    lo = int(opts.get("threshold1", 100))
    hi = int(opts.get("threshold2", 200))
    gray = image if image.ndim == 2 else cv2.cvtColor(image[:, :, :3], cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(gray, lo, hi)
    return {
        "output": _write(edges, _stem(path), "edges"),
        "edge_pixels": int(np.count_nonzero(edges)),
        "threshold1": lo,
        "threshold2": hi,
    }


def op_contours(image, path, opts):
    min_area = float(opts.get("min_area", 100))
    gray = image if image.ndim == 2 else cv2.cvtColor(image[:, :, :3], cv2.COLOR_BGR2GRAY)
    _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    found, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    boxes = []
    for c in found:
        area = cv2.contourArea(c)
        if area < min_area:
            continue
        x, y, w, h = cv2.boundingRect(c)
        boxes.append({"x": int(x), "y": int(y), "w": int(w), "h": int(h), "area": round(float(area), 1)})
    boxes.sort(key=lambda b: b["area"], reverse=True)
    return {"count": len(boxes), "contours": boxes[:50], "min_area": min_area}


def op_faces(image, path, _opts):
    cascade_path = os.path.join(cv2.data.haarcascades, "haarcascade_frontalface_default.xml")
    cascade = cv2.CascadeClassifier(cascade_path)
    if cascade.empty():
        raise ValueError("face cascade unavailable in this OpenCV build")
    gray = image if image.ndim == 2 else cv2.cvtColor(image[:, :, :3], cv2.COLOR_BGR2GRAY)
    faces = cascade.detectMultiScale(gray, scaleFactor=1.1, minNeighbors=5)
    boxes = [{"x": int(x), "y": int(y), "w": int(w), "h": int(h)} for (x, y, w, h) in faces]
    return {"count": len(boxes), "faces": boxes}


def op_resize(image, path, opts):
    h, w = image.shape[:2]
    width = opts.get("width")
    height = opts.get("height")
    if width is None and height is None:
        raise ValueError("resize needs width or height")
    if width is None:
        width = max(1, round(w * (int(height) / h)))
    if height is None:
        height = max(1, round(h * (int(width) / w)))
    resized = cv2.resize(image, (int(width), int(height)), interpolation=cv2.INTER_AREA)
    return {"output": _write(resized, _stem(path), f"{int(width)}x{int(height)}"), "width": int(width), "height": int(height)}


OPS = {
    "info": op_info,
    "grayscale": op_grayscale,
    "edges": op_edges,
    "contours": op_contours,
    "faces": op_faces,
    "resize": op_resize,
}


def main(argv):
    if len(argv) < 3:
        raise ValueError(f"usage: opencv_tool.py <{'|'.join(OPS)}> <image> [json-options]")
    op, path = argv[1], argv[2]
    opts = json.loads(argv[3]) if len(argv) > 3 and argv[3] else {}
    if op not in OPS:
        raise ValueError(f"unknown op '{op}'; expected one of {', '.join(OPS)}")
    result = OPS[op](_load(path), path, opts)
    result["ok"] = True
    result["op"] = op
    return result


if __name__ == "__main__":
    try:
        print(json.dumps(main(sys.argv)))
    except Exception as err:  # surfaced to the agent as the tool's error
        print(json.dumps({"ok": False, "error": str(err)}))
        sys.exit(1)
