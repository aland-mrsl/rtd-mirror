# rtd-mirror

Offline documentation mirror served as a single nginx container. All docs are
built from source at image-build time; no internet access is required at
runtime.

## Hostnames

The container exposes one nginx server on port 80. Each doc site is a separate
virtual host. You must point every hostname below at the container's IP before
the browser can reach them.

| Hostname | Contents |
|---|---|
| `docs.internal` | Landing page — links to all sites |
| `kubernetes.docs.internal` | Kubernetes concepts, tasks, API reference |
| `docker-build.docs.internal` | Docker Build architecture, Bake, buildx CLI |
| `kopf.docs.internal` | Kopf Python operator framework |
| `valkey.docs.internal` | Valkey commands, topics, configuration, clients |
| `valkey-py.docs.internal` | valkey-py Python client API reference |

## /etc/hosts (single machine)

Add a block like the following, replacing `<CONTAINER_IP>` with the actual IP
of the running container (`docker inspect` or `docker run --network host`):

```
# rtd-mirror offline docs
<CONTAINER_IP>  docs.internal
<CONTAINER_IP>  kubernetes.docs.internal
<CONTAINER_IP>  docker-build.docs.internal
<CONTAINER_IP>  kopf.docs.internal
<CONTAINER_IP>  valkey.docs.internal
<CONTAINER_IP>  valkey-py.docs.internal
```

**Linux / macOS:** `/etc/hosts`  
**Windows:** `C:\Windows\System32\drivers\etc\hosts` (open as Administrator)

### Quick one-liner (Linux/macOS, container on localhost)

If you run the container with `-p 80:80` on the same machine:

```sh
sudo tee -a /etc/hosts <<'EOF'
# rtd-mirror offline docs
127.0.0.1  docs.internal
127.0.0.1  kubernetes.docs.internal
127.0.0.1  docker-build.docs.internal
127.0.0.1  kopf.docs.internal
127.0.0.1  valkey.docs.internal
127.0.0.1  valkey-py.docs.internal
EOF
```

## DNS (shared / team use)

If the container is reachable over a network, create A records in your internal
DNS zone instead of editing each machine's hosts file.

### dnsmasq

Add to `/etc/dnsmasq.conf` (or a file in `/etc/dnsmasq.d/`):

```
address=/docs.internal/<CONTAINER_IP>
address=/kubernetes.docs.internal/<CONTAINER_IP>
address=/docker-build.docs.internal/<CONTAINER_IP>
address=/kopf.docs.internal/<CONTAINER_IP>
address=/valkey.docs.internal/<CONTAINER_IP>
address=/valkey-py.docs.internal/<CONTAINER_IP>
```

Or with a wildcard if you want all `*.docs.internal` subdomains to resolve to
the same container:

```
address=/.docs.internal/<CONTAINER_IP>
```

### CoreDNS

```
docs.internal. {
    hosts {
        <CONTAINER_IP> docs.internal
        <CONTAINER_IP> kubernetes.docs.internal
        <CONTAINER_IP> docker-build.docs.internal
        <CONTAINER_IP> kopf.docs.internal
        <CONTAINER_IP> valkey.docs.internal
        <CONTAINER_IP> valkey-py.docs.internal
        fallthrough
    }
    forward . /etc/resolv.conf
}
```

### Kubernetes (in-cluster)

Create a `Service` of type `ExternalName` or use a `ConfigMap` patch for
CoreDNS' `NodeHosts` to add the entries above, then deploy the container as a
`Deployment` + `Service` and route via an `Ingress`.

## Testing without admin access (podman on a remote host)

This section covers the case where:
- The container runs on a separate **podman host** you can SSH into
- You cannot `sudo` on either machine, so port 80 and `/etc/hosts` are off limits
- The browser is on your **local machine**

The approach has two parts: an SSH tunnel to forward the port, and a PAC
(Proxy Auto-Configuration) file to route the virtual hostnames through it —
no admin needed for either.

### Step 1 — start the container on a high port

On the podman host (rootless podman can bind any port ≥ 1024):

```sh
podman run --rm -p 8080:80 duncanal/rtd-mirror:latest
```

