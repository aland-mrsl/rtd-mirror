#!/usr/bin/env python3
import subprocess
import pathlib
from concurrent.futures import ThreadPoolExecutor
from utils import get_htmlzip_url, download_file
import zipfile
import requests

ROOT = pathlib.Path("docs")
PROJECT_FILE = pathlib.Path("projects.txt")

def mirror_project(project):
    project = project.strip()
    if not project:
        return

    print(f"[+] Processing {project}")
    htmlzip_url = get_htmlzip_url(project)
    target_dir = ROOT / project if not project.startswith("http") else ROOT / project.split("//")[1].split("/")[0]

    # Try downloading HTML zip first
    if htmlzip_url:
        zip_file = target_dir / "html.zip"
        success = download_file(htmlzip_url, zip_file)
        if success:
            print(f"    [+] Extracting HTML zip for {project}")
            target_dir.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(zip_file, 'r') as zip_ref:
                zip_ref.extractall(target_dir)
            zip_file.unlink()
            return

    # Fallback to wget mirror
    if project.startswith("http"):
        url = project
    else:
        url = f"https://{project}.readthedocs.io/en/stable/"

    target_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        "wget",
        "--mirror",
        "--convert-links",
        "--adjust-extension",
        "--page-requisites",
        "--no-parent",
        "--wait=1",
        "--random-wait",
        "-e",
        "robots=off",
        "-P",
        str(target_dir),
        url,
    ]
    subprocess.run(cmd, check=False)

def main():
    ROOT.mkdir(exist_ok=True)
    projects = PROJECT_FILE.read_text().splitlines()
    with ThreadPoolExecutor(max_workers=5) as pool:
        pool.map(mirror_project, projects)

if __name__ == "__main__":
    main()
