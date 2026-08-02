"""Prepare complete, playback-ready sequences for one-shot pet actions."""

from __future__ import annotations

import os
import shutil

def prepare_reaction_sequence(frames_dir, output_dir, fps=10):
    """Copy every usable frame into an action sequence without sampling.

    Selecting a high-motion sub-range made one-shot actions shorter, but it
    silently discarded the owner's generated frames. The runtime can play a
    non-looping sequence directly, so preserving the exact source sequence is
    both simpler and faithful to the source video.
    """
    del fps  # Retained in the public signature for Swift and CLI compatibility.
    paths = sorted(
        os.path.join(frames_dir, name)
        for name in os.listdir(frames_dir)
        if name.startswith("frame_")
        and os.path.splitext(name)[1].lower() in {".png", ".jpg", ".jpeg"}
        and not name.lower().endswith("_a.jpg")
    )
    if not paths:
        return {
            "prepared": False,
            "reason": "no_frames",
            "message": "动作素材中没有有效帧",
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

    for output_index, source in enumerate(paths):
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
        "frame_count": len(paths),
        "source_frame_count": len(paths),
        "start_index": 0,
        "end_index": len(paths),
    }
