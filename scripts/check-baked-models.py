#!/usr/bin/env python3
"""Require the full Hindsight image to contain its default local models.

The full image preloads whatever hindsight_api.config names as the local
embedding and reranker. Those ids move between releases (1.2.0 replaced
cross-encoder/ms-marco-MiniLM-L-6-v2 with hindsight-ai/hs-rerank-1), so the
check reads the constants from the image instead of pinning repo ids.
"""

import ast
import os
import sys
from pathlib import Path

EMBEDDING_CONST = "DEFAULT_EMBEDDINGS_LOCAL_MODEL"
RERANKER_CONST = "DEFAULT_RERANKER_LOCAL_MODEL"
WEIGHT_SUFFIXES = (".safetensors", ".bin", ".onnx", ".msgpack")


def find_config() -> Path:
    override = os.environ.get("HINDSIGHT_CONFIG_PATH")
    if override:
        path = Path(override)
        if not path.is_file():
            sys.exit(f"HINDSIGHT_CONFIG_PATH does not exist: {path}")
        return path

    candidates = [
        Path("/app/api/hindsight_api/config.py"),
        Path("/app/hindsight_api/config.py"),
    ]
    for path in candidates:
        if path.is_file():
            return path

    packaged = sorted(
        Path("/app").glob("api/.venv/lib/python*/site-packages/hindsight_api/config.py")
    )
    for path in packaged:
        if path.is_file():
            return path

    sys.exit(
        "could not find hindsight_api/config.py in the image "
        "(looked in /app/api and the api virtualenv)"
    )


def hub_cache_dir() -> Path:
    override = os.environ.get("HF_HUB_CACHE") or os.environ.get("HUGGINGFACE_HUB_CACHE")
    if override:
        return Path(override)
    hf_home = os.environ.get("HF_HOME")
    if hf_home:
        return Path(hf_home) / "hub"
    home = Path(os.environ.get("HOME") or "/home/hindsight")
    return home / ".cache" / "huggingface" / "hub"


def read_default_models(config_path: Path) -> dict[str, str]:
    wanted = {EMBEDDING_CONST: "", RERANKER_CONST: ""}
    tree = ast.parse(config_path.read_text(encoding="utf-8"), filename=str(config_path))
    for node in tree.body:
        name, value = _assignment(node)
        if name not in wanted or value is None:
            continue
        if not isinstance(value, ast.Constant) or not isinstance(value.value, str):
            sys.exit(f"{name} in {config_path} is not a string constant")
        wanted[name] = value.value

    missing = [name for name, repo_id in wanted.items() if not repo_id]
    if missing:
        sys.exit(f"could not read {', '.join(missing)} from {config_path}")
    for name, repo_id in wanted.items():
        _require_repo_id(name, repo_id)
    return wanted


def _assignment(node: ast.stmt) -> tuple[str | None, ast.expr | None]:
    if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
        return node.targets[0].id, node.value
    if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.value is not None:
        return node.target.id, node.value
    return None, None


def _require_repo_id(name: str, repo_id: str) -> None:
    parts = repo_id.split("/")
    if len(parts) != 2 or any(part in ("", ".", "..") for part in parts):
        sys.exit(f"{name} is not a single-namespace Hugging Face repo id: {repo_id!r}")


def cache_dir_for(hub: Path, repo_id: str) -> Path:
    return hub / ("models--" + repo_id.replace("/", "--"))


def has_weights(repo_dir: Path) -> bool:
    snapshots = repo_dir / "snapshots"
    if not snapshots.is_dir():
        return False
    for path in snapshots.rglob("*"):
        if not path.is_file() or path.suffix not in WEIGHT_SUFFIXES:
            continue
        try:
            # Snapshot names are symlinks into blobs/. Follow them.
            size = path.stat().st_size
        except OSError:
            continue
        if size > 0:
            return True
    return False


def present_model_dirs(hub: Path) -> list[str]:
    if not hub.is_dir():
        return []
    return sorted(path.name for path in hub.glob("models--*") if path.is_dir())


def main() -> None:
    config_path = find_config()
    models = read_default_models(config_path)
    hub = hub_cache_dir()
    missing: list[str] = []
    for name, repo_id in models.items():
        directory = cache_dir_for(hub, repo_id)
        if has_weights(directory):
            print(f"{name}={repo_id} weights at {directory}")
            continue
        missing.append(f"{name}={repo_id} (looked in {directory})")

    if missing:
        found = ", ".join(present_model_dirs(hub)) or "(none)"
        sys.exit(
            "full image is missing baked local-model weights:\n- "
            + "\n- ".join(missing)
            + f"\nhub cache model dirs: {found}"
        )


if __name__ == "__main__":
    main()
