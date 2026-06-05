#!/usr/bin/env python3
"""
Dispatcher that mirrors each source listed in projects.yml into ./docs/<slug>/.

Handler conventions
  - Every handler writes its output under <output_dir>/<slug>/.
  - Failures in a single handler are logged but do not abort the whole run.
"""

import io
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path

import requests
import yaml


def load_sources(path="projects.yml"):
    with open(path) as f:
        return yaml.safe_load(f)["sources"]


def _download(url, dest: Path) -> bool:
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"  GET {url}")
    with requests.get(url, stream=True, allow_redirects=True,
                      headers={"User-Agent": "rtd-mirror/1.0"}) as r:
        print(f"  → {r.status_code} {r.headers.get('Content-Type', '?')} (final url: {r.url})")
        if r.status_code != 200:
            return False
        with open(dest, "wb") as f:
            for chunk in r.iter_content(chunk_size=1 << 15):
                f.write(chunk)
    return True


def _rm(path: Path):
    if path.exists():
        shutil.rmtree(path)


# ─── RTD ──────────────────────────────────────────────────────────────────────

def mirror_rtd(entry, output_dir):
    slug = entry["slug"]
    version = entry.get("version", "stable")
    formats = entry.get("formats", ["htmlzip"])
    dest = Path(output_dir) / slug
    dest.mkdir(parents=True, exist_ok=True)

    if "htmlzip" in formats:
        # Try the subdomain URL first, fall back to the readthedocs.org direct URL.
        candidate_urls = [
            f"https://{slug}.readthedocs.io/_/downloads/en/{version}/htmlzip/",
            f"https://readthedocs.org/projects/{slug}/downloads/htmlzip/{version}/",
        ]
        zip_path = Path("/tmp") / f"{slug}-{version}.zip"
        downloaded = False
        for url in candidate_urls:
            if _download(url, zip_path):
                downloaded = True
                break
        if not downloaded:
            raise RuntimeError(f"HTTP failure downloading htmlzip for {slug} (tried: {candidate_urls})")
        # Verify we actually got a zip, not an HTML error page.
        with open(zip_path, "rb") as fh:
            magic = fh.read(4)
        if magic != b"PK\x03\x04":
            raise RuntimeError(
                f"Downloaded file for {slug} is not a zip (magic={magic!r}). "
                "RTD may have returned an HTML page — check the URL and project slug."
            )
        with tempfile.TemporaryDirectory() as tmp:
            with zipfile.ZipFile(zip_path) as zf:
                zf.extractall(tmp)
            # RTD htmlzip contains a single top-level <slug>-<ver>/ dir.
            entries = [p for p in Path(tmp).iterdir()]
            src = entries[0] if len(entries) == 1 and entries[0].is_dir() else Path(tmp)
            shutil.copytree(src, dest, dirs_exist_ok=True)
        zip_path.unlink(missing_ok=True)
        print(f"  [rtd] ok: {slug} → {dest}")

    if "pdf" in formats:
        url = f"https://{slug}.readthedocs.io/_/downloads/en/{version}/pdf/"
        if _download(url, dest / f"{slug}.pdf"):
            print(f"  [rtd] ok: {slug}.pdf")
        else:
            print(f"  [rtd] WARN: no pdf at {url}")


# ─── git + MkDocs ─────────────────────────────────────────────────────────────

