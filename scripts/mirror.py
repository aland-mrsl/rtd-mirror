# scripts/mirror.py  (updated structure — add handlers around your existing RTD logic)

import yaml, subprocess, shutil
from pathlib import Path

def load_sources(path="projects.yml"):
    with open(path) as f:
        return yaml.safe_load(f)["sources"]

def mirror_rtd(entry, output_dir):
    # Your existing RTD download logic, parameterised
    slug    = entry["slug"]
    version = entry.get("version", "stable")
    formats = entry.get("formats", ["htmlzip"])
    # ... your existing download + unzip code ...

def mirror_git_hugo(entry, output_dir):
    slug     = entry["slug"]
    repo     = entry["repo"]
    branch   = entry.get("branch", "main")
    hugo_ver = entry.get("hugo_version", "latest")
    copy_paths = entry.get("copy_paths", [])   # <-- new

    work_dir = Path("/tmp") / f"hugo-{slug}"
    subprocess.run(["git", "clone", "--depth=1", "--branch", branch,
                    repo, str(work_dir)], check=True)

    subprocess.run([
        "docker", "run", "--rm",
        "-v", f"{work_dir}:/src",
        f"hugomods/hugo:exts-{hugo_ver}",
        "hugo", "--minify", "--destination", "/src/public"
    ], check=True)

    public = work_dir / "public"
    dest_root = Path(output_dir) / slug
    dest_root.mkdir(parents=True, exist_ok=True)

    if copy_paths:
        # Selective copy — only the requested subdirs
        for path in copy_paths:
            src = public / path
            if src.exists():
                shutil.copytree(src, dest_root / path, dirs_exist_ok=True)
                print(f"  [hugo] copied public/{path}/ → {dest_root}/{path}/")
            else:
                print(f"  [hugo] WARNING: public/{path}/ not found after build")
        # Also copy the root index so the slug dir isn't a dead end
        for f in ["index.html", "404.html"]:
            if (public / f).exists():
                shutil.copy2(public / f, dest_root / f)
    else:
        # Copy everything (original behaviour)
        shutil.copytree(public, dest_root, dirs_exist_ok=True)

def mirror_git_nextjs(entry, output_dir):
    slug      = entry["slug"]
    repo      = entry["repo"]
    branch    = entry.get("branch", "main")
    build_cmd = entry.get("build_cmd", "npm ci && npm run build")
    out_dir   = entry.get("out_dir", "out")
    work_dir  = Path("/tmp") / f"nextjs-{slug}"

    subprocess.run(["git", "clone", "--depth=1", "--branch", branch, repo, str(work_dir)], check=True)
    subprocess.run(build_cmd, shell=True, cwd=work_dir, check=True)
    dest = Path(output_dir) / slug
    shutil.copytree(work_dir / out_dir, dest, dirs_exist_ok=True)

def mirror_wget(entry, output_dir):
    slug  = entry["slug"]
    url   = entry["url"]
    depth = entry.get("depth", 5)
    dest  = Path(output_dir) / slug
    subprocess.run([
        "wget", "--mirror", "--convert-links", "--adjust-extension",
        "--page-requisites", "--no-parent", f"--level={depth}",
        "--wait=1", "--random-wait", "-e", "robots=off",
        f"--directory-prefix={dest}", url
    ], check=True)

HANDLERS = {
    "rtd":         mirror_rtd,
    "git-hugo":    mirror_git_hugo,
    "git-nextjs":  mirror_git_nextjs,
    "wget":        mirror_wget,
}

if __name__ == "__main__":
    sources    = load_sources()
    output_dir = "docs"
    for entry in sources:
        t = entry.get("type", "rtd")
        handler = HANDLERS.get(t)
        if not handler:
            print(f"Unknown type '{t}' for {entry.get('slug')} — skipping")
            continue
        print(f"[{t}] Mirroring {entry['slug']}...")
        handler(entry, output_dir)