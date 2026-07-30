import json

import numpy as np
from safetensors.numpy import load_file, save_file

from pipeline.model_paths import BIREFNET_REPO, birefnet_checkpoint
from scripts.prepare_birefnet_fp16 import (
    MANIFEST_NAME,
    RUNTIME_FILES,
    convert_snapshot,
)


def _write_snapshot(path):
    path.mkdir()
    for filename in RUNTIME_FILES:
        content = "{}" if filename.endswith(".json") else "# test\n"
        (path / filename).write_text(content)
    save_file({
        "weight": np.array([1.0, -2.5, 0.33333334], dtype=np.float32),
        "counter": np.array(7, dtype=np.int64),
    }, path / "model.safetensors", metadata={"format": "pt"})


def test_fp16_checkpoint_matches_runtime_conversion(tmp_path):
    source = tmp_path / "source"
    output = tmp_path / "output"
    _write_snapshot(source)

    convert_snapshot(source, output)
    tensors = load_file(output / "model.safetensors")

    expected = load_file(source / "model.safetensors")
    np.testing.assert_array_equal(
        tensors["weight"], expected["weight"].astype(np.float16))
    np.testing.assert_array_equal(tensors["counter"], expected["counter"])
    assert tensors["counter"].shape == ()
    assert tensors["weight"].dtype == np.float16
    assert json.loads((output / MANIFEST_NAME).read_text())["tensor_count"] == 2
    for filename in RUNTIME_FILES:
        assert (output / filename).is_file()


def test_birefnet_checkpoint_prefers_complete_local_model(tmp_path, monkeypatch):
    monkeypatch.setenv("REALPET_WEIGHTS_DIR", str(tmp_path))
    assert birefnet_checkpoint() == BIREFNET_REPO

    local = tmp_path / "birefnet-fp16"
    local.mkdir()
    for filename in ("config.json", "model.safetensors", "birefnet.py"):
        (local / filename).touch()
    assert birefnet_checkpoint() == str(local)


def test_explicit_birefnet_checkpoint_wins(tmp_path, monkeypatch):
    explicit = tmp_path / "custom-model"
    monkeypatch.setenv("REALPET_BIREFNET_CHECKPOINT", str(explicit))
    assert birefnet_checkpoint() == str(explicit)