def mirror_git_mkdocs(entry, output_dir):
    slug = entry["slug"]
    repo = entry["repo"]
    branch = entry.get("branch", "main")
    config = entry.get("config", "mkdocs.yml")

    work_dir = Path("/tmp") / f"mkdocs-{slug}"
    _rm(work_dir)
    subprocess.run(
        ["git", "clone", "--depth=1", "--branch", branch, repo, str(work_dir)],
        check=True,
    )

    # Install the project itself so any in-tree MkDocs extensions are importable.
    for extras in ("[docs]", "[doc]", "[documentation]", ""):
        spec = f".[{extras.strip('[]')}]" if extras else "."
        r = subprocess.run(
            [sys.executable, "-m", "pip", "install", "--no-cache-dir", "-e", spec],
            cwd=work_dir, capture_output=True,
        )
        if r.returncode == 0:
            print(f"  [mkdocs] installed project as {spec}")
            break

    # Best-effort install of any explicit docs requirements file.
    for req in ("docs/requirements.txt", "requirements/docs.txt",
                "requirements-docs.txt", "docs-requirements.txt"):
        rp = work_dir / req
        if rp.exists():
            print(f"  [mkdocs] installing {req}")
            subprocess.run(
                [sys.executable, "-m", "pip", "install", "--no-cache-dir", "-r", str(rp)],
                check=False,
            )
            break

    # Ensure any in-tree Python packages are importable.
    # Try installing the project in editable mode first, then set PYTHONPATH.
    subprocess.run(
        [sys.executable, "-m", "pip", "install", "--no-cache-dir", "-e", "."],
        cwd=work_dir,
        capture_output=True,
        check=False,  # Ignore failures, PYTHONPATH will be the fallback.
    )

    site_dir = work_dir / "_site"
    extra_paths = [str(work_dir), str(work_dir / "docs")]
    env = {**os.environ,
           "PYTHONPATH": ":".join(extra_paths + [os.environ.get("PYTHONPATH", "")])}
    subprocess.run(
        ["mkdocs", "build",
         "--config-file", str(work_dir / config),
         "--site-dir", str(site_dir)],
        cwd=work_dir,
        env=env,
        check=True,
    )
    dest = Path(output_dir) / slug
    _rm(dest)
    shutil.copytree(site_dir, dest)
    print(f"  [mkdocs] ok: {slug} → {dest}")


# ─── git + Hugo ───────────────────────────────────────────────────────────────

def _ensure_hugo(version: str) -> Path:
    """
    Return a path to the hugo extended binary for the requested version,
    downloading it into /opt/hugo/<version>/ if not already present.
    """
    target_dir = Path("/opt/hugo") / version
    binary = target_dir / "hugo"
    if binary.exists():
        return binary
    target_dir.mkdir(parents=True, exist_ok=True)
    url = (f"https://github.com/gohugoio/hugo/releases/download/"
           f"v{version}/hugo_extended_{version}_linux-amd64.tar.gz")
    print(f"  [hugo] fetching {version}")
    with urllib.request.urlopen(url) as r:
        data = r.read()
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
        tf.extract("hugo", target_dir, filter="data")
    binary.chmod(0o755)
    return binary


def mirror_git_hugo(entry, output_dir):
    slug = entry["slug"]
    repo = entry["repo"]
    branch = entry.get("branch", "main")
    hugo_ver = entry.get("hugo_version")
    pre_build = entry.get("pre_build")
    clone_flags = entry.get("clone_flags", "--depth=1").split()
    copy_paths = entry.get("copy_paths", [])

    work_dir = Path("/tmp") / f"hugo-{slug}"
    _rm(work_dir)
    subprocess.run(
        ["git", "clone", *clone_flags, "--branch", branch, repo, str(work_dir)],
        check=True,
    )

    hugo_bin = str(_ensure_hugo(hugo_ver)) if hugo_ver else "hugo"

    if pre_build:
        subprocess.run(pre_build, shell=True, cwd=work_dir, check=True)

    subprocess.run(
        [hugo_bin, "--minify", "--destination", "public"],
        cwd=work_dir,
        check=True,
    )

    public = work_dir / "public"
    dest_root = Path(output_dir) / slug
    dest_root.mkdir(parents=True, exist_ok=True)

    if copy_paths:
        for path in copy_paths:
            src = public / path
            if src.exists():
                shutil.copytree(src, dest_root / path, dirs_exist_ok=True)
                print(f"  [hugo] copied public/{path}/ → {dest_root}/{path}/")
            else:
                print(f"  [hugo] WARN: public/{path}/ not found after build")
        for f in ("index.html", "404.html"):
            if (public / f).exists():
                shutil.copy2(public / f, dest_root / f)
    else:
        shutil.copytree(public, dest_root, dirs_exist_ok=True)
    print(f"  [hugo] ok: {slug} → {dest_root}")


# ─── git + Next.js ────────────────────────────────────────────────────────────

def mirror_git_nextjs(entry, output_dir):
    slug = entry["slug"]
    repo = entry["repo"]
    branch = entry.get("branch", "main")
    build_cmd = entry.get("build_cmd", "npm ci && npm run build")
    out_dir = entry.get("out_dir", "out")

    work_dir = Path("/tmp") / f"nextjs-{slug}"
    _rm(work_dir)
    subprocess.run(
        ["git", "clone", "--depth=1", "--branch", branch, repo, str(work_dir)],
        check=True,
    )
    subprocess.run(build_cmd, shell=True, cwd=work_dir, check=True)
    dest = Path(output_dir) / slug
    _rm(dest)
    shutil.copytree(work_dir / out_dir, dest)
    print(f"  [nextjs] ok: {slug} → {dest}")


