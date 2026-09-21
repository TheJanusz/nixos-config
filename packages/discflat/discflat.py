#!/usr/bin/env python3
"""Detect a disc in a photo, rectify it to a circle, write a square RGBA PNG."""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import cv2
import numpy as np

DETECT_MAX_SIDE = 1400
MIN_AXIS_FRAC = 0.25
MAX_ASPECT = 2.6
HOLE_RATIO_RANGE = (0.07, 0.42)
N_SAMPLE = 32
OUT_SIZE_MIN = 256
OUT_SIZE_MAX = 4096


def read_bgr(path: Path) -> np.ndarray | None:
    buf = np.frombuffer(path.read_bytes(), dtype=np.uint8)
    img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    return img


def write_png(path: Path, bgra: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    ok, encoded = cv2.imencode(".png", bgra)
    if not ok:
        raise RuntimeError(f"failed to encode PNG: {path}")
    path.write_bytes(encoded.tobytes())


def ellipse_axes(ell: tuple) -> tuple[float, float]:
    (_cx, _cy), (w, h), _ang = ell
    return float(max(w, h)), float(min(w, h))


def scale_ellipse(ell: tuple, s: float) -> tuple:
    (cx, cy), (w, h), ang = ell
    return ((cx * s, cy * s), (w * s, h * s), ang)


def sample_ellipse(ell: tuple, n: int = N_SAMPLE) -> np.ndarray:
    (cx, cy), (w, h), ang = ell
    phi = math.radians(ang)
    t = np.linspace(0.0, 2.0 * math.pi, n, endpoint=False)
    x = (w / 2.0) * np.cos(t)
    y = (h / 2.0) * np.sin(t)
    c, s = math.cos(phi), math.sin(phi)
    xr = x * c - y * s + cx
    yr = x * s + y * c + cy
    return np.column_stack([xr, yr]).astype(np.float32)


def sample_circle(cx: float, cy: float, r: float, n: int = N_SAMPLE) -> np.ndarray:
    t = np.linspace(0.0, 2.0 * math.pi, n, endpoint=False)
    return np.column_stack([cx + r * np.cos(t), cy + r * np.sin(t)]).astype(np.float32)


def ellipse_inside_frame(ell: tuple, shape: tuple[int, ...]) -> bool:
    h, w = shape[:2]
    pts = sample_ellipse(ell, 48)
    outside = (
        (pts[:, 0] < 0)
        | (pts[:, 1] < 0)
        | (pts[:, 0] > w - 1)
        | (pts[:, 1] > h - 1)
    )
    if int(np.count_nonzero(outside)) > 4:
        return False
    touches = (
        int(np.any(pts[:, 0] < 6))
        + int(np.any(pts[:, 0] > w - 7))
        + int(np.any(pts[:, 1] < 6))
        + int(np.any(pts[:, 1] > h - 7))
    )
    return touches < 4


def score_ellipse(contour: np.ndarray, ell: tuple, shape: tuple[int, ...]) -> float:
    major, minor = ellipse_axes(ell)
    if minor < 8 or major < 16:
        return 0.0
    aspect = major / minor
    if aspect > MAX_ASPECT:
        return 0.0
    min_dim = float(min(shape[0], shape[1]))
    if major < MIN_AXIS_FRAC * min_dim:
        return 0.0
    if not ellipse_inside_frame(ell, shape):
        return 0.0
    area = cv2.contourArea(contour)
    peri = cv2.arcLength(contour, True)
    if peri < 1.0 or area < 1.0:
        return 0.0
    circ = 4.0 * math.pi * area / (peri * peri)
    ell_area = math.pi * (major / 2.0) * (minor / 2.0)
    fit = min(area, ell_area) / max(area, ell_area)
    return float(area * circ * fit / aspect)


def fit_scored(contour: np.ndarray, shape: tuple[int, ...]) -> tuple[tuple, float] | None:
    if len(contour) < 20:
        return None
    try:
        ell = cv2.fitEllipse(contour)
    except cv2.error:
        return None
    sc = score_ellipse(contour, ell, shape)
    if sc <= 0:
        return None
    return ell, sc


def similar_ellipses(a: tuple, b: tuple, tol: float = 0.08) -> bool:
    (ax, ay), (aw, ah), _ = a
    (bx, by), (bw, bh), _ = b
    maj = max(aw, ah, bw, bh)
    if maj < 1:
        return True
    if math.hypot(ax - bx, ay - by) > tol * maj:
        return False
    return abs(max(aw, ah) - max(bw, bh)) <= tol * maj


def add_candidate(cands: list[tuple[tuple, float]], ell: tuple, score: float) -> None:
    for i, (other, other_s) in enumerate(cands):
        if similar_ellipses(ell, other):
            if score > other_s:
                cands[i] = (ell, score)
            return
    cands.append((ell, score))


def contours_from_edges(edges: np.ndarray) -> list[np.ndarray]:
    edges = cv2.dilate(edges, np.ones((3, 3), np.uint8), iterations=1)
    contours, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE)
    return list(contours)


