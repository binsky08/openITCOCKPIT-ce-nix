# Offline NixOS VM test of the module mechanics.
#
# The real openITCOCKPIT stack needs ~6 GB of images, so this test uses a tiny
# Nix-built stand-in for the openitcockpit container that mimics its relevant
# behaviour (port 80 redirects to https, TLS on 443 with a self-signed
# certificate, a websocket endpoint at /push_notifications) plus the real redis
# image. Covered:
#   - rootless podman as the dedicated system user (linger, subuids, network,
#     named volumes, DNS aliases, --init)
#   - generated openitcockpit.env, extraEnv and environmentFiles precedence
#   - custom image (overlay) build
#   - host nginx reverse proxy with ACME (pebble) and websockets
#   - the update job (pull from a local registry, restart of changed containers)
#   - the initial image pull (before the containers, retries while the registry is down)
{ pkgs, self }:
let
  domain = "openitcockpit.test";
  nixpkgsPath = pkgs.path;

  redisImage = pkgs.dockerTools.pullImage {
    imageName = "library/redis";
    imageDigest = "sha256:1f88291b4c57bdf249f02eb085a8669889b2d2954e91d4de5118a5da6b78dd53";
    hash = "sha256-wWbX4jP+kdWnjZVVgQnce85/Haqmie7wRTXFRzDkxnI=";
    finalImageName = "library/redis";
    finalImageTag = "latest";
  };

  selfSigned = pkgs.runCommand "standin-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=standin \
      -keyout $out/key.pem -out $out/cert.pem
  '';

  standinNginxConf = pkgs.writeText "nginx.conf" ''
    daemon off;
    user nobody nobody;
    error_log stderr;
    pid /tmp/nginx.pid;
    events {}
    http {
      access_log off;
      client_body_temp_path /tmp/body;
      proxy_temp_path /tmp/proxy;
      fastcgi_temp_path /tmp/fastcgi;
      uwsgi_temp_path /tmp/uwsgi;
      scgi_temp_path /tmp/scgi;

      # Like the real image: port 80 only redirects
      server {
        listen 80;
        return 301 https://$host$request_uri;
      }

      server {
        listen 443 ssl;
        ssl_certificate ${selfSigned}/cert.pem;
        ssl_certificate_key ${selfSigned}/key.pem;

        location = / {
          default_type text/plain;
          return 200 "openITCOCKPIT stand-in host=$host proto=$http_x_forwarded_proto\n";
        }

        location /push_notifications {
          proxy_pass http://127.0.0.1:8083;
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection "upgrade";
        }
      }
    }
  '';

  standinStart = pkgs.writeScript "standin-start" ''
    #!${pkgs.busybox}/bin/sh
    ${pkgs.websocat}/bin/websocat -t ws-l:127.0.0.1:8083 mirror: &
    exec ${pkgs.nginx}/bin/nginx -e stderr -c ${standinNginxConf}
  '';

  standinImage = pkgs.dockerTools.buildLayeredImage {
    name = "localhost/oitc-standin";
    tag = "latest";
    contents = [
      pkgs.busybox
      pkgs.dockerTools.fakeNss
    ];
    extraCommands = ''
      mkdir -p tmp
      chmod 1777 tmp
    '';
    config.Cmd = [ "${standinStart}" ];
  };