# ─── wget ─────────────────────────────────────────────────────────────────────

def mirror_wget(entry, output_dir):
    slug = entry["slug"]
    url = entry["url"]
    depth = entry.get("depth", 5)
    dest = Path(output_dir) / slug
    dest.mkdir(parents=True, exist_ok=True)
    # wget can fail with exit code 8 (server errors) but still download useful content.
    r = subprocess.run([
        "wget", "--mirror", "--convert-links", "--adjust-extension",
        "--page-requisites", "--no-parent", f"--level={depth}",
        "--wait=1", "--random-wait", "-e", "robots=off",
        f"--directory-prefix={dest}", url,
    ], capture_output=True)
    # Check if anything was actually downloaded (look for index.html in the domain dir).
    site_dirs = list(dest.glob("*/"))
    if not site_dirs:
        raise RuntimeError(f"wget downloaded nothing from {url} (exit {r.returncode})")
    print(f"  [wget] ok: {slug} → {dest} (exit {r.returncode})")


def mirror_git_sphinx(entry, output_dir):
    slug = entry["slug"]
    repo = entry["repo"]
    branch = entry.get("branch", "main")
    doc_dir = entry.get("doc_dir", "docs")

    work_dir = Path("/tmp") / f"sphinx-{slug}"
    _rm(work_dir)
    subprocess.run(
        ["git", "clone", "--depth=1", "--branch", branch, repo, str(work_dir)],
        check=True,
    )

    # Install the project + docs extras, best-effort.
    for spec in (".[docs]", ".[doc]", "."):
        r = subprocess.run(
            [sys.executable, "-m", "pip", "install", "--no-cache-dir", "-e", spec],
            cwd=work_dir, capture_output=True,
        )
        if r.returncode == 0:
            print(f"  [sphinx] installed as {spec}")
            break

    src = work_dir / doc_dir
    build = work_dir / "_build" / "html"
    # Sphinx exits non-zero on warnings/errors but may still produce usable output.
    subprocess.run(
        ["sphinx-build", "-b", "html", str(src), str(build)],
        check=False,
    )
    if not (build / "index.html").exists():
        raise RuntimeError(f"Sphinx build produced no output for {slug}")
    dest = Path(output_dir) / slug
    _rm(dest)
    shutil.copytree(build, dest)
    print(f"  [sphinx] ok: {slug} → {dest}")


HANDLERS = {
    "rtd":         mirror_rtd,
    "git-mkdocs":  mirror_git_mkdocs,
    "git-sphinx":  mirror_git_sphinx,
    "git-hugo":    mirror_git_hugo,
    "git-nextjs":  mirror_git_nextjs,
    "wget":        mirror_wget,
}


def mirror_one(slug, output_dir="docs"):
    """Mirror a single source by slug. Used by Docker builds."""
    sources = load_sources()
    for entry in sources:
        if entry.get("slug") == slug:
            t = entry.get("type", "rtd")
            handler = HANDLERS.get(t)
            if not handler:
                raise ValueError(f"unknown type '{t}' for {slug}")
            print(f"[{t}] mirroring {slug}…")
            Path(output_dir).mkdir(exist_ok=True)
            handler(entry, output_dir)
            return
    raise ValueError(f"slug '{slug}' not found in projects.yml")


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--slug", help="Mirror only this slug (for single-doc Docker builds)")
    args = parser.parse_args()

    if args.slug:
        mirror_one(args.slug)
    else:
        sources = load_sources()
        output_dir = "docs"
        Path(output_dir).mkdir(exist_ok=True)

        failures = []
        for entry in sources:
            t = entry.get("type", "rtd")
            handler = HANDLERS.get(t)
            slug = entry.get("slug", "?")
            if not handler:
                print(f"[skip] unknown type '{t}' for {slug}")
                continue
            print(f"[{t}] mirroring {slug}…")
            try:
                handler(entry, output_dir)
            except subprocess.CalledProcessError as e:
                print(f"[{t}] FAIL {slug}: {e}")
                failures.append(slug)
            except Exception as e:
                print(f"[{t}] FAIL {slug}: {e!r}")
                failures.append(slug)

        if failures:
            print(f"\nFAILED ({len(failures)}): {', '.join(failures)}", file=sys.stderr)
            sys.exit(1)
        else:
            print("\nAll sources mirrored.")
