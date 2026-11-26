#!/usr/bin/env python3
"""Standalone Mainland China Dockerfile / Docker Compose mirror linter.

Checks a build file for un-mirrored bare Docker Hub images (when the host
daemon has no `registry-mirrors` across Linux, macOS, Windows, or WSL2) and for
package installs that never switched to a domestic mirror. Exit code 1 when
warnings are found.

Usage:
    python3 mirror_lint.py Dockerfile [more files...]
    python mirror_lint.py compose.yaml --json
    python mirror_lint.py Dockerfile --assume-daemon-mirrors
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import List, Optional, Sequence


def _has_registry_host(image_ref: str) -> bool:
    """Return True if image_ref begins with an explicit registry domain/port (e.g. docker.m.daocloud.io/...)."""
    if "/" not in image_ref:
        return False
    first = image_ref.split("/", 1)[0]
    return "." in first or ":" in first or first == "localhost"


def candidate_daemon_json_paths() -> List[Path]:
    """Return platform-appropriate Docker daemon.json locations (macOS, Linux, Windows, WSL2)."""
    override = os.environ.get("CN_DOCKER_DAEMON_JSON", "").strip()
    if override:
        return [Path(override)]

    paths: List[Path] = []
    home = Path.home()

    if sys.platform == "win32":
        paths.append(home / ".docker" / "daemon.json")
        prog_data = os.environ.get("PROGRAMDATA", r"C:\ProgramData")
        paths.append(Path(prog_data) / "docker" / "config" / "daemon.json")
    elif sys.platform == "darwin":
        paths.append(home / ".docker" / "daemon.json")
        paths.append(home / ".orbstack" / "config" / "docker.json")
    else:
        paths.append(Path("/etc/docker/daemon.json"))
        paths.append(home / ".config" / "docker" / "daemon.json")
        paths.append(home / ".docker" / "daemon.json")
        # WSL2 with Docker Desktop on Windows stores daemon.json under /mnt/c/Users/<user>/.docker/daemon.json
        is_wsl = bool(os.environ.get("WSL_DISTRO_NAME"))
        if not is_wsl:
            try:
                is_wsl = "microsoft" in Path("/proc/version").read_text(encoding="utf-8", errors="ignore").lower()
            except Exception:
                is_wsl = False
        if is_wsl:
            users_root = Path("/mnt/c/Users")
            if users_root.is_dir():
                for child in sorted(users_root.iterdir()):
                    cand = child / ".docker" / "daemon.json"
                    if cand.is_file():
                        paths.append(cand)

    return paths


def _file_has_mirrors(daemon_json_path: Path) -> bool:
    try:
        if not daemon_json_path.is_file():
            return False
        data = json.loads(daemon_json_path.read_text(encoding="utf-8"))
        mirrors = data.get("registry-mirrors") if isinstance(data, dict) else None
        return isinstance(mirrors, list) and any(str(m).strip() for m in mirrors)
    except Exception:
        return False


def host_has_docker_mirrors(daemon_json_path: Optional[Path] = None) -> bool:
    """Return True if host Docker daemon.json configures non-empty registry-mirrors."""
    if daemon_json_path is not None:
        return _file_has_mirrors(daemon_json_path)
    return any(_file_has_mirrors(p) for p in candidate_daemon_json_paths())


def check_deploy_mirror_warnings(
    rel_path: str,
    content: str,
    local_images: Optional[Sequence[str]] = None,
    daemon_mirrors_configured: Optional[bool] = None,
) -> List[str]:
    """Static guard detecting un-mirrored bare Docker Hub refs (when daemon lacks mirrors) or un-mirrored pkg installs."""
    warnings: List[str] = []
    name_low = Path(rel_path).name.lower()
    is_dockerfile = "dockerfile" in name_low
    is_compose = ("compose" in name_low) and name_low.endswith((".yml", ".yaml"))
    if not (is_dockerfile or is_compose):
        return warnings

    has_daemon_mirrors = (
        host_has_docker_mirrors()
        if daemon_mirrors_configured is None
        else bool(daemon_mirrors_configured)
    )

    local_set = set(local_images or ())
    local_set_bare = set(local_set)
    for img in local_set:
        if img.endswith(":latest"):
            local_set_bare.add(img[:-7])

    def _check_img(img_ref: str, stage_aliases: set) -> None:
        ref = img_ref.strip().strip('"').strip("'")
        if not ref or ref.lower() == "scratch" or "$" in ref:
            return
        if ref.lower() in stage_aliases:
            return
        if ref.startswith("cn_local_") or ref.startswith("local/") or ref.endswith((":local", ":dev")):
            return
        if ref in local_set_bare or (":" not in ref and (ref + ":latest") in local_set):
            return
        if not has_daemon_mirrors and not _has_registry_host(ref):
            p1 = "docker.1ms.run/library/%s" % ref if "/" not in ref else "docker.1ms.run/%s" % ref
            p2 = "docker.1panel.live/library/%s" % ref if "/" not in ref else "docker.1panel.live/%s" % ref
            p3 = "docker.m.daocloud.io/library/%s" % ref if "/" not in ref else "docker.m.daocloud.io/%s" % ref
            warnings.append(
                "Bare Docker Hub image %r is not cached locally and host daemon.json has no registry-mirrors! "
                "Prefix it in fallback order: %r -> %r -> %r."
                % (ref, p1, p2, p3)
            )

    if is_dockerfile:
        stage_aliases = set()
        for line in content.splitlines():
            m = re.match(
                r"^\s*FROM\s+(?:--platform=\S+\s+)?(\S+)(?:\s+AS\s+(\S+))?",
                line,
                flags=re.IGNORECASE,
            )
            if m:
                _check_img(m.group(1), stage_aliases)
                if m.group(2):
                    stage_aliases.add(m.group(2).strip().lower())
        low = content.lower()
        has_cn_pkg_mirror = any(
            h in low for h in ("mirrors.aliyun.com", "mirrors.ustc.edu.cn", "mirrors.tuna.tsinghua.edu.cn")
        )
        if "apt-get update" in low and not has_cn_pkg_mirror:
            warnings.append(
                "Dockerfile runs 'apt-get update' without switching APT sources to mirrors.aliyun.com or mirrors.ustc.edu.cn."
            )
        if "apk add" in low and not has_cn_pkg_mirror:
            warnings.append(
                "Dockerfile runs 'apk add' without switching /etc/apk/repositories to mirrors.aliyun.com/alpine."
            )
        if re.search(r"\bpip3?\s+install\b", low) and "mirrors.aliyun.com" not in low and "tuna.tsinghua" not in low:
            warnings.append(
                "Dockerfile runs 'pip install' without a China PyPI mirror (-i https://mirrors.aliyun.com/pypi/simple/)."
            )
        if re.search(r"\b(?:curl|wget|git\s+clone)\b[^\n]*github\.com", low):
            warnings.append(
                "Dockerfile fetches directly from github.com which may time out on Mainland China hosts! Avoid direct github.com downloads."
            )

    if is_compose:
        for line in content.splitlines():
            m = re.match(r'^\s*image:\s*["\']?([^"\'\s#]+)["\']?', line)
            if m:
                _check_img(m.group(1), set())

    return warnings


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Lint Dockerfiles and docker-compose files for Mainland China mirror & network readiness."
    )
    parser.add_argument("files", nargs="+", type=Path, help="Dockerfile or *compose*.yml files to inspect")
    parser.add_argument(
        "--assume-daemon-mirrors",
        action="store_true",
        help="Skip bare Docker Hub image warnings (assume host daemon.json configures registry-mirrors)",
    )
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON instead of text")
    args = parser.parse_args(argv)

    total_warnings = 0
    results = []
    for fpath in args.files:
        if not fpath.is_file():
            if not args.json:
                print(f"[SKIP] Not a file: {fpath}", file=sys.stderr)
            results.append({"file": str(fpath), "warnings": [], "error": "not a file"})
            continue
        warns = check_deploy_mirror_warnings(
            rel_path=fpath.name,
            content=fpath.read_text(encoding="utf-8", errors="replace"),
            daemon_mirrors_configured=True if args.assume_daemon_mirrors else None,
        )
        total_warnings += len(warns)
        results.append({"file": str(fpath), "warnings": warns})
        if not args.json:
            if warns:
                print(f"[WARN] {fpath}:")
                for w in warns:
                    print(f"  - {w}")
            else:
                print(f"[OK] {fpath}: no mirror warnings")

    if args.json:
        print(json.dumps({"files": results, "total_warnings": total_warnings}, ensure_ascii=False, indent=2))
    return 1 if total_warnings else 0


if __name__ == "__main__":
    sys.exit(main())
