variable "REGISTRY" { default = "duncanal" }
variable "HUGO_VERSION" {
  default = "0.144.2"
}

# ── Shared base image (Python + Hugo + Node) ───────────────────────────────────
# Used by Dockerfiles generated from projects.yml via scripts/generate-bake.py.
target "base" {
  dockerfile = "Dockerfile.base"
  tags       = ["${REGISTRY}/rtd-mirror-base:latest"]
}

# ── Standalone doc builds ──────────────────────────────────────────────────────

target "k8s" {
  # Kubernetes docs (Hugo) + Docker Build/Bake docs (HTTrack)
  dockerfile = "Dockerfile.k8"
  tags       = ["rtd-k8:latest"]
}

target "kopf" {
  # Kopf Python operator framework docs (Sphinx via uv)
  # docs version: main
  dockerfile = "Dockerfile.kopf"
  tags       = ["rtd-kopf:latest"]
}

target "valkey" {
  # Valkey website (Zola, 6 source repos) + valkey-py API docs (Sphinx)
  dockerfile = "Dockerfile.valkey"
  tags       = ["rtd-valkey:latest"]
}

# ── Combined nginx image ───────────────────────────────────────────────────────
# Assembles all standalone doc outputs into a single nginx container.
# Depends on k8s, kopf, and valkey; bake resolves them automatically via contexts.

target "nginx" {
  dockerfile = "Dockerfile.nginx"
  tags       = [
    "${REGISTRY}/rtd-mirror:latest",
    "ghcr.io/aland-mrsl/rtd-mirror:latest",
  ]
  contexts   = {
    "k8s"    = "target:k8s"
    "kopf"   = "target:kopf"
    "valkey" = "target:valkey"
  }
}

# ── Groups ─────────────────────────────────────────────────────────────────────

group "default" { targets = ["nginx"] }
group "docs"    { targets = ["k8s", "kopf", "valkey"] }