def collect_candidates(gray: np.ndarray) -> list[tuple[tuple, float]]:
    shape = gray.shape
    blurred = cv2.GaussianBlur(gray, (7, 7), 0)
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    eq = clahe.apply(blurred)
    cands: list[tuple[tuple, float]] = []

    for src in (blurred, eq):
        for low, high in ((30, 90), (50, 150), (80, 200)):
            edges = cv2.Canny(src, low, high)
            for contour in contours_from_edges(edges):
                fitted = fit_scored(contour, shape)
                if fitted:
                    add_candidate(cands, fitted[0], fitted[1])

        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
        grad = cv2.morphologyEx(src, cv2.MORPH_GRADIENT, kernel)
        _thr, binary = cv2.threshold(grad, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        for contour in contours_from_edges(binary):
            fitted = fit_scored(contour, shape)
            if fitted:
                add_candidate(cands, fitted[0], fitted[1])

    min_dim = min(shape[0], shape[1])
    circles = cv2.HoughCircles(
        eq,
        cv2.HOUGH_GRADIENT,
        dp=1.2,
        minDist=min_dim / 5.0,
        param1=120,
        param2=40,
        minRadius=int(min_dim * MIN_AXIS_FRAC / 2.0),
        maxRadius=int(min_dim * 0.49),
    )
    if circles is not None:
        for x, y, r in circles[0]:
            ell = ((float(x), float(y)), (float(2 * r), float(2 * r)), 0.0)
            if ellipse_inside_frame(ell, shape) and 2 * r >= MIN_AXIS_FRAC * min_dim:
                add_candidate(cands, ell, math.pi * r * r * 0.5)

    return cands


def pick_outer(cands: list[tuple[tuple, float]]) -> tuple | None:
    if not cands:
        return None
    return max(cands, key=lambda item: item[1] * ellipse_axes(item[0])[0])[0]


def hole_from_candidates(cands: list[tuple[tuple, float]], outer: tuple) -> tuple | None:
    (ocx, ocy), (ow, oh), _ = outer
    outer_maj = max(ow, oh)
    best = None
    best_s = 0.0
    for ell, score in cands:
        if similar_ellipses(ell, outer, tol=0.2):
            continue
        (cx, cy), (w, h), _ = ell
        maj = max(w, h)
        ratio = maj / outer_maj
        if not (HOLE_RATIO_RANGE[0] <= ratio <= HOLE_RATIO_RANGE[1]):
            continue
        dist = math.hypot(cx - ocx, cy - ocy)
        if dist > 0.18 * outer_maj:
            continue
        pts = sample_ellipse(ell, 16)
        # hole must sit inside the outer ellipse, not on the rim
        if np.max(np.hypot(pts[:, 0] - ocx, pts[:, 1] - ocy)) > 0.45 * outer_maj:
            continue
        centered = 1.0 - dist / (0.18 * outer_maj)
        prefer_true_hole = 1.15 if ratio < 0.2 else 1.0
        s = score * centered * prefer_true_hole
        if s > best_s:
            best_s = s
            best = ell
    return best


def filled_ellipse_mask(shape: tuple[int, ...], ell: tuple, scale: float = 1.0) -> np.ndarray:
    mask = np.zeros(shape[:2], dtype=np.uint8)
    (cx, cy), (w, h), ang = ell
    axes = (max(1, int(round(w * scale / 2.0))), max(1, int(round(h * scale / 2.0))))
    cv2.ellipse(mask, (int(round(cx)), int(round(cy))), axes, ang, 0, 360, 255, -1)
    return mask


def hole_from_darkness(gray: np.ndarray, outer: tuple) -> tuple | None:
    disc = filled_ellipse_mask(gray.shape, outer, 0.92)
    core = filled_ellipse_mask(gray.shape, outer, 0.40)
    pixels = gray[disc > 0]
    if pixels.size < 200:
        return None
    dark = (gray < np.percentile(pixels, 18)).astype(np.uint8) * 255
    dark = cv2.bitwise_and(dark, core)
    dark = cv2.morphologyEx(dark, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
    contours, _ = cv2.findContours(dark, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    (ocx, ocy), (ow, oh), _ = outer
    outer_maj = max(ow, oh)
    best = None
    best_s = 0.0
    for contour in contours:
        if len(contour) < 16:
            continue
        try:
            ell = cv2.fitEllipse(contour)
        except cv2.error:
            continue
        (cx, cy), (w, h), _ = ell
        maj, minor = max(w, h), min(w, h)
        if minor < 4:
            continue
        ratio = maj / outer_maj
        if not (HOLE_RATIO_RANGE[0] <= ratio <= HOLE_RATIO_RANGE[1]):
            continue
        if maj / max(minor, 1e-6) > MAX_ASPECT:
            continue
        dist = math.hypot(cx - ocx, cy - ocy)
        if dist > 0.18 * outer_maj:
            continue
        area = cv2.contourArea(contour)
        s = area * (1.0 - dist / (0.18 * outer_maj))
        if s > best_s:
            best_s = s
            best = ell
    return best


def pick_hole(cands: list[tuple[tuple, float]], outer: tuple, gray: np.ndarray) -> tuple | None:
    from_cands = hole_from_candidates(cands, outer)
    from_dark = hole_from_darkness(gray, outer)
    if from_cands is None:
        return from_dark
    if from_dark is None:
        return from_cands
    # Prefer the smaller well-centered ellipse (true spindle hole over stacking ring)
    def hole_key(ell: tuple) -> tuple[float, float]:
        (cx, cy), (w, h), _ = ell
        (ocx, ocy), (ow, oh), _ = outer
        dist = math.hypot(cx - ocx, cy - ocy) / max(ow, oh)
        return (dist, max(w, h))

    return min((from_cands, from_dark), key=hole_key)


def rectify_homography(outer: tuple, hole: tuple | None, out_size: int) -> np.ndarray | None:
    r = out_size / 2.0 - 1.0
    cx = cy = (out_size - 1) / 2.0
    src = sample_ellipse(outer, N_SAMPLE)
    dst = sample_circle(cx, cy, r, N_SAMPLE)
    if hole is not None:
        (ow, oh) = ellipse_axes(outer)
        (hw, hh) = ellipse_axes(hole)
        inner_r = r * (max(hw, hh) / max(ow, oh))
        src = np.vstack([src, sample_ellipse(hole, N_SAMPLE)])
        dst = np.vstack([dst, sample_circle(cx, cy, inner_r, N_SAMPLE)])
        src = np.vstack([src, np.array([hole[0]], dtype=np.float32)])
        dst = np.vstack([dst, np.array([[cx, cy]], dtype=np.float32)])
    H, _mask = cv2.findHomography(src, dst, cv2.RANSAC, 3.0)
    return H


def circular_alpha(out_size: int) -> np.ndarray:
    yy, xx = np.mgrid[0:out_size, 0:out_size].astype(np.float32)
    cx = cy = (out_size - 1) / 2.0
    r = out_size / 2.0 - 0.5
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
    return np.clip((r + 0.75 - d) / 1.5 * 255.0, 0, 255).astype(np.uint8)


def apply_circle_alpha(bgr: np.ndarray) -> np.ndarray:
    h, w = bgr.shape[:2]
    if h != w:
        raise RuntimeError("internal: warped image is not square")
    bgra = cv2.cvtColor(bgr, cv2.COLOR_BGR2BGRA)
    bgra[:, :, 3] = circular_alpha(h)
    return bgra


def rotate_clockwise(bgr: np.ndarray, degrees: float) -> np.ndarray:
    if abs(degrees) < 1e-6:
        return bgr
    h, w = bgr.shape[:2]
    m = cv2.getRotationMatrix2D(((w - 1) / 2.0, (h - 1) / 2.0), -degrees, 1.0)
    return cv2.warpAffine(
        bgr,
        m,
        (w, h),
        flags=cv2.INTER_LANCZOS4,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=(0, 0, 0),
    )


def debug_overlay(bgr: np.ndarray, outer: tuple, hole: tuple | None) -> np.ndarray:
    vis = bgr.copy()
    (cx, cy), (w, h), ang = outer
    cv2.ellipse(
        vis,
        (int(round(cx)), int(round(cy))),
        (max(1, int(round(w / 2))), max(1, int(round(h / 2)))),
        ang,
        0,
        360,
        (0, 220, 0),
        3,
    )
    cv2.circle(vis, (int(round(cx)), int(round(cy))), 5, (0, 220, 0), -1)
    if hole is not None:
        (hx, hy), (hw, hh), hang = hole
        cv2.ellipse(
            vis,
            (int(round(hx)), int(round(hy))),
            (max(1, int(round(hw / 2))), max(1, int(round(hh / 2)))),
            hang,
            0,
            360,
            (220, 220, 0),
            2,
        )
        cv2.circle(vis, (int(round(hx)), int(round(hy))), 4, (220, 220, 0), -1)
    return vis


def detect_disc(bgr: np.ndarray) -> tuple[tuple, tuple | None]:
    h, w = bgr.shape[:2]
    scale = max(h, w) / float(DETECT_MAX_SIDE)
    if scale < 1.0:
        scale = 1.0
        work = bgr
    else:
        work = cv2.resize(bgr, (int(round(w / scale)), int(round(h / scale))), interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(work, cv2.COLOR_BGR2GRAY)
    cands = collect_candidates(gray)
    outer = pick_outer(cands)
    if outer is None:
        raise ValueError("no disc ellipse found")
    hole = pick_hole(cands, outer, gray)
    if scale != 1.0:
        outer = scale_ellipse(outer, scale)
        if hole is not None:
            hole = scale_ellipse(hole, scale)
    return outer, hole


def flatten(bgr: np.ndarray, outer: tuple, hole: tuple | None, rotate: float) -> np.ndarray:
    major, _minor = ellipse_axes(outer)
    out_size = int(round(major))
    out_size = max(OUT_SIZE_MIN, min(OUT_SIZE_MAX, out_size))
    if out_size % 2:
        out_size += 1
    H = rectify_homography(outer, hole, out_size)
    if H is None:
        raise ValueError("could not compute rectifying homography")
    warped = cv2.warpPerspective(
        bgr,
        H,
        (out_size, out_size),
        flags=cv2.INTER_LANCZOS4,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=(0, 0, 0),
    )
    warped = rotate_clockwise(warped, rotate)
    return apply_circle_alpha(warped)


_IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".tif", ".tiff"}


def output_is_directory(out_arg: Path, many: bool) -> bool:
    if many:
        return True
    if out_arg.is_dir():
        return True
    return out_arg.suffix.lower() not in _IMAGE_SUFFIXES


def default_output_path(src: Path, out_arg: Path | None, many: bool) -> Path:
    name = f"{src.stem}.disc.png"
    if out_arg is None:
        return src.with_name(name)
    if output_is_directory(out_arg, many):
        return out_arg / name
    return out_arg


def debug_path_for(dest: Path) -> Path:
    return dest.with_name(dest.stem + ".debug.png")


def process_one(src: Path, dest: Path, rotate: float, debug: bool) -> None:
    if not src.is_file():
        raise FileNotFoundError(src)
    bgr = read_bgr(src)
    if bgr is None:
        raise ValueError(f"could not decode image: {src}")
    outer, hole = detect_disc(bgr)
    bgra = flatten(bgr, outer, hole, rotate)
    write_png(dest, bgra)
    if debug:
        overlay = debug_overlay(bgr, outer, hole)
        write_png(debug_path_for(dest), overlay)


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="discflat",
        description="Cut a disc from a photo, un-project it to a circle, write a square transparent PNG.",
    )
    p.add_argument("images", nargs="+", type=Path, help="Input photo(s)")
    p.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Output PNG (single input) or directory (batch). Default: <stem>.disc.png beside each input.",
    )
    p.add_argument(
        "--debug",
        action="store_true",
        help="Also write <output-stem>.debug.png with fitted rim (green) and hole (cyan).",
    )
    p.add_argument(
        "--rotate",
        type=float,
        default=0.0,
        metavar="DEG",
        help="Rotate the flattened disc clockwise (label 'up' is not detected).",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    images: list[Path] = args.images
    out_arg: Path | None = args.output
    many = len(images) > 1
    if many and out_arg is not None and out_arg.suffix.lower() in _IMAGE_SUFFIXES and not out_arg.is_dir():
        print("discflat: with multiple inputs, -o must be a directory", file=sys.stderr)
        return 2
    if out_arg is not None and output_is_directory(out_arg, many):
        out_arg.mkdir(parents=True, exist_ok=True)

    failures = 0
    for src in images:
        dest = default_output_path(src, out_arg, many)
        try:
            process_one(src, dest, args.rotate, args.debug)
            extra = f"  debug {debug_path_for(dest)}" if args.debug else ""
            print(f"{src} -> {dest}{extra}")
        except Exception as exc:
            failures += 1
            print(f"discflat: {src}: {exc}", file=sys.stderr)
    if failures:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
