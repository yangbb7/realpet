"""Semantic quality gates for imported action frame sequences."""

from __future__ import annotations

import glob
import os

import cv2
import numpy as np
from PIL import Image


GAZE_KINDS = {"gaze_left", "gaze_right", "gaze_up", "gaze_down"}
IDENTITY_SAMPLE_COUNT = 10
IDENTITY_HISTOGRAM_BINS = (12, 8)
IDENTITY_MIN_SIMILARITY = 0.52


def _frame_paths(frames_dir, max_frames=60):
    paths = sorted(glob.glob(os.path.join(frames_dir, "frame_*.png")))
    if not paths:
        all_jpg = sorted(glob.glob(os.path.join(frames_dir, "frame_*.jpg")))
        paths = [path for path in all_jpg if not path.endswith("_a.jpg")]
    if max_frames is None or len(paths) <= max_frames:
        return paths
    indices = np.linspace(0, len(paths) - 1, max_frames).round().astype(int)
    return [paths[index] for index in indices]


def _load_rgba(path):
    if path.lower().endswith(".jpg"):
        stem, _ = os.path.splitext(path)
        alpha_path = stem + "_a.jpg"
        rgb = np.array(Image.open(path).convert("RGB"))
        if os.path.exists(alpha_path):
            alpha = np.array(Image.open(alpha_path).convert("L"))
        else:
            alpha = np.full(rgb.shape[:2], 255, dtype=np.uint8)
        return rgb, alpha
    rgba = np.array(Image.open(path).convert("RGBA"))
    return rgba[:, :, :3], rgba[:, :, 3]


def _lower_body_centroid(mask):
    ys, xs = np.where(mask)
    if not len(xs):
        return 0.0, 0.0
    lower_y = int(ys.min() + (ys.max() - ys.min() + 1) * 0.55)
    lower_indices = ys >= lower_y
    lower_xs = xs[lower_indices]
    lower_ys = ys[lower_indices]
    if not len(lower_xs):
        return float(xs.mean()), float(ys.mean())
    return float(lower_xs.mean()), float(lower_ys.mean())


def _upper_body_centroid(mask):
    ys, xs = np.where(mask)
    if not len(xs):
        return 0.0, 0.0
    upper_y = int(ys.min() + (ys.max() - ys.min() + 1) * 0.50)
    upper_indices = ys <= upper_y
    upper_xs = xs[upper_indices]
    upper_ys = ys[upper_indices]
    if not len(upper_xs):
        return float(xs.mean()), float(ys.mean())
    return float(upper_xs.mean()), float(upper_ys.mean())


def _direction_reversals(values, minimum_delta):
    directions = []
    for previous, current in zip(values, values[1:]):
        delta = current - previous
        if abs(delta) < minimum_delta:
            continue
        direction = 1 if delta > 0 else -1
        if not directions or directions[-1] != direction:
            directions.append(direction)
    return max(0, len(directions) - 1)


