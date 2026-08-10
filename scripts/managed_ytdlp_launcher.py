#!/usr/bin/env python3
"""Launch the independently updated yt-dlp script with app-owned packages only."""

import importlib
import os
import runpy
import sys


def configure_runtime() -> None:
    version = f"python{sys.version_info.major}.{sys.version_info.minor}"
    site_packages = os.path.join(sys.prefix, "lib", version, "site-packages")
    if not os.path.isdir(site_packages):
        raise SystemExit(f"Managed Python packages are missing: {site_packages}")
    sys.path.insert(0, site_packages)


def validate_runtime() -> None:
    if not sys.flags.no_site:
        raise SystemExit("Managed Python must launch with site initialization disabled")
    leaked_paths = [path for path in sys.path if path and os.path.realpath(path).startswith("/opt/homebrew/")]
    if leaked_paths:
        raise SystemExit(f"Homebrew paths leaked into managed Python: {leaked_paths}")
    for module in (
        "brotli",
        "Cryptodome",
        "mutagen",
        "requests",
        "urllib3",
        "websockets",
        "yt_dlp_ejs",
    ):
        imported = importlib.import_module(module)
        module_path = os.path.realpath(getattr(imported, "__file__", ""))
        if not module_path.startswith(os.path.realpath(sys.prefix) + os.sep):
            raise SystemExit(f"Managed module escaped the runtime: {module} -> {module_path}")
    print("Managed Python dependencies ready")


configure_runtime()

if len(sys.argv) == 2 and sys.argv[1] == "--inout-check-runtime":
    validate_runtime()
    raise SystemExit(0)

if len(sys.argv) < 2:
    raise SystemExit("Usage: managed_ytdlp_launcher.py /path/to/yt-dlp [arguments...]")

script_path = os.path.realpath(sys.argv[1])
sys.argv = sys.argv[1:]
sys.path.insert(0, script_path)
runpy.run_path(script_path, run_name="__main__")
