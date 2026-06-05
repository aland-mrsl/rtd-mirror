#!/usr/bin/env python3
"""
Generate docker-bake.hcl + per-slug Dockerfiles + Dockerfile.nginx from projects.yml.

Run:  python3 scripts/generate-bake.py
Then: ./build.sh
"""

import argparse
import sys
from pathlib import Path
import yaml


# ─── Dockerfile generators per source type ────────────────────────────────────

def dockerfile_rtd(source):
    slug = source["slug"]
    version = source.get("version", "stable")
    formats = source.get("formats", ["htmlzip"])
    lines = [f"# RTD: {slug} @ {version}"]
    if "htmlzip" in formats:
        url = f"https://{slug}.readthedocs.io/_/downloads/en/{version}/htmlzip/"
        fallback = f"https://readthedocs.org/projects/{slug}/downloads/htmlzip/{version}/"
        lines += [
            f"RUN mkdir -p /build/docs/{slug} && \\",
            f"    curl -fL '{url}' -o /tmp/{slug}.zip || \\",
            f"    curl -fL '{fallback}' -o /tmp/{slug}.zip && \\",
            f"    unzip -q /tmp/{slug}.zip -d /tmp/{slug}-extract && \\",
            # RTD zips contain a single top-level dir; flatten it
            f"    src=$(find /tmp/{slug}-extract -maxdepth 1 -mindepth 1 -type d | head -1) && \\",
            f"    cp -r \"${{src:-.}}/\"* /build/docs/{slug}/ && \\",
            f"    rm -rf /tmp/{slug}.zip /tmp/{slug}-extract",
        ]
    if "pdf" in formats:
        pdf_url = f"https://{slug}.readthedocs.io/_/downloads/en/{version}/pdf/"
        lines += [
            f"RUN curl -fL '{pdf_url}' -o /build/docs/{slug}/{slug}.pdf || \\",
            f"    echo 'PDF not available for {slug}, skipping'",
        ]
    return lines


def dockerfile_git_sphinx(source):
    slug = source["slug"]
    repo = source["repo"]
    branch = source.get("branch", "main")
    doc_dir = source.get("doc_dir", "docs")
    lines = [
        f"# git-sphinx: {slug} @ {branch}",
        f"RUN git clone --depth=1 --branch {branch} {repo} /tmp/src-{slug}",
        f"RUN pip install --no-cache-dir -e '/tmp/src-{slug}[docs]' 2>/dev/null || \\",
        f"    pip install --no-cache-dir -e '/tmp/src-{slug}[doc]' 2>/dev/null || \\",
        f"    pip install --no-cache-dir -e /tmp/src-{slug} 2>/dev/null || true",
        f"RUN sphinx-build -b html /tmp/src-{slug}/{doc_dir} /build/docs/{slug}",
    ]
    return lines


def dockerfile_git_mkdocs(source):
    slug = source["slug"]
    repo = source["repo"]
    branch = source.get("branch", "main")
    config = source.get("config", "mkdocs.yml")
    lines = [
        f"# git-mkdocs: {slug} @ {branch}",
        f"RUN git clone --depth=1 --branch {branch} {repo} /tmp/src-{slug}",
        f"RUN pip install --no-cache-dir -e '/tmp/src-{slug}[docs]' 2>/dev/null || \\",
        f"    pip install --no-cache-dir -e /tmp/src-{slug} 2>/dev/null || true",
        f"RUN PYTHONPATH=/tmp/src-{slug}:/tmp/src-{slug}/docs \\",
        f"    mkdocs build \\",
        f"    --config-file /tmp/src-{slug}/{config} \\",
        f"    --site-dir /build/docs/{slug}",
    ]
    return lines