### Step 2 — open an SSH tunnel

On your **local machine**, forward local port 8080 to the same port on the
podman host:

```sh
ssh -N -L 8080:127.0.0.1:8080 you@podman-host
```

Leave this terminal open. While it is running, `localhost:8080` on your local
machine reaches nginx inside the container.

`-N` keeps the tunnel open without launching a shell. Add `-f` to push it to
the background if you prefer.

### Step 3 — create a PAC file

A PAC file tells the browser to route matching hostnames through a specific
address without touching the OS resolver. Create the file anywhere in your home
directory — for example `~/docs.pac`:

```javascript
function FindProxyForURL(url, host) {
    if (host === "docs.internal" || dnsDomainIs(host, ".docs.internal")) {
        // Route all *.docs.internal traffic through the SSH tunnel endpoint.
        // nginx sees the original Host header so virtual-host routing works.
        return "PROXY 127.0.0.1:8080";
    }
    return "DIRECT";
}
```

### Step 4 — point the browser at the PAC file

#### Firefox

1. Open **Settings → General → Network Settings → Settings…**
2. Select **Automatic proxy configuration URL**
3. Enter `file:///home/you/docs.pac` (adjust path)
4. Click **OK** and reload

#### Chrome / Chromium

Pass the flag when launching (no admin required):

```sh
google-chrome --proxy-pac-url="file:///home/you/docs.pac"
```

Or on macOS:

```sh
open -a "Google Chrome" --args --proxy-pac-url="file:///Users/you/docs.pac"
```

#### Windows (Chrome or Edge, no admin)

In **Chrome/Edge → Settings → System → Open your computer's proxy settings**,
set **Use a setup script** to `file://C:/Users/you/docs.pac` — this requires
the local settings page, not the system-wide one, so no admin is needed.

Alternatively, launch Chrome directly:

```bat
chrome.exe --proxy-pac-url="file:///C:/Users/you/docs.pac"
```

### Step 5 — open the docs

Type this in the browser address bar:

```
http://docs.internal/
```

The PAC file intercepts the request, routes it to `localhost:8080` (the SSH
tunnel), and nginx serves the landing page. Every link on the landing page uses
the same `.docs.internal` hostnames, so they all route through the tunnel
automatically — no port numbers needed in the URL.

### Quick command-line check (no browser needed)

To verify the container is responding correctly before setting up the browser:

```sh
# Landing page
curl -s --resolve docs.internal:8080:127.0.0.1 http://docs.internal:8080/ | grep -o '<title>[^<]*</title>'

# Each virtual host
curl -s --resolve kubernetes.docs.internal:8080:127.0.0.1   http://kubernetes.docs.internal:8080/   | head -5
curl -s --resolve docker-build.docs.internal:8080:127.0.0.1 http://docker-build.docs.internal:8080/ | head -5
curl -s --resolve kopf.docs.internal:8080:127.0.0.1         http://kopf.docs.internal:8080/         | head -5
curl -s --resolve valkey.docs.internal:8080:127.0.0.1       http://valkey.docs.internal:8080/       | head -5
curl -s --resolve valkey-py.docs.internal:8080:127.0.0.1    http://valkey-py.docs.internal:8080/    | head -5
```

`--resolve` injects a fake DNS entry just for that curl invocation — no files
touched, no admin needed.

## Building

```sh
# Build all images and the combined nginx image
docker buildx bake

# Build only the individual doc images (skip the combined image)
docker buildx bake docs

# Build and run the combined image
docker buildx bake
docker run --rm -p 80:80 duncanal/rtd-mirror:latest
```

## Adding a new site

1. Add a new `Dockerfile.<name>` following the pattern of `Dockerfile.kopf`
   (Sphinx) or `Dockerfile.valkey` (Zola/multi-repo).
2. Add a `target "<name>"` block to `docker-bake.hcl` and wire it into the
   `nginx` contexts and `docs` group.
3. Add `COPY --from=<name>` lines to `Dockerfile.nginx`.
4. Add a `server { }` block to `nginx.conf`.
5. Add a card to `landing/index.html`.
6. Add the new hostname to this README and to `/etc/hosts` / DNS.
