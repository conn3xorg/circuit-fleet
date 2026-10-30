# Facts give each host's distribution, for the os check and for hosts that
# don't set os, and its architecture, since Fleet's release has one Linux
# build, for amd64.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
    postcondition {
      condition     = self.arch == "x86_64"
      error_message = "Host ${each.key} is ${self.arch}. Fleet's release has a Linux build for amd64 only."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }

  apt_hosts = { for name, h in var.hosts : name => h if contains(["debian", "ubuntu"], local.os[name]) }

  dir       = "/opt/fleet"
  binary    = "${local.dir}/fleet_v${var.fleet_version}_linux/fleet"
  conf_dir  = "/etc/fleet"
  config    = "${local.conf_dir}/fleet.yml"
  env_file  = "${local.conf_dir}/fleet.env"
  pass_file = "${local.conf_dir}/mysql_password"
  state_dir = "/var/lib/fleet"
  log_dir   = "/var/log/fleet"

  # Without files of your own, the circuit makes a self-signed certificate.
  self_signed = var.tls && var.tls_cert_file == null
  cert        = coalesce(var.tls_cert_file, "${local.conf_dir}/fleet.crt")
  key         = coalesce(var.tls_key_file, "${local.conf_dir}/fleet.key")
  san         = can(cidrhost("${var.server_name}/32", 0)) ? "IP:${var.server_name}" : "DNS:${var.server_name}"

  fleet_yml = yamlencode({
    mysql = {
      address       = var.database_address
      database      = var.database_name
      username      = var.database_user
      password_path = local.pass_file
    }
    redis = {
      address = var.redis_address
    }
    server = merge(
      { address = "${var.listen_address}:${var.port}", tls = var.tls },
      var.tls ? { cert = local.cert, key = local.key } : {},
    )
    logging = {
      json = true
    }
    # Fleet's default keeps these in /tmp, which doesn't last a reboot.
    filesystem = {
      result_log_file     = "${local.log_dir}/osquery_result.log"
      status_log_file     = "${local.log_dir}/osquery_status.log"
      audit_log_file      = "${local.log_dir}/audit.log"
      enable_log_rotation = true
    }
    vulnerabilities = {
      databases_path = "${local.state_dir}/vulndbs"
    }
  })
}

# The download step needs curl or wget. A small Debian or Ubuntu host may
# have neither; the Red Hat family ships curl-minimal, which is enough.
circuit "curl" {
  hosts = local.apt_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "package" {
    package {
      name = "curl"
    }
  }
}

