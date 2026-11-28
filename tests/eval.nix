# Evaluation tests: no VM, only checks what the module generates.
{
  pkgs,
  self,
  nixpkgs,
}:
let
  inherit (pkgs) lib;

  mkSystem =
    extra:
    nixpkgs.lib.nixosSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        self.nixosModules.default
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          system.stateVersion = "26.05";
          services.openitcockpit.enable = true;
        }
        extra
      ];
    };

  # 1) Defaults
  defaults = (mkSystem { }).config;

  # 2) Customized setup
  customized =
    (mkSystem {
      services.openitcockpit = {
        environment = {
          MYSQL_PASSWORD = "s3cret";
          GW_TIMEZONE = "Europe/Berlin";
          OITC_ADMIN_FIRSTNAME = null;
        };
        extraEnv = "VICTORIA_METRICS_RETENTION_PERIOD=12";
        environmentFiles = [ "/run/secrets/openitcockpit.env" ];
        carbonCacheInstances = 3;
        modGearmanWorkerReplicas = 2;
        containers.redis.tag = "7.4";
        containers.grafana.tag = "sha256:a39434aba1a49f35c8814215ca4ea169e3f8116fe9e9e149bbbf50b7b50b6a2b";
        containers.postfix.enable = false;
        containers.postfix.environment.RELAYHOST = "mail.example.org";
        customImage.commands = [ "apt-get update && apt-get -y upgrade" ];
        autoUpdate.enable = true;
        autoUpdate.minFreeSpaceGiB = 0;
        nginx = {
          enable = true;
          domain = "monitoring.example.org";
        };
      };
      security.acme = {
        acceptTerms = true;
        defaults.email = "admin@example.org";
      };
    }).config;

  oci = cfg: cfg.virtualisation.oci-containers.containers;
  svc = cfg: cfg.systemd.services;

  checks = {
    "all compose services exist by default" =
      builtins.attrNames (oci defaults) == [
        "openitcockpit-carbon-c-relay"
        "openitcockpit-carbon-cache1"
        "openitcockpit-carbon-cache2"
        "openitcockpit-checkmk"
        "openitcockpit-gearmand"
        "openitcockpit-grafana"
        "openitcockpit-graphite-web"
        "openitcockpit-mod_gearman_worker"
        "openitcockpit-mysql"
        "openitcockpit-naemon"
        "openitcockpit-openitcockpit"
        "openitcockpit-postfix"
        "openitcockpit-prometheus"
        "openitcockpit-puppeteer"
        "openitcockpit-redis"
        "openitcockpit-statusengine-worker"
        "openitcockpit-victoria-metrics"
      ];

    "containers are rootless under the service user" = lib.all (c: c.podman.user == "openitcockpit") (
      builtins.attrValues (oci defaults)
    );

    "service user lingers and has subuids" =
      let
        u = defaults.users.users.openitcockpit;
      in
      u.linger && u.autoSubUidGidRange && u.uid == 2930 && u.home == "/var/lib/openitcockpit";

    "default image references" =
      (oci defaults).openitcockpit-mysql.image == "docker.io/library/mysql:lts"
      &&
        (oci defaults).openitcockpit-openitcockpit.image
        == "docker.io/openitcockpit/openitcockpit-ce:latest";

    "https port published on loopback only" =
      (oci defaults).openitcockpit-openitcockpit.ports == [ "127.0.0.1:8443:443" ];

    "dns aliases and grafana.docker" =
      lib.elem "--network-alias=grafana.docker" (oci defaults).openitcockpit-grafana.extraOptions
      && lib.elem "--network-alias=mysql" (oci defaults).openitcockpit-mysql.extraOptions;

    "init and ulimits like compose" =
      lib.elem "--init" (oci defaults).openitcockpit-naemon.extraOptions
      && lib.elem "--ulimit=nofile=65536:65536" (oci defaults).openitcockpit-mysql.extraOptions;

    "systemd dependencies follow depends_on" =
      (oci defaults).openitcockpit-prometheus.dependsOn == [
        "openitcockpit-victoria-metrics"
        "openitcockpit-openitcockpit"
      ];

    "missing images are pulled one after another before the containers start" =
      let
        script = (svc defaults).openitcockpit-image-pull.script;
        mysql = (svc defaults).podman-openitcockpit-mysql;
      in
      (svc defaults).openitcockpit-image-pull.serviceConfig.User == "openitcockpit"
      && lib.hasInfix "docker.io/library/mysql:lts" script
      && lib.hasInfix "docker.io/openitcockpit/openitcockpit-ce:latest" script
      && lib.elem "openitcockpit-image-pull.service" mysql.after
      && lib.elem "openitcockpit-image-pull.service" mysql.wants
      && !(lib.elem "openitcockpit-image-pull.service" mysql.requires);

    "initial pull covers tags, digests and the custom image base" =
      let
        script = (svc customized).openitcockpit-image-pull.script;
      in
      lib.hasInfix "docker.io/library/redis:7.4" script
      && lib.hasInfix "docker.io/openitcockpit/grafana@sha256:a39434aba1a49f35c8814215ca4ea169e3f8116fe9e9e149bbbf50b7b50b6a2b" script
      && lib.hasInfix "docker.io/openitcockpit/openitcockpit-ce:latest" script
      && !(lib.hasInfix customized.services.openitcockpit.customImage.ref script)
      && !(lib.hasInfix "boky/postfix" script)
      && lib.elem "openitcockpit-image-pull.service" (svc customized).openitcockpit-image-build.after;

    "no timer without autoUpdate" = !((defaults.systemd.timers or { }) ? openitcockpit-update);
    "update service always available" = (svc defaults) ? openitcockpit-update;
    "update checks free disk space by default" =
      lib.hasInfix "required=$(( 10 * 1024 * 1024 * 1024 ))" (svc defaults).openitcockpit-update.script;
    "disk space check can be disabled" =
      !(lib.hasInfix "Not enough free disk space" (svc customized).openitcockpit-update.script);
    "no nginx by default" = !defaults.services.nginx.enable;

    "tag override" = (oci customized).openitcockpit-redis.image == "docker.io/library/redis:7.4";
    "digest pin" =
      (oci customized).openitcockpit-grafana.image
      == "docker.io/openitcockpit/grafana@sha256:a39434aba1a49f35c8814215ca4ea169e3f8116fe9e9e149bbbf50b7b50b6a2b";
    "disabled container is gone" = !((oci customized) ? openitcockpit-postfix);
    "scaled carbon caches" =
      (oci customized) ? openitcockpit-carbon-cache3
      && (oci customized).openitcockpit-carbon-cache3.environment.CC_INSTANCE == "3"
      && (oci customized).openitcockpit-carbon-cache3.hostname == "carbon-cache3";
    "gearman replicas" =
      (oci customized) ? openitcockpit-mod_gearman_worker-1
      && (oci customized) ? openitcockpit-mod_gearman_worker-2;
    "secret env files come after the generated one" =
      (oci customized).openitcockpit-openitcockpit.environmentFiles == [
        customized.services.openitcockpit.envFile
        "/run/secrets/openitcockpit.env"
      ];
    "containers without env_file get none" =
      (oci customized).openitcockpit-redis.environmentFiles == [ ];
    "custom image is used and built" =
      (oci customized).openitcockpit-openitcockpit.image
      == customized.services.openitcockpit.customImage.ref
      && (oci customized).openitcockpit-openitcockpit.pull == "never"
      && lib.elem "openitcockpit-image-build.service" (svc customized)
      .podman-openitcockpit-openitcockpit.requires;
    "update timer" = customized.systemd.timers.openitcockpit-update.timerConfig.OnCalendar == "weekly";
    "nginx vhost" =
      let
        vh = customized.services.nginx.virtualHosts."monitoring.example.org";
      in
      vh.forceSSL
      && vh.enableACME
      && vh.locations."/".proxyPass == "https://127.0.0.1:8443"
      && vh.locations."/".proxyWebsockets;
  };

  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);

  # Force evaluation of the complete systems (assertions, warnings, units).
  toplevels = [
    (mkSystem { }).config.system.build.toplevel.drvPath
    customized.system.build.toplevel.drvPath
  ];