in
pkgs.testers.runNixOSTest {
  name = "openitcockpit-basic";

  nodes.acme =
    { ... }:
    {
      imports = [ "${nixpkgsPath}/nixos/tests/common/acme/server" ];
    };

  nodes.server =
    { pkgs, ... }:
    {
      imports = [
        self.nixosModules.default
        "${nixpkgsPath}/nixos/tests/common/acme/client"
      ];

      virtualisation = {
        memorySize = 2048;
        diskSize = 4096;
        containers.registries.insecure = [ "localhost:5000" ];
      };

      networking.hosts."127.0.0.1" = [ domain ];

      environment.systemPackages = with pkgs; [
        websocat
        skopeo
        openssl
      ];

      environment.etc."openitcockpit-secret.env".text = ''
        MYSQL_PASSWORD=from-secret-file
        OITC_TEST_SECRET=topsecret
      '';

      services.openitcockpit = {
        enable = true;

        # Only what this test needs; everything else is covered by eval checks.
        containers = {
          gearmand.enable = false;
          mysql.enable = false;
          victoria-metrics.enable = false;
          carbon-c-relay.enable = false;
          carbon-cache.enable = false;
          graphite-web.enable = false;
          grafana.enable = false;
          naemon.enable = false;
          mod_gearman_worker.enable = false;
          statusengine-worker.enable = false;
          puppeteer.enable = false;
          checkmk.enable = false;
          prometheus.enable = false;
          postfix.enable = false;

          # Served by the registry below, to exercise the update job.
          redis.image = "localhost:5000/library/redis";

          openitcockpit = {
            image = "localhost/oitc-standin";
            imageFile = standinImage;
          };
        };

        environment = {
          MYSQL_PASSWORD = "nixos-test";
          GW_TIMEZONE = "first";
        };
        extraEnv = ''
          GW_TIMEZONE=second
        '';
        environmentFiles = [ "/etc/openitcockpit-secret.env" ];

        customImage.commands = [ "touch /oitc-custom-marker" ];
        # The test VM disk is only 4 GB
        autoUpdate.minFreeSpaceGiB = 1;

        nginx = {
          enable = true;
          inherit domain;
          openFirewall = true;
        };
      };

      # Local registry with the redis image, available before the images are pulled.
      services.dockerRegistry = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 5000;
      };
      systemd.services.seed-registry = {
        after = [ "docker-registry.service" ];
        requires = [ "docker-registry.service" ];
        # Ordering only (both start in the boot transaction): a dependency of the
        # pull unit would start the registry again when the retry subtest restarts
        # the pull unit with the registry stopped.
        before = [ "openitcockpit-image-pull.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [
          pkgs.skopeo
          pkgs.curl
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          until curl -sf http://localhost:5000/v2/; do sleep 1; done
          skopeo copy --dest-tls-verify=false \
            docker-archive:${redisImage} docker://localhost:5000/library/redis:latest
        '';
      };
    };

  testScript = ''
    def podman(cmd):
        return server.succeed(f"openitcockpit-podman {cmd}").strip()

    def env_of(container, var):
        return podman(f"exec openitcockpit-{container} printenv {var}")

    def journal_of_last_run(unit):
        return (
            "journalctl --no-pager _SYSTEMD_INVOCATION_ID="
            f"$(systemctl show -p InvocationID --value {unit})"
        )

    start_all()
    acme.wait_for_unit("pebble.service")

    with subtest("missing images are pulled before the containers start"):
        server.wait_for_unit("openitcockpit-image-pull.service")
        server.succeed(
            "journalctl -u openitcockpit-image-pull.service"
            " | grep -q 'Pulling localhost:5000/library/redis:latest (attempt 1)'"
        )
        # The stand-in comes from an imageFile and is not pulled
        server.fail("journalctl -u openitcockpit-image-pull.service | grep -q oitc-standin")

    with subtest("containers run rootless as the service user"):
        server.wait_for_unit("openitcockpit-podman-setup.service")
        server.wait_for_unit("podman-openitcockpit-redis.service")
        server.wait_for_unit("podman-openitcockpit-openitcockpit.service")
        server.wait_for_unit("openitcockpit.target")
        assert podman("info --format '{{.Host.Security.Rootless}}'") == "true"
        server.succeed("ps -eo user:20,args | grep -- 'nginx -e stderr' | grep -v grep | grep -q '^openitcockpit '")
        server.fail("ps -eo user:20,args | grep -- 'nginx -e stderr' | grep -v grep | grep -q '^root '")
        assert "oitc-backend" in podman("network ls --format '{{.Name}}'")
        assert "oitc-webroot" in podman("volume ls --format '{{.Name}}'")

    with subtest("network aliases and init like compose"):
        server.wait_until_succeeds("openitcockpit-podman exec openitcockpit-openitcockpit nslookup redis")
        assert podman("inspect openitcockpit-openitcockpit --format '{{.HostConfig.Init}}'") == "true"

    with subtest("generated env file and precedence"):
        assert env_of("openitcockpit", "OITC_ADMIN_EMAIL") == "user@example.org"
        assert env_of("openitcockpit", "OITC_MYSQL_PASSWORD") == "nixos-test"
        assert env_of("openitcockpit", "GW_TIMEZONE") == "second", "extraEnv must win"
        assert env_of("openitcockpit", "MYSQL_PASSWORD") == "from-secret-file", "environmentFiles must win"
        assert env_of("openitcockpit", "OITC_TEST_SECRET") == "topsecret"
        server.fail("openitcockpit-podman exec openitcockpit-redis printenv OITC_ADMIN_EMAIL")

    with subtest("custom image"):
        podman("exec openitcockpit-openitcockpit test -f /oitc-custom-marker")
        assert podman("inspect openitcockpit-openitcockpit --format '{{.ImageName}}'").startswith(
            "localhost/openitcockpit-ce-custom:"
        )

    with subtest("container port is published on loopback only"):
        server.succeed("curl -skf https://127.0.0.1:8443/ | grep -q stand-in")
        server.fail("ss -tlnH | grep ':8443 ' | grep -v '127.0.0.1'")

    with subtest("nginx reverse proxy with ACME certificate"):
        server.wait_for_unit("nginx.service")
        server.wait_until_succeeds(
            "echo | openssl s_client -connect ${domain}:443 -servername ${domain} 2>/dev/null"
            " | openssl x509 -noout -issuer | grep -i pebble",
            timeout=120,
        )
        out = server.succeed("curl -skf https://${domain}/")
        assert "host=${domain}" in out and "proto=https" in out, out
        server.succeed("curl -sI http://${domain}/ | grep -i '^location: https://${domain}/'")

    with subtest("websockets through nginx"):
        out = server.succeed(
            "(echo ping-oitc; sleep 2) | timeout 20 websocat -k wss://${domain}/push_notifications"
        )
        assert "ping-oitc" in out, out

    with subtest("update job pulls new images and restarts changed containers"):
        before = podman("inspect openitcockpit-redis --format '{{.Image}}'")
        oitc_before = podman("inspect openitcockpit-openitcockpit --format '{{.Image}}'")
        # Publish a new redis "release" in the registry
        server.succeed("mkdir -p /tmp/v2 && printf 'FROM localhost:5000/library/redis:latest\\nLABEL release=v2\\n' > /tmp/v2/Containerfile")
        podman("build --tag localhost/redis-v2 /tmp/v2")
        podman("push --tls-verify=false localhost/redis-v2 localhost:5000/library/redis:latest")
        podman("rmi localhost/redis-v2")

        server.succeed("systemctl start openitcockpit-update.service")
        server.wait_for_unit("podman-openitcockpit-redis.service")
        server.wait_until_succeeds(
            "openitcockpit-podman inspect openitcockpit-redis --format '{{index .Config.Labels \"release\"}}' | grep -qx v2"
        )
        assert podman("inspect openitcockpit-redis --format '{{.Image}}'") != before
        # the custom image is rebuilt without cache, so it changes as well
        server.wait_for_unit("podman-openitcockpit-openitcockpit.service")
        server.wait_until_succeeds(
            f"openitcockpit-podman inspect openitcockpit-openitcockpit --format '{{{{.Image}}}}' | grep -vqx {oitc_before}"
        )
        podman("exec openitcockpit-openitcockpit test -f /oitc-custom-marker")

        # A second run without upstream changes restarts redis no more
        redis_pid = podman("inspect openitcockpit-redis --format '{{.State.Pid}}'")
        server.succeed("systemctl start openitcockpit-update.service")
        assert podman("inspect openitcockpit-redis --format '{{.State.Pid}}'") == redis_pid

    with subtest("update job refuses to run without enough free disk space"):
        redis_pid = podman("inspect openitcockpit-redis --format '{{.State.Pid}}'")
        # Leave less than 1 GiB on the filesystem of the image store
        server.succeed(
            "avail=$(df --output=avail -B1 /var/lib/openitcockpit | tail -n1);"
            " fallocate -l $(( avail - 512 * 1024 * 1024 )) /var/lib/fill"
        )
        server.fail("systemctl start openitcockpit-update.service")
        last_run = (
            "journalctl --no-pager _SYSTEMD_INVOCATION_ID="
            "$(systemctl show -p InvocationID --value openitcockpit-update.service)"
        )
        server.succeed(f"{last_run} | grep -q 'Not enough free disk space'")
        server.fail(f"{last_run} | grep -q Pulling")
        assert podman("inspect openitcockpit-redis --format '{{.State.Pid}}'") == redis_pid
        server.succeed("rm /var/lib/fill")
        server.succeed("systemctl start openitcockpit-update.service")

    with subtest("initial pull retries until the registry is reachable"):
        server.succeed("systemctl stop openitcockpit.target docker-registry.service")
        podman("rmi --force localhost:5000/library/redis:latest")
        server.succeed("systemctl restart --no-block openitcockpit-image-pull.service")
        server.wait_until_succeeds(
            journal_of_last_run("openitcockpit-image-pull.service") + " | grep -q 'retrying in 10s'",
            timeout=120,
        )
        # The retry really happened against a stopped registry
        server.fail("systemctl is-active docker-registry.service")
        server.succeed("systemctl start docker-registry.service")
        server.wait_until_succeeds("systemctl is-active openitcockpit-image-pull.service", timeout=180)
        server.succeed(journal_of_last_run("openitcockpit-image-pull.service") + " | grep -q '(attempt 2)'")
        podman("image exists localhost:5000/library/redis:latest")
        server.succeed("systemctl start openitcockpit.target")
        server.wait_for_unit("podman-openitcockpit-openitcockpit.service")

    with subtest("everything still answers after the update"):
        server.wait_until_succeeds("curl -skf https://${domain}/ | grep -q stand-in")
  '';
}
