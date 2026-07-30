"""Prepare short, motion-focused sequences for one-shot pet actions."""

from __future__ import annotations

import os
import shutil

import numpy as np

from pipeline.action_quality import analyze_action_frames


def select_reaction_range(full_changes, frame_count, fps=10, duration=1.2):
    if frame_count < 6 or len(full_changes) != frame_count - 1:
        return None
    window = max(6, min(frame_count, int(round(max(0.6, duration) * fps))))
    if window >= frame_count:
        return 0, frame_count

    scores = [
        float(np.mean(full_changes[start:start + window - 1]))
        for start in range(frame_count - window + 1)
    ]
    best_start = int(np.argmax(scores))
    local = full_changes[best_start:best_start + window - 1]
    peak_transition = best_start + int(np.argmax(local))
    start = max(0, min(frame_count - window, peak_transition - 2))
    return start, start + window


def prepare_reaction_sequence(frames_dir, output_dir, fps=10):
    analysis = analyze_action_frames(
        frames_dir, "react", max_frames=None, include_series=True)
    paths = analysis.get("frame_paths", [])
    full_changes = analysis.get("full_changes", [])
    selected = select_reaction_range(full_changes, len(paths), fps=fps)
    if selected is None:
        return {
            "prepared": False,
            "reason": analysis.get("reason", "too_few_frames"),
            "message": analysis.get("message", "无法提取互动动作"),
        }

    if os.path.exists(output_dir):
        if not os.path.isdir(output_dir) or os.listdir(output_dir):
            return {
                "prepared": False,
                "reason": "output_not_empty",
                "message": "动作输出目录不是空目录",
            }
    else:
        os.makedirs(output_dir)

    start, end = selected
    for output_index, source in enumerate(paths[start:end]):
        extension = os.path.splitext(source)[1].lower()
        destination = os.path.join(
            output_dir, f"frame_{output_index:04d}{extension}")
        shutil.copy2(source, destination)
        if extension == ".jpg":
            alpha_source = os.path.splitext(source)[0] + "_a.jpg"
            if os.path.exists(alpha_source):
                alpha_destination = os.path.join(
                    output_dir, f"frame_{output_index:04d}_a.jpg")
                shutil.copy2(alpha_source, alpha_destination)

    return {
        "prepared": True,
        "frames_dir": output_dir,
        "frame_count": end - start,
        "source_frame_count": len(paths),
        "start_index": start,
        "end_index": end,
        "source_peak_full_change": analysis["metrics"]["peak_full_change"],
    }
