"""Regression tests for streaming/memory-bounded pipeline paths."""

import os
import tempfile

import cv2
import numpy as np

from scripts.track_then_matte import (
    TrackingMasks,
    motion_gated_temporal_smooth,
    run_quality_feedback,
    run_quality_feedback_from_files,
    stabilize_alpha_temporal,
    stabilize_alpha_temporal_files,
)


def _reference_temporal_smooth(alphas, masks, window, soft_lo=1, soft_hi=255):
    """Previous whole-clip implementation, retained as an output oracle."""
    a_stack = np.stack(alphas, axis=0).astype(np.uint8)
    s_stack = np.stack(masks, axis=0).astype(np.uint8)
    flipped = np.zeros(a_stack.shape, dtype=bool)
    for offset in range(-window, window + 1):
        if offset:
            flipped |= np.roll(s_stack, offset, axis=0) != s_stack
    eligible = (a_stack > soft_lo) & (a_stack < soft_hi) & ~flipped
    windows = np.stack([
        np.roll(a_stack, offset, axis=0)
        for offset in range(-window, window + 1)
    ])
    median = np.median(windows, axis=0)
    return np.where(eligible, median, a_stack).astype(np.uint8)


def test_streaming_temporal_smooth_is_pixel_identical():
    for n, h, w, window in ((3, 7, 11, 1), (7, 13, 17, 2), (10, 8, 9, 3)):
        rng = np.random.default_rng(n * 100 + window)
        alphas = [rng.integers(0, 256, (h, w), dtype=np.uint8) for _ in range(n)]
        masks = [rng.integers(0, 2, (h, w), dtype=np.uint8) for _ in range(n)]

        expected = _reference_temporal_smooth(alphas, masks, window)
        actual = motion_gated_temporal_smooth(
            alphas, masks, window=window, chunk_rows=4)

        assert np.array_equal(actual, expected)


def test_temporal_smooth_writes_to_supplied_memmap():
    rng = np.random.default_rng(42)
    alphas = rng.integers(0, 256, (5, 9, 13), dtype=np.uint8)
    masks = rng.integers(0, 2, (5, 9, 13), dtype=np.uint8)

    with tempfile.TemporaryDirectory() as directory:
        output = np.memmap(os.path.join(directory, "out.u8"), mode="w+",
                           dtype=np.uint8, shape=alphas.shape)
        result = motion_gated_temporal_smooth(
            alphas, masks, window=2, output=output, chunk_rows=3)
        assert result is output
        assert np.array_equal(result, _reference_temporal_smooth(alphas, masks, 2))


def _write_rgba_frames(directory, alphas):
    for index, alpha in enumerate(alphas):
        bgra = np.zeros((*alpha.shape, 4), dtype=np.uint8)
        bgra[:, :, :3] = 120
        bgra[:, :, 3] = alpha
        assert cv2.imwrite(os.path.join(directory, f"frame_{index:04d}.png"), bgra)


def test_streaming_quality_and_deflicker_match_in_memory_paths():
    h, w = 40, 48
    clean = []
    for offset in range(6):
        alpha = np.zeros((h, w), dtype=np.uint8)
        alpha[10:30, 10 + offset:30 + offset] = 255
        clean.append(alpha)
    source = [alpha.copy() for alpha in clean]
    source[3] = np.zeros((h, w), dtype=np.uint8)
    logits = {i: np.where(alpha > 0, 4.0, -4.0).astype(np.float32)
              for i, alpha in enumerate(clean)}
    bbox = [8, 8, 38, 32]

    _, expected_metrics, expected_red = run_quality_feedback(
        source, logits, bbox, h, w)
    expected_alphas, expected_flagged = stabilize_alpha_temporal(source)

    with tempfile.TemporaryDirectory() as directory:
        _write_rgba_frames(directory, source)
        metrics, red_count, coverage = run_quality_feedback_from_files(
            directory, len(source), logits, bbox, h, w)
        flagged = stabilize_alpha_temporal_files(
            directory, len(source), h, w, coverage=coverage)

        assert metrics == expected_metrics
        assert red_count == expected_red
        assert flagged == expected_flagged
        for index, expected in enumerate(expected_alphas):
            actual = cv2.imread(
                os.path.join(directory, f"frame_{index:04d}.png"),
                cv2.IMREAD_UNCHANGED)[:, :, 3]
            assert np.array_equal(actual, expected)


def test_compact_tracking_masks_preserve_quality_metrics():
    rng = np.random.default_rng(91)
    h, w, n = 24, 31, 5
    alphas = [rng.integers(0, 256, (h, w), dtype=np.uint8) for _ in range(n)]
    logits = {i: rng.normal(size=(h, w)).astype(np.float32) for i in range(n)}
    compact = TrackingMasks()
    for index, logit in logits.items():
        compact[index] = (logit > 0).astype(np.uint8)
        compact.object_scores[index] = float(np.mean(np.abs(logit)))

    _, expected_metrics, expected_red = run_quality_feedback(
        alphas, logits, None, h, w)
    _, actual_metrics, actual_red = run_quality_feedback(
        alphas, compact, None, h, w)

    assert actual_metrics == expected_metrics
    assert actual_red == expected_red