circuit "fleet" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "openssl" {
    for_each = local.self_signed ? ["openssl"] : []
    package {
      name = item.value
    }
  }

  step "user" {
    user {
      name   = "fleet"
      system = true
      home   = local.state_dir
      shell  = "/usr/sbin/nologin"
    }
  }

  step "dir" {
    directory {
      path = local.dir
      mode = "0755"
    }
  }

  step "conf_dir" {
    directory {
      path  = local.conf_dir
      owner = "root"
      group = "fleet"
      mode  = "0750"
    }
    depends_on = [conn3x_user.fleet__user]
  }

  step "state_dir" {
    directory {
      path  = local.state_dir
      owner = "fleet"
      group = "fleet"
      mode  = "0750"
    }
    depends_on = [conn3x_user.fleet__user]
  }

  step "log_dir" {
    directory {
      path  = local.log_dir
      owner = "fleet"
      group = "fleet"
      mode  = "0750"
    }
    depends_on = [conn3x_user.fleet__user]
  }

  # The download step checks the tarball against this checksum.
  step "download" {
    download {
      url    = "https://github.com/fleetdm/fleet/releases/download/fleet-v${var.fleet_version}/fleet_v${var.fleet_version}_linux.tar.gz"
      sha256 = var.fleet_sha256
      dest   = "${local.dir}/fleet_v${var.fleet_version}_linux.tar.gz"
    }
    depends_on = [conn3x_directory.fleet__dir, conn3x_package.curl__package]
  }

  step "unpack" {
    archive {
      src     = "${local.dir}/fleet_v${var.fleet_version}_linux.tar.gz"
      dest    = local.dir
      creates = local.binary
    }
  }

  # A new server_name needs a new certificate, so it's a trigger rather
  # than a creates. The key is only ever on the host.
  step "certificate" {
    for_each = local.self_signed ? ["self-signed"] : []
    command {
      command = "openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes -keyout ${local.key} -out ${local.cert} -subj '/CN=${var.server_name}' -addext 'subjectAltName=${local.san}' 2>/dev/null && chown root:fleet ${local.key} ${local.cert} && chmod 640 ${local.key} && chmod 644 ${local.cert}"
      triggers = {
        server_name = var.server_name
      }
    }
    depends_on = [conn3x_directory.fleet__conf_dir, conn3x_package.fleet__openssl]
  }

  # Fleet can read this one password from a file, so it stays out of the
  # environment.
  step "database_password" {
    file {
      path       = local.pass_file
      content_wo = var.database_password
      owner      = "root"
      group      = "fleet"
      mode       = "0640"
    }
    depends_on = [conn3x_directory.fleet__conf_dir]
  }

  # Fleet only takes these two from its config file or the environment. In
  # a double-quoted value, systemd treats only \ and " specially.
  step "environment" {
    file {
      path       = local.env_file
      content_wo = <<-EOT
        FLEET_REDIS_PASSWORD="${replace(replace(var.redis_password, "\\", "\\\\"), "\"", "\\\"")}"
        FLEET_SERVER_PRIVATE_KEY="${replace(replace(var.server_private_key, "\\", "\\\\"), "\"", "\\\"")}"
      EOT
      owner      = "root"
      group      = "root"
      mode       = "0600"
    }
    depends_on = [conn3x_directory.fleet__conf_dir]
  }

  step "config" {
    file {
      path    = local.config
      content = local.fleet_yml
      owner   = "root"
      group   = "fleet"
      mode    = "0640"
    }
    depends_on = [conn3x_directory.fleet__conf_dir]
  }

  # The database units only exist when they're on this host. Ordering on one
  # that doesn't exist does nothing, and Restart covers a remote database
  # that isn't up yet.
  step "unit" {
    file {
      path    = "/etc/systemd/system/fleet.service"
      content = <<-EOT
        [Unit]
        Description=Fleet
        After=network-online.target mysql.service mysqld.service valkey.service valkey-server.service
        Wants=network-online.target

        [Service]
        User=fleet
        Group=fleet
        EnvironmentFile=${local.env_file}
        ExecStart=${local.binary} serve --config ${local.config}
        Restart=always
        RestartSec=5
        NoNewPrivileges=true
        LimitNOFILE=65536

        [Install]
        WantedBy=multi-user.target
      EOT
    }
  }

  # Fleet's upgrade guide runs migrations with every server stopped. On the
  # first apply this creates the schema. A new release gets here through
  # its own trigger.
  step "prepare" {
    command {
      command = "systemctl stop fleet 2>/dev/null || true; ${local.binary} prepare db --no-prompt --config ${local.config}"
      triggers = {
        version = var.fleet_version
      }
    }
    depends_on = [conn3x_archive.fleet__unpack, conn3x_file.fleet__config, conn3x_file.fleet__database_password]
  }

  # It runs here rather than in a handler so the wait below finds the server
  # running with the new settings.
  step "restart" {
    command {
      command = "systemctl daemon-reload && systemctl restart fleet"
      triggers = {
        prepare     = conn3x_command.fleet__prepare[each.key].revision
        unit        = conn3x_file.fleet__unit[each.key].revision
        config      = conn3x_file.fleet__config[each.key].revision
        environment = conn3x_file.fleet__environment[each.key].revision
        password    = conn3x_file.fleet__database_password[each.key].revision
        certificate = try(conn3x_command.fleet__certificate["${each.key}/self-signed"].revision, "")
      }
    }
  }

  step "running" {
    service {
      name    = "fleet"
      state   = "started"
      enabled = true
    }
  }

  step "ready" {
    wait_for {
      port    = var.port
      timeout = "2m"
    }
  }
}
