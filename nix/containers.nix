# Static description of the openITCOCKPIT CE container stack.
#
# Mirrors https://github.com/openITCOCKPIT/openITCOCKPIT-ce-docker/blob/main/compose.yml
# Initially build based on the commit 124a03c3b4a61bf907667b0616ce77ffd88cf8e7.
#
# Keys are the compose service names; they are also used as DNS aliases on the
# backend network, so the containers find each other exactly like under compose.
#
# Fields:
#   image        repository (fully qualified, rootless podman cannot prompt for short names)
#   tag          default tag
#   envFile      whether the generated openitcockpit.env is passed (compose `env_file`)
#   init         run with an init process (compose `init: true`)
#   nofile       raise the open files limit to 65536 (compose `ulimits.nofile`)
#   volumes      named volumes / mounts
#   dependsOn    compose `depends_on` (service names)
#   cmd          command override (compose `command`)
#   environment  container specific environment (compose `environment`)
#   aliases      additional DNS aliases on the backend network
#   instances    "carbon" / "gearman" for services that can be scaled (see module)
{
  gearmand = {
    image = "docker.io/openitcockpit/gearmand";
    nofile = true;
  };

  redis = {
    image = "docker.io/library/redis";
  };

  mysql = {
    image = "docker.io/library/mysql";
    tag = "lts";
    envFile = true;
    nofile = true;
    volumes = [ "mysql-data:/var/lib/mysql" ];
    cmd = [
      "mysqld"
      "--sql_mode="
      "--innodb-buffer-pool-size=256M"
      "--innodb-flush-log-at-trx-commit=2"
      "--innodb-file-per-table=1"
      "--innodb-flush-method=O_DIRECT"
      "--character-set-server=utf8mb4"
      "--collation-server=utf8mb4_general_ci"
      "--skip-log-bin"
    ];
  };

  victoria-metrics = {
    image = "docker.io/openitcockpit/victoria-metrics";
    envFile = true;
  };

  carbon-c-relay = {
    image = "docker.io/openitcockpit/carbon-c-relay";
    envFile = true;
  };

  # Expanded to carbon-cache1 .. carbon-cacheN by the module.
  carbon-cache = {
    image = "docker.io/openitcockpit/carbon-cache";
    envFile = true;
    nofile = true;
    instances = "carbon";
    volumes = [ "graphite-data:/var/lib/graphite/whisper" ];
  };

  graphite-web = {
    image = "docker.io/openitcockpit/graphite-web";
    volumes = [ "graphite-data:/var/lib/graphite/whisper" ];
  };

  grafana = {
    image = "docker.io/openitcockpit/grafana";
    envFile = true;
    aliases = [ "grafana.docker" ];
    volumes = [ "grafana-data:/var/lib/grafana" ];
  };

  naemon = {
    image = "docker.io/openitcockpit/naemon";
    init = true;
    envFile = true;
    dependsOn = [ "gearmand" ];
    volumes = [
      "naemon-var:/opt/openitc/nagios/var"
      "naemon-var-local:/opt/openitc/nagios/var_local"
      "naemon-config:/opt/openitc/nagios/etc/config:ro"
    ];
  };

  # Expanded to N replicas by the module.
  mod_gearman_worker = {
    image = "docker.io/openitcockpit/mod_gearman_worker";
    init = true;
    envFile = true;
    instances = "gearman";
    environment.IS_WORKHORSE_CONTAINER = "1";
    dependsOn = [ "gearmand" ];
    volumes = [
      "naemon-var:/opt/openitc/nagios/var"
      "oitc-agent-cert:/opt/openitc/agent:ro"
      "oitc-agent-etc:/opt/openitc/receiver/etc:ro"
      "oitc-frontend-src:/opt/openitc/frontend:ro"
    ];
  };

  statusengine-worker = {
    image = "docker.io/openitcockpit/statusengine-worker";
    init = true;
    envFile = true;
    dependsOn = [
      "mysql"
      "gearmand"
    ];
  };

  openitcockpit = {
    image = "docker.io/openitcockpit/openitcockpit-ce";
    init = true;
    envFile = true;
    dependsOn = [
      "redis"
      "mysql"
      "gearmand"
    ];
    volumes = [
      "naemon-config:/opt/openitc/nagios/etc/config"
      "naemon-var:/opt/openitc/nagios/var"
      "oitc-frontend-src:/opt/openitc/src_sharing/frontend"
      "oitc-webroot:/opt/openitc/frontend/webroot"
      "oitc-maps:/opt/openitc/frontend/plugins/MapModule/webroot/img"
      "oitc-agent-cert:/opt/openitc/agent"
      "oitc-agent-etc:/opt/openitc/receiver/etc"
      "oitc-var:/opt/openitc/var"
      "oitc-backups:/opt/openitc/nagios/backup"
      "oitc-styles:/opt/openitc/frontend/plugins/DesignModule/webroot/css"
      "checkmk-agents:/opt/openitc/check_mk/agents:ro"
      "checkmk-etc:/opt/openitc/check_mk/etc/check_mk"
      "checkmk-var:/opt/openitc/check_mk/var/check_mk"
      "prometheus-config:/opt/openitc/prometheus"
    ];
  };

  puppeteer = {
    image = "docker.io/openitcockpit/puppeteer";
    init = true;
    envFile = true;
    volumes = [ "oitc-webroot:/opt/openitc/frontend/webroot:ro" ];
  };

  checkmk = {
    image = "docker.io/openitcockpit/checkmk";
    init = true;
    envFile = true;
    volumes = [
      "naemon-var:/opt/openitc/nagios/var"
      "checkmk-agents:/opt/omd/sites/nagios/version/share/check_mk/agents"
      "checkmk-etc:/omd/sites/nagios/etc/check_mk:ro"
      "checkmk-var:/omd/sites/nagios/var/check_mk"
    ];
  };

  prometheus = {
    image = "docker.io/openitcockpit/prometheus";
    init = true;
    envFile = true;
    dependsOn = [
      "victoria-metrics"
      "openitcockpit"
    ];
    volumes = [
      "prometheus-var:/opt/openitc/var"
      "prometheus-config:/opt/openitc/prometheus:ro"
    ];
  };

  postfix = {
    image = "docker.io/boky/postfix";
    environment.ALLOW_EMPTY_SENDER_DOMAINS = "true";
  };
}