in
assert lib.assertMsg (failed == [ ]) "eval checks failed: ${lib.concatStringsSep ", " failed}";
pkgs.runCommand "openitcockpit-eval-checks"
  {
    defaultEnv = defaults.services.openitcockpit.envFile;
    customEnv = customized.services.openitcockpit.envFile;
    toplevels = builtins.toJSON (map builtins.unsafeDiscardStringContext toplevels);
  }
  ''
    set -e
    fail() { echo "FAIL: $*" >&2; exit 1; }

    # Defaults of the upstream openitcockpit.env
    grep -qx 'MYSQL_PASSWORD=openitcockpit_password' $defaultEnv || fail default mysql password
    grep -qx 'OITC_ADMIN_EMAIL=user@example.org' $defaultEnv || fail default admin
    grep -qx 'CCR_CARBON_CACHE_2=carbon-cache2:2003' $defaultEnv || fail carbon caches

    # Derived credentials follow MYSQL_PASSWORD
    grep -qx 'MYSQL_PASSWORD=s3cret' $customEnv || fail custom password
    grep -qx 'OITC_MYSQL_PASSWORD=s3cret' $customEnv || fail derived gearman password
    grep -qx 'STATUSENGINE_MYSQL_DSN=openitcockpit:s3cret@tcp(mysql:3306)/openitcockpit?parseTime=true' $customEnv \
      || fail derived statusengine dsn
    grep -qx 'CCR_CARBON_CACHE_3=carbon-cache3:2003' $customEnv || fail third carbon cache
    grep -qx 'GW_TIMEZONE=Europe/Berlin' $customEnv || fail extra variable
    grep -q 'OITC_ADMIN_FIRSTNAME' $customEnv && fail null removes key
    tail -n1 $customEnv | grep -qx 'VICTORIA_METRICS_RETENTION_PERIOD=12' || fail extraEnv appended last

    echo "$toplevels" > $out
  ''