def dockerfile_git_hugo(source):
    slug = source["slug"]
    repo = source["repo"]
    branch = source.get("branch", "main")
    hugo_ver = source.get("hugo_version")
    pre_build = source.get("pre_build")
    clone_flags = source.get("clone_flags", "--depth=1")
    copy_paths = source.get("copy_paths", [])

    lines = [f"# git-hugo: {slug} @ {branch}"]
    lines.append(
        f"RUN git clone {clone_flags} --branch {branch} {repo} /tmp/src-{slug}"
    )

    # Download specific Hugo version if needed
    if hugo_ver:
        lines += [
            f"RUN mkdir -p /opt/hugo/{hugo_ver} && \\",
            f"    curl -fL \"https://github.com/gohugoio/hugo/releases/download/v{hugo_ver}/hugo_extended_{hugo_ver}_linux-amd64.tar.gz\" \\",
            f"    | tar xz -C /opt/hugo/{hugo_ver} hugo && \\",
            f"    chmod +x /opt/hugo/{hugo_ver}/hugo",
        ]
        hugo_bin = f"/opt/hugo/{hugo_ver}/hugo"
    else:
        hugo_bin = "hugo"

    if pre_build:
        lines.append(f"RUN cd /tmp/src-{slug} && {pre_build}")

    # Build
    lines.append(
        f"RUN {hugo_bin} --minify --destination /tmp/src-{slug}/public --source /tmp/src-{slug}"
    )

    # Copy output
    if copy_paths:
        copy_cmds = [f"mkdir -p /build/docs/{slug}"]
        for path in copy_paths:
            copy_cmds.append(
                f"cp -r /tmp/src-{slug}/public/{path} /build/docs/{slug}/ 2>/dev/null || true"
            )
        # Also copy root index/404
        copy_cmds.append(
            f"cp /tmp/src-{slug}/public/index.html /build/docs/{slug}/ 2>/dev/null || true"
        )
        copy_cmds.append(
            f"cp /tmp/src-{slug}/public/404.html /build/docs/{slug}/ 2>/dev/null || true"
        )
        lines.append("RUN " + " && \\\n    ".join(copy_cmds))
    else:
        lines.append(f"RUN cp -r /tmp/src-{slug}/public /build/docs/{slug}")

    return lines


def dockerfile_git_nextjs(source):
    slug = source["slug"]
    repo = source["repo"]
    branch = source.get("branch", "main")
    build_cmd = source.get("build_cmd", "npm ci && npm run build")
    out_dir = source.get("out_dir", "out")
    lines = [
        f"# git-nextjs: {slug} @ {branch}",
        f"RUN git clone --depth=1 --branch {branch} {repo} /tmp/src-{slug}",
        f"RUN cd /tmp/src-{slug} && {build_cmd}",
        f"RUN cp -r /tmp/src-{slug}/{out_dir} /build/docs/{slug}",
    ]
    return lines


def dockerfile_wget(source):
    slug = source["slug"]
    url = source["url"]
    depth = source.get("depth", 5)
    lines = [
        f"# wget: {slug} @ {url}",
        f"RUN mkdir -p /build/docs/{slug} && \\",
        f"    wget --mirror --convert-links --adjust-extension \\",
        f"    --page-requisites --no-parent --level={depth} \\",
        f"    --wait=1 --random-wait -e robots=off \\",
        f"    --directory-prefix=/build/docs/{slug} \\",
        f"    {url} || true",  # wget exit 8 = server errors but content may exist
    ]
    return lines


DOCKERFILE_GENERATORS = {
    "rtd":         dockerfile_rtd,
    "git-sphinx":  dockerfile_git_sphinx,
    "git-mkdocs":  dockerfile_git_mkdocs,
    "git-hugo":    dockerfile_git_hugo,
    "git-nextjs":  dockerfile_git_nextjs,
    "wget":        dockerfile_wget,
}


# ─── Main generators ──────────────────────────────────────────────────────────

def generate_doc_dockerfile(source, output_dir="."):
    slug = source["slug"]
    source_type = source.get("type", "rtd")
    gen = DOCKERFILE_GENERATORS.get(source_type)
    if not gen:
        print(f"  WARN: unknown type '{source_type}' for {slug}, skipping", file=sys.stderr)
        return None

    run_lines = gen(source)

    lines = [
        # 'base' is resolved by bake to target:base via contexts
        f"FROM base AS builder",
        f"",
        f"WORKDIR /build",
        f"",
    ]
    for line in run_lines:
        lines.append(line)

    lines += [
        "",
        "# Export only the built docs so this layer is small.",
        "FROM scratch",
        f"COPY --from=builder /build/docs/{slug} /",
    ]

    path = Path(output_dir) / f"Dockerfile.{slug}"
    path.write_text("\n".join(lines) + "\n")
    return str(path)


