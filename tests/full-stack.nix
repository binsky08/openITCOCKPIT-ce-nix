# Offline end-to-end test with the real upstream images, pinned in
# tests/images.json (refresh with `nix run .#update-test-images`).
#
# Large: ~6 GB of images in the Nix store and ~20 GB VM disk in $TMPDIR.
# Not part of `nix flake check`. Run it with
#
#   nix build .#test-full-stack -L
#
# or, if your Nix build directory is a small tmpfs, outside the sandbox:
#
#   nix build .#test-full-stack.driver
#   mkdir -p /var/tmp/oitc-test
#   XDG_RUNTIME_DIR=/var/tmp/oitc-test TMPDIR=/var/tmp/oitc-test ./result/bin/nixos-test-driver
#
# (outside the sandbox the driver keeps the VM disks in $XDG_RUNTIME_DIR,
# usually a small tmpfs)
{ pkgs, self }:
let
  inherit (pkgs) lib;

  domain = "openitcockpit.test";

  pinned = lib.importJSON ./images.json;

  cert = pkgs.runCommand "test-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=${domain} \
      -keyout $out/key.pem -out $out/cert.pem
  '';
in
pkgs.testers.runNixOSTest {
  name = "openitcockpit-full-stack";

  nodes.server =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.default ];

      virtualisation = {
        memorySize = 6144;
        cores = 4;
        diskSize = 30 * 1024;
      };

      networking.hosts."127.0.0.1" = [ domain ];
      environment.systemPackages = [ pkgs.jq ];

      services.openitcockpit = {
        enable = true;
        containers = lib.mapAttrs (_: img: {
          image = img.finalImageName;
          tag = img.finalImageTag;
          imageFile = pkgs.dockerTools.pullImage img;
        }) pinned;
        # Overlay on the real image (offline, so no apt here)
        customImage.commands = [
          # Upstream bug (image of 2026-10-22): CONTAINER_SETUP.sh pings MySQL
          # with mysqladmin and a client config containing `database=`, which
          # mysqladmin rejects, so fresh installations never finish. No-op once
          # fixed upstream. See README "Known upstream issues".
          ''sed -i 's|mysqladmin --defaults-extra-file="$INIFILE" ping|mysqladmin --defaults-extra-file="$DUMPINIFILE" ping|' /opt/openitc/frontend/CONTAINER_SETUP.sh''
          "echo nix > /etc/oitc-nix-custom"
        ];
        nginx = {
          enable = true;
          inherit domain;
          enableACME = false;
        };
      };

      services.nginx.virtualHosts.${domain} = {
        sslCertificate = "${cert}/cert.pem";
        sslCertificateKey = "${cert}/key.pem";
      };
    };

  testScript =
    { nodes, ... }:
    let
      units = map (n: "podman-${n}.service") (
        builtins.attrNames nodes.server.virtualisation.oci-containers.containers
      );
    in
    ''
      import json

      URL = "https://${domain}"
      CURL = "curl -sk --max-time 60 -c /tmp/jar -b /tmp/jar"

      start_all()

      with subtest("all containers start"):
          for unit in ${builtins.toJSON units}:
              server.wait_for_unit(unit, timeout=1800)

      with subtest("openITCOCKPIT finishes its first time setup"):
          server.wait_until_succeeds(
              "openitcockpit-podman logs openitcockpit-openitcockpit 2>&1 | grep -q 'openITCOCKPIT is now ready'",
              timeout=2400,
          )

      with subtest("custom image is in use"):
          server.succeed("openitcockpit-podman exec openitcockpit-openitcockpit test -f /etc/oitc-nix-custom")

      with subtest("login through the host nginx"):
          server.wait_until_succeeds(f"{CURL} -f {URL}/users/login.json", timeout=600)
          token = json.loads(server.succeed(f"{CURL} {URL}/users/login.json"))["_csrfToken"]
          res = server.succeed(
              f"{CURL} -H 'Content-Type: application/json' -H 'Accept: application/json'"
              f" -H 'X-CSRF-Token: {token}'"
              """ -d '{"email":"user@example.org","password":"asdf12"}'"""
              f" {URL}/users/login"
          )
          assert json.loads(res).get("success") is True, res
          res = server.succeed(f"{CURL} {URL}/users/login.json")
          assert json.loads(res).get("isLoggedIn") is True, res

      with subtest("websocket upgrade through the host nginx"):
          out = server.succeed(
              "curl -sk --http1.1 -i --max-time 5"
              " -H 'Connection: Upgrade' -H 'Upgrade: websocket'"
              " -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='"
              f" {URL}/push_notifications || true"
          )
          # The Go websocket backend authenticates on its own and answers 401
          # without credentials. Either way the upgrade request reached it
          # through both nginx hops (a proxy problem would be 404/502).
          # Frame forwarding itself is covered by vm-basic.
          status = out.splitlines()[0]
          assert " 101 " in status or (" 401 " in status and out.rstrip().endswith("Unauthorized")), out

      with subtest("monitoring backend is running"):
          server.wait_until_succeeds("openitcockpit-podman exec openitcockpit-naemon pgrep -x naemon", timeout=600)
          server.wait_until_succeeds(
              "openitcockpit-podman exec openitcockpit-mysql"
              " mysql -uopenitcockpit -popenitcockpit_password openitcockpit -e 'SELECT 1 FROM statusengine_users LIMIT 1'",
              timeout=600,
          )

      with subtest("everything still active"):
          for unit in ${builtins.toJSON units}:
              server.require_unit_state(unit, "active")
    '';
}
