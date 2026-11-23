# openITCOCKPIT CE on NixOS

A NixOS module (flake) that runs the [openITCOCKPIT Community Edition container stack](https://github.com/openITCOCKPIT/openITCOCKPIT-ce-docker/blob/main/compose.yml) as `virtualisation.oci-containers` on **rootless podman**, owned by a dedicated system user.

Features:

- All compose services (16 at the time of writing). Container names are prefixed with `openitcockpit-`, and the compose service names are kept as DNS aliases, so the containers find each other exactly as they do under compose.
- Rootless podman under a configurable system user (default `openitcockpit`), with linger and subuid/subgid ranges. Images and volumes live in that user's home (`/var/lib/openitcockpit`).
- Per-image `tag` overrides, including `sha256:` digests. Optionally `imageFile` (e.g. `dockerTools.pullImage`) for fully Nix-managed images.
- An optional update timer that pulls the images, rebuilds the custom image and restarts only the containers whose image actually changed.
- An optional custom overlay image for the `openitcockpit` container (`FROM` upstream image plus your `RUN` commands, e.g. `apt-get -y upgrade`).
- A generated `openitcockpit.env`: upstream defaults, a Nix attrset, a raw text block, plus runtime env files for secrets (sops-nix, agenix, …).
- An optional virtual host in the host's nginx, with HTTPS via `security.acme` and websockets.

## Usage

```nix
# flake.nix of your system
{
  inputs.openitcockpit.url = "github:<you>/openITCOCKPIT-ce-nix";

  outputs = { nixpkgs, openitcockpit, ... }: {
    nixosConfigurations.monitoring = nixpkgs.lib.nixosSystem {
      modules = [
        openitcockpit.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

```nix
# configuration.nix
{
  services.openitcockpit = {
    enable = true;

    nginx = {
      enable = true;
      domain = "monitoring.example.org";
      openFirewall = true;          # 80 + 443, needed for ACME http-01
    };

    environment = {
      OITC_ADMIN_EMAIL = "admin@example.org";
      GW_TIMEZONE = "Europe/Berlin";
    };

    containers.postfix.environment.RELAYHOST = "mail.example.org";
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@example.org";
  };
}
```

Log in at `https://monitoring.example.org` as `user@example.org` / `asdf12` (unless you changed `OITC_ADMIN_*`), then change the password in the web UI.
The `OITC_ADMIN_*` values are only used for the very first setup.

## How it fits together

```
 client ──https──▶ host nginx (ACME, :443) ──https──▶ 127.0.0.1:8443 ──▶ openitcockpit container :443
                                                     (rootlessport)       (internal nginx, websockets,
                                                                           grafana auth proxy, php-fpm)
                    podman network "oitc-backend" (rootless, user openitcockpit)
          mysql, redis, gearmand, naemon, mod_gearman_worker, statusengine-worker, grafana, …
```

**Why TLS between host nginx and container:** the nginx inside the upstream image serves openITCOCKPIT **only on port 443**; its port 80 does nothing but `return 301 https://$host$request_uri`. Proxying plain HTTP to it would loop. The host nginx therefore talks HTTPS to the container's self-signed certificate on loopback (`proxy_ssl_verify off`). The container's own nginx config, with the websockets for `/push_notifications` and `/query_log`, the Grafana auth proxy and the 256M upload limit, keeps working unchanged. Only `services.openitcockpit.listen.{address,port}` is published (default `127.0.0.1:8443`).

systemd units:

| Unit | Purpose |
| --- | --- |
| `openitcockpit.target` | all containers (`systemctl restart openitcockpit.target`) |
| `podman-openitcockpit-<name>.service` | one per container, runs as the service user |
| `openitcockpit-podman-setup.service` | creates the podman network and named volumes |
| `openitcockpit-image-build.service` | builds the custom image (only if configured) |
| `openitcockpit-update.service` | update run; also usable manually when the timer is off |

`openitcockpit-podman` runs podman in the rootless context of the service user
(as root):

```sh
sudo openitcockpit-podman ps
sudo openitcockpit-podman logs -f openitcockpit-openitcockpit
sudo openitcockpit-podman exec -it openitcockpit-openitcockpit bash
```

## Configuration

### Images, tags, determinism

```nix
services.openitcockpit.containers = {
  redis.tag = "7.4";                                   # different tag
  grafana.tag = "sha256:a39434ab…";                   # pinned digest (image@sha256:…)
  mysql.image = "registry.example.org/mirror/mysql";   # different repository
  postfix.enable = false;                              # drop a container
  mysql.cmd = [ "mysqld" "--innodb-buffer-pool-size=1G" ];
  statusengine-worker.ports = [ "127.0.0.1:9105:9105" ];
  openitcockpit.extraVolumes = [ "/srv/import:/opt/openitc/frontend/plugins/ImportModule/webroot/files" ];
};
services.openitcockpit.carbonCacheInstances = 4;       # carbon-cache1..4 (+ CCR_CARBON_CACHE_n)
services.openitcockpit.modGearmanWorkerReplicas = 2;
```

There are two ways to operate the stack:

- **Deterministic:** pin each image with a `sha256:` digest, or provide an
  `imageFile`, and leave the update timer off. An image only changes when you
  change the configuration.
- **Convenient:** keep the `latest` tags and enable the update timer:

  ```nix
  services.openitcockpit.autoUpdate = {
    enable = true;
    interval = "Sun *-*-* 03:00:00";   # systemd OnCalendar, default "weekly"
    minFreeSpaceGiB = 10;              # default; 0 disables the check
  };
  ```

  Before doing anything, the update job checks that the filesystem of the podman image store (below `dataDir`) has at least `minFreeSpaceGiB` free. If not, it fails without pulling, building or restarting anything. The update job pulls every image of a container with `containers.<name>.autoUpdate = true` (the default), compares image IDs and restarts (`try-restart`) only the containers whose image changed. Dependent containers follow through systemd dependencies: a restarted mysql also restarts openitcockpit and statusengine-worker. If a pull fails, the job continues with the other images and exits non-zero at the end. Without the timer you can still run the job manually with `systemctl start openitcockpit-update`.

Without auto-updates, a `latest` image is pulled once (the first time the container starts) and stays until you run the update job.

### Custom openitcockpit image (security updates between releases)

`openitcockpit/openitcockpit-ce:latest` is only rebuilt for openITCOCKPIT releases. To pull in e.g. PHP security fixes earlier ([openITCOCKPIT-ce-docker#5](https://github.com/openITCOCKPIT/openITCOCKPIT-ce-docker/issues/5)):

```nix
services.openitcockpit.customImage.commands = [
  "apt-get update && apt-get -y upgrade && apt-get clean && rm -rf /var/lib/apt/lists/*"
];
```

This builds `localhost/openitcockpit-ce-custom:<hash>` `FROM` the configured openitcockpit image (`containers.openitcockpit.{image,tag}`), with one `RUN` per entry. `customImage.extraInstructions` takes raw Containerfile lines. The tag is a hash of the Containerfile, so a configuration change triggers a rebuild and a container restart on `nixos-rebuild switch`.

The update job rebuilds the image with `--no-cache`. If the openitcockpit container has `autoUpdate = true`, it also uses `--pull=always` to pick up a new base image. Each update run therefore produces a new image and restarts the openitcockpit container once.

### openitcockpit.env

The file is generated completely. It is passed to every container that uses `env_file` in the upstream compose.yml. The precedence, from lowest to highest:

1. Upstream defaults (`MYSQL_*`, `OITC_ADMIN_*`, Grafana passwords) set with `mkDefault`.
2. `services.openitcockpit.environment`: an attrset; `null` removes a key.
3. `services.openitcockpit.extraEnv`: raw lines appended to the file (the last occurrence of a key wins).
4. `services.openitcockpit.environmentFiles`: files read at container start. Use these for secrets.
5. `containers.<name>.environment` / `.environmentFiles` for a single container.

```nix
services.openitcockpit = {
  environment.VICTORIA_METRICS_RETENTION_PERIOD = 12;
  extraEnv = ''
    OITC_PHP_MEMORY_LIMIT=1024M
    NAEMON_MAX_CONCURRENT_CHECKS=500
  '';
};
```

Some images read the MySQL credentials under other names, with the default password baked into the image: mod_gearman_worker uses `OITC_MYSQL_*` and statusengine-worker uses `STATUSENGINE_MYSQL_DSN`. The module derives both from `MYSQL_*`, so changing `environment.MYSQL_PASSWORD` is enough.
**If you set `MYSQL_PASSWORD` in a secret file, also set the derived values there.**
`services.openitcockpit.envFile` gives you the generated file for reference.

#### Secrets with sops-nix

```nix
sops.secrets."openitcockpit/mysql" = { };
sops.secrets."openitcockpit/salt" = { };
sops.templates."openitcockpit.env" = {
  owner = "openitcockpit";   # podman reads env files as the rootless user!
  content = ''
    MYSQL_PASSWORD=${config.sops.placeholder."openitcockpit/mysql"}
    OITC_MYSQL_PASSWORD=${config.sops.placeholder."openitcockpit/mysql"}
    STATUSENGINE_MYSQL_DSN=openitcockpit:${config.sops.placeholder."openitcockpit/mysql"}@tcp(mysql:3306)/openitcockpit?parseTime=true
    OITC_SECURITY_SALT=${config.sops.placeholder."openitcockpit/salt"}
  '';
};
services.openitcockpit.environmentFiles = [ config.sops.templates."openitcockpit.env".path ];
```

Notes on credentials:

- The MySQL credentials are only applied when the database volume is first initialized. Changing them later requires changing them in MySQL as well.
- `OITC_SECURITY_SALT` is the CakePHP security salt. The image ships a publicly known default, so consider setting your own before the first start.
- MySQL, Redis and the other services are only reachable on the internal podman network, never from the host or the outside.

### nginx

| Option | Default |
| --- | --- |
| `nginx.domain` | (required) |
| `nginx.enableACME` | `true` unless `useACMEHost` is set |
| `nginx.useACMEHost` | `null` (e.g. an existing wildcard certificate) |
| `nginx.openFirewall` | `false` |

Everything else can be added to `services.nginx.virtualHosts."<domain>"` directly (IP allow lists, basic auth, extra headers, …). NixOS merges it with the module's definitions.

Without the nginx integration, publish the container directly, e.g. `listen = { address = "0.0.0.0"; port = 8443; }` and open the port. Ports below 1024 are not possible for rootless podman unless you lower `net.ipv4.ip_unprivileged_port_start`.

### User, paths

| Option | Default |
| --- | --- |
| `user` / `group` | `openitcockpit` |
| `uid` | `2930`. It must be static because the units depend on `/run/user/<uid>` |
| `dataDir` | `/var/lib/openitcockpit` (home of the user, podman storage) |
| `networkName` | `oitc-backend` |

Named volumes are at `/var/lib/openitcockpit/.local/share/containers/storage/volumes/<name>/_data`.
Back up at least `mysql-data`, `oitc-*`, `naemon-*`, `grafana-data`, `graphite-data` and `checkmk-*`. The `oitc-backups` volume contains the automatic MySQL dumps of openITCOCKPIT.

### Differences from compose

- Podman does not grant `NET_RAW`, `MKNOD` and `AUDIT_WRITE` by default, while Docker does, and the stack was built for Docker. The module adds them back (needed e.g. for `check_icmp` and cron).
- Restart handling is done by systemd (`Restart=on-failure`), and dependencies follow `depends_on`.
- The container's port 80 is not published (see above).
- `carbonCacheInstances` must be at least 2, because carbon-c-relay always falls back to `carbon-cache1` and `carbon-cache2`.

### Known upstream issues

**Fresh installations hang in "Waiting for MySQL to become available…"** (`openitcockpit/openitcockpit-ce:latest` of 2026-10-22, also under Docker).
`CONTAINER_SETUP.sh` pings MySQL with `mysqladmin --defaults-extra-file=/opt/openitc/etc/mysql/mysql.cnf`. That file contains `database = …` in its `[client]` section, which `mysqladmin` rejects (`unknown variable 'database=openitcockpit'`), so the container restarts forever.
Existing installations are not affected, because the script only runs once. Workaround with the custom image; it is a no-op once fixed upstream:

```nix
services.openitcockpit.customImage.commands = [
  ''sed -i 's|mysqladmin --defaults-extra-file="$INIFILE" ping|mysqladmin --defaults-extra-file="$DUMPINIFILE" ping|' /opt/openitc/frontend/CONTAINER_SETUP.sh''
];
```

### What this module does not do (scope)

- No Docker backend. `virtualisation.oci-containers.backend` must be `podman`.
- No building of the upstream images from source. They are not published (see #5); only an overlay on top of them is supported.
- No backups or restore, and no migration of an existing Docker installation. The volume layout is the same, though, so copying the volume contents works.
- No openITCOCKPIT application configuration (hosts, users, …). That happens in the web UI or the API.
- No Enterprise Edition and no other upstream compose variants (`_compose.nightly.yml`).

## Development and tests

```sh
nix develop                     # nixfmt, nixd, statix, deadnix, skopeo, nix-prefetch-docker
nix fmt
nix flake check                 # eval checks + offline VM test (KVM required)
nix run .#vm                    # interactive VM with the real stack, see below
```

The tests run in three tiers. All of them work on any Linux machine with Nix
and KVM; NixOS is not required on the host.

1. **`checks.eval`** (seconds): evaluates the module with default and customized settings, asserts on the generated containers, units and nginx vhost, and checks the env file contents.
2. **`checks.vm-basic`** (a few minutes, offline): a NixOS VM test with [pebble](https://github.com/letsencrypt/pebble) as ACME server. It uses the real redis image and a tiny Nix-built stand-in for the openitcockpit container that behaves like it at the HTTP level (80 → 301, TLS on 443, websocket at `/push_notifications`). It covers rootless operation, DNS aliases, `--init`, env precedence, the custom image build, nginx + ACME + websockets, and the update job against a local registry, including restarts only for changed images.
3. **`packages.test-full-stack`** (large, offline): all 16 real upstream images, pinned in `tests/images.json`. It waits for the first-time setup, logs in through the host nginx using the JSON API, checks the websocket upgrade, naemon and statusengine. It is not part of `nix flake check`. Refresh the pins with `nix run .#update-test-images`.

   ```sh
   nix build .#test-full-stack -L
   # If the Nix build dir is a small tmpfs (/tmp), run it outside the sandbox:
   nix build .#test-full-stack.driver && mkdir -p /var/tmp/oitc-test && XDG_RUNTIME_DIR=/var/tmp/oitc-test TMPDIR=/var/tmp/oitc-test ./result/bin/nixos-test-driver
   ```

**KVM inside the Nix sandbox (non-NixOS hosts):** builds run as the `nixbld*` users, which often cannot open `/dev/kvm` (e.g. Ubuntu: `0660 root:kvm`). QEMU then silently falls back to software emulation (`failed to initialize kvm: Permission denied` in the log), and the tests become far too slow. Either grant access:

```sh
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' \
  | sudo tee /etc/udev/rules.d/65-kvm.rules
sudo udevadm control --reload && sudo udevadm trigger --name-match=kvm
```

or run the test driver outside the sandbox as your user (who is in the `kvm` group):

```sh
nix build .#checks.x86_64-linux.vm-basic.driver
mkdir -p /var/tmp/oitc-test && XDG_RUNTIME_DIR=/var/tmp/oitc-test TMPDIR=/var/tmp/oitc-test ./result/bin/nixos-test-driver
```

Every VM test can also be driven interactively: `nix run .#checks.x86_64-linux.vm-basic.driverInteractive`, then `start_all()` and `server.shell_interact()`.

**Interactive VM** (`nix run .#vm`): a QEMU VM (NixOS `qemu-vm` module) with internet access. It pulls the real images, which allows testing auto-updates and `apt-get upgrade` overlays.

- UI: <https://openitcockpit.localhost:8443> (self-signed certificate)
- SSH: `ssh -p 2222 root@localhost` (password `root`)
- The VM disk is `./oitc.qcow2`; delete it for a fresh install.

Because of the forwarded port, Grafana iframes inside the dev VM may point to port 443. That only affects the dev VM.

The tests use the plain NixOS test framework and `qemu-vm` instead of microvm.nix. They need no extra flake input, the same machinery powers the nixpkgs tests, and VM tests run reproducibly in the Nix sandbox and in CI (e.g. GitHub Actions runners with KVM).