def generate_nginx_dockerfile(slugs, output_file="Dockerfile.nginx"):
    lines = [
        "FROM nginx:alpine",
        "",
        "COPY <<EOF /etc/nginx/conf.d/default.conf",
        "server {",
        "    listen 80;",
        "    server_name _;",
        "    root /usr/share/nginx/html;",
        "    index index.html;",
        "    location / { try_files $uri $uri/ =404; }",
        "}",
        "EOF",
        "",
        "COPY <<EOF /usr/share/nginx/html/index.html",
        "<html><head><title>Offline Documentation Portal</title>",
        "<style>body{font-family:sans-serif;margin:2em}</style></head>",
        "<body><h1>Documentation Mirror</h1><ul>",
    ]
    for slug in slugs:
        lines.append(f'<li><a href="/{slug}/">{slug}</a></li>')
    lines += [
        "</ul></body></html>",
        "EOF",
        "",
    ]
    for slug in slugs:
        lines.append(f"COPY --from={slug} / /{slug}/")
    lines += ["", "EXPOSE 80"]

    Path(output_file).write_text("\n".join(lines) + "\n")
    print(f"Generated {output_file} ({len(slugs)} docs: {', '.join(slugs)})")


def generate_bake(sources, slugs, output_file="docker-bake.hcl"):
    lines = [
        "# Generated by scripts/generate-bake.py — do not edit",
        "",
        'variable "REGISTRY" { default = "duncanal" }',
        "",
        'target "base" {',
        '  dockerfile = "Dockerfile.base"',
        '  tags       = ["${REGISTRY}/rtd-mirror-base:latest"]',
        "}",
        "",
    ]

    slug_set = set(slugs)
    for source in sources:
        slug = source.get("slug")
        if slug not in slug_set:
            continue
        source_type = source.get("type", "rtd")

        version_tag = "latest"
        if source_type == "rtd":
            version_tag = source.get("version", "stable")
        elif source_type in ("git-sphinx", "git-mkdocs", "git-hugo", "git-nextjs"):
            version_tag = source.get("branch", "main")

        lines += [
            f'target "{slug}" {{',
            f'  # docs version: {version_tag}',
            f'  dockerfile = "Dockerfile.{slug}"',
            f'  tags       = ["rtd-mirror-doc-{slug}:latest"]',
            f'  contexts   = {{ base = "target:base" }}',
            "}",
            "",
        ]

    # nginx uses docker-image:// contexts so it can reference already-built doc images
    lines += [
        'target "nginx" {',
        '  dockerfile = "Dockerfile.nginx"',
        '  tags       = ["${REGISTRY}/rtd-mirror:latest"]',
        '  contexts   = {',
    ]
    for slug in slugs:
        lines.append(f'    {slug} = "docker-image://rtd-mirror-doc-{slug}:latest"')
    lines += [
        "  }",
        "}",
        "",
        'group "default" { targets = ["nginx"] }',
        'group "docs"    { targets = [' + ", ".join(f'"{s}"' for s in slugs) + "] }",
    ]

    Path(output_file).write_text("\n".join(lines) + "\n")
    print(f"Generated {output_file} ({len(slugs)} doc targets)")


def load_sources(projects_file="projects.yml"):
    with open(projects_file) as f:
        return yaml.safe_load(f).get("sources", [])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate bake files from projects.yml")
    parser.add_argument("--projects", default="projects.yml")
    parser.add_argument(
        "--nginx-slugs", nargs="*",
        help="Slugs to include in nginx (defaults to all). Used by build.sh after partial builds.",
    )
    args = parser.parse_args()

    sources = load_sources(args.projects)
    all_slugs = [s["slug"] for s in sources if s.get("slug")]

    # Generate per-slug Dockerfiles
    for source in sources:
        if not source.get("slug"):
            continue
        path = generate_doc_dockerfile(source)
        if path:
            print(f"  Generated {path}")

    # Bake file always uses all slugs (build.sh decides what to attempt)
    generate_bake(sources, all_slugs)

    # Nginx dockerfile uses provided slugs (or all if not specified)
    nginx_slugs = args.nginx_slugs if args.nginx_slugs is not None else all_slugs
    generate_nginx_dockerfile(nginx_slugs)