def analyze_action_frames(
        frames_dir, kind, max_frames=60, include_series=False):
    paths = _frame_paths(frames_dir, max_frames=max_frames)
    if len(paths) < 6:
        return {
            "passed": False, "kind": kind,
            "reason": "too_few_frames", "message": "动作帧太少，至少需要 6 帧",
            "frame_count": len(paths),
        }

    frames = [_load_rgba(path) for path in paths]
    masks = [alpha > 40 for _, alpha in frames]
    union = np.logical_or.reduce(masks)
    _, xs = np.where(union)
    if not len(xs):
        return {
            "passed": False, "kind": kind,
            "reason": "empty_foreground", "message": "动作帧中没有有效宠物前景",
            "frame_count": len(paths),
        }

    x0, x1 = int(xs.min()), int(xs.max()) + 1
    bbox_width = max(1, x1 - x0)

    lower_changes = []
    lower_rgb_motion = []
    full_changes = []
    centroids = []
    lower_centroids = []
    relative_head_x = []
    relative_head_y = []
    kernel = np.ones((3, 3), np.uint8)
    for _, mask in zip(frames, masks):
        coords = np.where(mask)
        centroids.append((
            float(coords[1].mean()) if len(coords[1]) else 0.0,
            float(coords[0].mean()) if len(coords[0]) else 0.0,
        ))
        lower_centroids.append(_lower_body_centroid(mask))
        upper = _upper_body_centroid(mask)
        relative_head_x.append(upper[0] - lower_centroids[-1][0])
        relative_head_y.append(upper[1] - lower_centroids[-1][1])

    for index in range(1, len(frames)):
        previous_full = masks[index - 1]
        current_full = masks[index]
        dx = lower_centroids[index - 1][0] - lower_centroids[index][0]
        dy = lower_centroids[index - 1][1] - lower_centroids[index][1]
        transform = np.float32([[1, 0, dx], [0, 1, dy]])
        current_aligned = cv2.warpAffine(
            current_full.astype(np.uint8), transform,
            (current_full.shape[1], current_full.shape[0]),
            flags=cv2.INTER_NEAREST, borderValue=0).astype(bool)
        current_rgb_aligned = cv2.warpAffine(
            frames[index][0], transform,
            (current_full.shape[1], current_full.shape[0]),
            flags=cv2.INTER_LINEAR, borderValue=0)

        pair_union = np.logical_or(previous_full, current_aligned)
        pair_ys, pair_xs = np.where(pair_union)
        if not len(pair_xs):
            full_changes.append(0.0)
            lower_changes.append(0.0)
            lower_rgb_motion.append(0.0)
            continue
        px0, px1 = int(pair_xs.min()), int(pair_xs.max()) + 1
        py0, py1 = int(pair_ys.min()), int(pair_ys.max()) + 1
        previous_pair = previous_full[py0:py1, px0:px1]
        current_pair = current_aligned[py0:py1, px0:px1]
        full_changed = np.logical_xor(previous_pair, current_pair).sum()
        full_occupied = np.logical_or(previous_pair, current_pair).sum()
        full_changes.append(float(full_changed / max(1, full_occupied)))

        lower_y = py0 + int((py1 - py0) * 0.55)
        previous_mask = previous_full[lower_y:py1, px0:px1]
        current_mask = current_aligned[lower_y:py1, px0:px1]
        changed = np.logical_xor(previous_mask, current_mask).sum()
        occupied = np.logical_or(previous_mask, current_mask).sum()
        lower_changes.append(float(changed / max(1, occupied)))

        interior = cv2.erode(
            np.logical_and(previous_mask, current_mask).astype(np.uint8),
            kernel, iterations=1).astype(bool)
        previous_rgb = frames[index - 1][0][lower_y:py1, px0:px1]
        current_rgb = current_rgb_aligned[lower_y:py1, px0:px1]
        color_delta = np.abs(
            current_rgb.astype(np.int16) - previous_rgb.astype(np.int16)).mean(axis=2)
        lower_rgb_motion.append(float(
            np.logical_and(interior, color_delta > 18).sum()
            / max(1, interior.sum())))

    median_lower_change = float(np.median(lower_changes))
    active_lower_ratio = float(np.mean(np.array(lower_changes) >= 0.012))
    median_lower_rgb = float(np.median(lower_rgb_motion))
    median_full_change = float(np.median(full_changes))
    active_full_ratio = float(np.mean(np.array(full_changes) >= 0.008))
    peak_full_change = float(np.max(full_changes))
    p90_full_change = float(np.percentile(full_changes, 90))
    active_count = max(1, len(full_changes) // 3)
    active_third_mean = float(np.mean(np.sort(full_changes)[-active_count:]))
    burst_contrast = peak_full_change / max(0.000001, median_full_change)
    centroid_span = float(
        (max(point[0] for point in centroids)
         - min(point[0] for point in centroids)) / bbox_width)
    head_horizontal_span = float(
        (max(relative_head_x) - min(relative_head_x)) / bbox_width)
    head_vertical_span = float(
        (max(relative_head_y) - min(relative_head_y)) / bbox_width)
    head_direction_reversals = _direction_reversals(
        relative_head_x, minimum_delta=max(0.75, bbox_width * 0.0035))

    if kind in {"walk", "run"}:
        articulated = active_lower_ratio >= 0.30 and (
            median_lower_change >= 0.025
            or (median_lower_change >= 0.010 and median_lower_rgb >= 0.008)
        )
        passed = articulated
        message = ("动作验证通过" if passed else
                   "未检测到持续腿部步态，请使用完整拍到四肢的走路视频")
        reason = None if passed else "no_locomotion_evidence"
    else:
        coherent_burst = (
            peak_full_change >= 0.012
            and p90_full_change >= 0.009
            and active_third_mean >= 0.009
            and burst_contrast >= 2.0
        )
        generic_reaction = (
            median_full_change >= 0.008
            or active_full_ratio >= 0.30
            or centroid_span >= 0.03
            or coherent_burst
        )
        if kind in GAZE_KINDS:
            head_motion = max(head_horizontal_span, head_vertical_span)
            passed = (
                generic_reaction
                and head_motion >= 0.015
                and active_lower_ratio < 0.35
            )
            message = (
                "注视素材验证通过，请在预览中确认方向"
                if passed else "未检测到清晰的头部转向，请重录让宠物看向目标方向")
            reason = None if passed else "no_gaze_evidence"
        elif kind == "shake_head":
            passed = (
                generic_reaction
                and head_horizontal_span >= 0.025
                and head_direction_reversals >= 1
                and active_lower_ratio < 0.35
            )
            message = ("动作验证通过" if passed else
                       "未检测到头部左右往返，请使用完整拍到摇头过程的视频")
            reason = None if passed else "no_head_shake_evidence"
        elif kind == "play":
            lower_body_engaged = (
                active_lower_ratio >= 0.18
                and (median_lower_change >= 0.006
                     or median_lower_rgb >= 0.006)
            )
            passed = generic_reaction and lower_body_engaged
            message = ("动作验证通过" if passed else
                       "未检测到躯干或四肢参与，请使用玩耍动作明显的视频")
            reason = None if passed else "no_play_evidence"
        else:
            passed = generic_reaction
            message = ("动作验证通过" if passed else
                       "素材动作变化太小，请换一段互动更明显的视频")
            reason = None if passed else "insufficient_motion"

    result = {
        "passed": passed,
        "kind": kind,
        "reason": reason,
        "message": message,
        "frame_count": len(paths),
        "metrics": {
            "median_lower_change": median_lower_change,
            "active_lower_ratio": active_lower_ratio,
            "median_lower_rgb": median_lower_rgb,
            "median_full_change": median_full_change,
            "active_full_ratio": active_full_ratio,
            "peak_full_change": peak_full_change,
            "p90_full_change": p90_full_change,
            "active_third_mean": active_third_mean,
            "burst_contrast": burst_contrast,
            "centroid_span": centroid_span,
            "head_horizontal_span": head_horizontal_span,
            "head_vertical_span": head_vertical_span,
            "head_direction_reversals": head_direction_reversals,
        },
    }
    if include_series:
        result["frame_paths"] = paths
        result["full_changes"] = full_changes
    return result


def _sample_paths(paths, maximum=IDENTITY_SAMPLE_COUNT):
    if len(paths) <= maximum:
        return paths
    indices = np.linspace(0, len(paths) - 1, maximum).round().astype(int)
    return [paths[index] for index in indices]


def _identity_descriptor(frames_dir):
    """Summarize foreground appearance without loading a learned identity model.

    The response capture is already alpha-matted by the same pipeline as the
    idle loop. Comparing hue/saturation distribution and normalized silhouette
    is a deliberately conservative continuity gate: it catches a clearly
    different animal or a broken matte while leaving final identity approval to
    the owner's preview.
    """
    histograms = []
    aspects = []
    for path in _sample_paths(_frame_paths(frames_dir, max_frames=None)):
        rgb, alpha = _load_rgba(path)
        mask = (alpha >= 64).astype(np.uint8)
        ys, xs = np.where(mask)
        if len(xs) < 64:
            continue
        x0, x1 = int(xs.min()), int(xs.max()) + 1
        y0, y1 = int(ys.min()), int(ys.max()) + 1
        crop = rgb[y0:y1, x0:x1]
        crop_mask = mask[y0:y1, x0:x1]
        hsv = cv2.cvtColor(crop, cv2.COLOR_RGB2HSV)
        histogram = cv2.calcHist(
            [hsv], [0, 1], crop_mask, IDENTITY_HISTOGRAM_BINS,
            [0, 180, 0, 256]).astype(np.float64)
        total = histogram.sum()
        if total <= 0:
            continue
        histograms.append(histogram / total)
        aspects.append((x1 - x0) / max(1.0, y1 - y0))
    if not histograms:
        return None
    return {
        "histogram": np.median(np.stack(histograms), axis=0),
        "aspect": float(np.median(aspects)),
        "samples": len(histograms),
    }


def compare_foreground_identity(reference_frames_dir, candidate_frames_dir):
    """Return a local appearance-continuity score in [0, 1]."""
    reference = _identity_descriptor(reference_frames_dir)
    candidate = _identity_descriptor(candidate_frames_dir)
    if reference is None or candidate is None:
        return {
            "passed": False,
            "similarity": 0.0,
            "histogram_similarity": 0.0,
            "silhouette_similarity": 0.0,
            "reason": "identity_reference_unavailable",
        }
    histogram_similarity = float(np.minimum(
        reference["histogram"], candidate["histogram"]).sum())
    aspect_delta = abs(np.log(
        max(reference["aspect"], 1e-6) / max(candidate["aspect"], 1e-6)))
    silhouette_similarity = max(0.0, 1.0 - min(1.0, aspect_delta / 0.70))
    similarity = 0.80 * histogram_similarity + 0.20 * silhouette_similarity
    return {
        "passed": similarity >= IDENTITY_MIN_SIMILARITY,
        "similarity": float(similarity),
        "histogram_similarity": histogram_similarity,
        "silhouette_similarity": silhouette_similarity,
        "reference_samples": reference["samples"],
        "candidate_samples": candidate["samples"],
        "reason": None if similarity >= IDENTITY_MIN_SIMILARITY else "identity_mismatch",
    }


def validate_response_candidate(
        frames_dir, kind, reference_frames_dir, max_frames=60):
    """Combine semantic motion and local owner-appearance continuity gates."""
    result = analyze_action_frames(frames_dir, kind, max_frames=max_frames)
    identity = compare_foreground_identity(reference_frames_dir, frames_dir)
    result["identity"] = identity
    result.setdefault("metrics", {})["identity_similarity"] = identity["similarity"]
    if not identity["passed"]:
        result["passed"] = False
        result["reason"] = identity["reason"]
        result["message"] = "素材外观与待机宠物差异过大，请确认使用同一只宠物的视频"
    elif result["passed"]:
        result["message"] = "动作与实拍外观连续性验证通过，请在预览中确认"
    return result
