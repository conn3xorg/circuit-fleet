# circuit-fleet

[![Conn3x grade](https://conn3x.org/circuits/fleet/grade.svg)](https://conn3x.org/circuits/fleet/grade)

A Conn3x circuit that installs the Fleet device management server from its pinned, checksum-verified release and runs it under systemd. Fleet is built on osquery: your hosts enroll with it, and you can ask any of them a question in SQL and get the answer back while you wait.

Fleet needs MySQL and Redis or Valkey, and this circuit expects both to exist. [circuit-mysql](https://github.com/conn3xorg/circuit-mysql) and [circuit-valkey](https://github.com/conn3xorg/circuit-valkey) put them on the same host, and [circuit-osquery](https://github.com/conn3xorg/circuit-osquery) enrolls your hosts afterwards. Passwords and keys go in at run time and never land in state.

## Usage

```hcl
variable "db_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "valkey_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "server_private_key" {
  type      = string
  ephemeral = true
  sensitive = true
}

locals {
  host = { fleet = { address = "192.168.1.50", os = "ubuntu" } }
}

module "mysql" {
  source = "github.com/conn3xorg/circuit-mysql?ref=v0.1.0"

  hosts                = local.host
  ssh_private_key_file = "~/.ssh/id_ed25519"

  # Fleet lists 8.0, 8.4 and 9.5 as tested, not circuit-mysql's default of 9.7.
  mysql_version  = "8.4"
  users          = ["fleet"]
  user_passwords = { fleet = var.db_password }
  databases      = ["fleet"]
  grants         = [{ user = "fleet", database = "fleet" }]
}

module "valkey" {
  source = "github.com/conn3xorg/circuit-valkey?ref=v0.1.0"

  hosts                = local.host
  ssh_private_key_file = "~/.ssh/id_ed25519"

  password = var.valkey_password
}

module "fleet" {
  source = "github.com/conn3xorg/circuit-fleet?ref=v0.1.1"

  depends_on = [module.mysql, module.valkey]

  hosts                = local.host
  ssh_private_key_file = "~/.ssh/id_ed25519"

  server_name        = "fleet.example.com"
  database_password  = var.db_password
  redis_password     = var.valkey_password
  server_private_key = var.server_private_key
}
```

Then run `conn3x init` and `conn3x apply` with the secrets in the environment:

```sh
export TF_VAR_db_password='...'
export TF_VAR_valkey_password='...'
export TF_VAR_server_private_key="$(openssl rand -base64 32)"   # keep a copy of this one
conn3x apply
```

A second `conn3x plan` says `No changes.` Every plan needs the secrets too, since Conn3x checks the files on the host against them.

`server_private_key` encrypts the secrets Fleet keeps in its database. Store it somewhere safe and pass the same value every time: anything encrypted with it can't be read without it.

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry. Give each one's distribution in `os` too. Set `os` as well when you put `depends_on` on this module, as above: `depends_on` holds back reading the hosts until the apply, so without `os` the plan fails with `Invalid for_each argument`.

To try it on a throwaway container first, see [examples/local](examples/local).

## Finish setup before you open it up

A new Fleet has no admin, and the first person to reach it creates one. That's why Fleet listens on `127.0.0.1` until you change `listen_address`. Finish setup from the host itself, over SSH, in a browser through a tunnel or with the API:

```sh
curl --cacert /etc/fleet/fleet.crt -H 'Content-Type: application/json' \
  https://localhost:8080/api/v1/setup -d '{
    "admin": {"name": "You", "email": "you@example.com", "password": "at-least-12-chars-1-symbol!"},
    "org_info": {"org_name": "Example"},
    "server_url": "https://fleet.example.com:8080"
  }'
```

Log in at `/api/v1/fleet/login` for a token, then choose the enroll secret osquery will use:

```sh
curl --cacert /etc/fleet/fleet.crt -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  https://localhost:8080/api/v1/fleet/spec/enroll_secret \
  -d '{"spec": {"secrets": [{"secret": "your-enroll-secret"}]}}'
```

Those commands run on the host. With a certificate of your own, or with `server_name` set to something other than `localhost`, use that name in the URL and the matching certificate. Then set `listen_address` to `"0.0.0.0"` or a private address and apply again. The circuit doesn't open a firewall port, so if you run a firewall, open `port` there.

The commands above put the admin password in your shell history and in `ps` on the host while they run, so change it in Fleet afterwards if other people share the box. The circuit doesn't do setup for you. It would have to keep an admin password and an API session in step with whatever you later change in Fleet, and that's your account, not configuration.

## Enrolling hosts

Use [circuit-osquery](https://github.com/conn3xorg/circuit-osquery) on every host you want in Fleet. With a self-signed certificate, copy `/etc/fleet/fleet.crt` from the Fleet host to each one first, and point `server_certs` at it:

```hcl
module "osquery" {
  source = "github.com/conn3xorg/circuit-osquery?ref=v0.1.0"

  hosts                = { web1 = "192.168.1.60" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  fleet = {
    address      = "fleet.example.com:8080"
    server_certs = "/etc/osquery/fleet.crt"
  }
  enroll_secret = var.enroll_secret
}
```

`address` has to match `server_name`, or osquery refuses the certificate. Then the host shows up in `GET /api/v1/fleet/hosts`, and you can ask it something:

```sh
curl --cacert fleet.crt -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  https://fleet.example.com:8080/api/v1/fleet/hosts/1/query \
  -d '{"query": "SELECT version FROM osquery_info;"}'
```

## What's free and what's paid

This circuit installs the free tier and sets no license key. As of October 2026, [Fleet's pricing table](https://fleetdm.com/pricing) lists these among the free features: device inventory, reports, policies, labels, file integrity monitoring, continuous vulnerability scanning, script execution, the REST API, GitOps and SSO.

These are among the features it lists as Fleet Premium, and need a paid license this circuit doesn't provide: fleets (grouping hosts with their own settings), role-based access control, audit logging, two-factor authentication, conditional access, vulnerability scores and CISA KEVs, custom tables, lock and wipe commands, disk encryption and OS update enforcement, application deployment and self-service installs, zero-touch setup, control over agent versions, and managed hosting. The table changes over time, so check it before you plan around a feature.

The only features exercised here are setup, enrollment, the host list and live queries, on Linux. Fleet's free tier also lists device management for other platforms; none of that was set up or tried with this circuit, on Apple, Windows or Android devices.

## What it does

On each host, in order:

1. On Debian and Ubuntu, installs `curl` for the download. Installs `openssl` too, when the circuit makes the certificate.
2. Creates a `fleet` system user, then `/etc/fleet`, `/var/lib/fleet` and `/var/log/fleet`.
3. Downloads Fleet's Linux release to `/opt/fleet`, checks it against `fleet_sha256` and unpacks it. The tarball stays there, and so do earlier releases after an upgrade.
4. Makes a self-signed certificate for `server_name`, valid for ten years, unless you give it `tls_cert_file` and `tls_key_file`, or set `tls` to false.
5. Writes `/etc/fleet/fleet.yml`, which holds no secrets; `/etc/fleet/mysql_password`, which Fleet reads directly; and `/etc/fleet/fleet.env`, root-only, with the Valkey password and `server_private_key`, which systemd hands to Fleet.
6. Writes `fleet.service`, stops Fleet, runs `fleet prepare db` to create or migrate the schema, and starts Fleet again, now and at boot. The migration runs on the first apply and when `fleet_version` changes. A change to any file above restarts Fleet without one.

Raising `fleet_version` is the upgrade path, in the order Fleet's guide gives. Back up the database first, as that guide advises: the circuit doesn't, and a migration can't be undone by lowering the version.

### Usage data and outbound connections

Fleet sends anonymous [usage statistics](https://fleetdm.com/docs/using-fleet/usage-statistics) by default: `enable_analytics` was on after setup in testing. To turn it off, set `server_settings.enable_analytics` to false through `PATCH /api/v1/fleet/config`. Its vulnerability job also downloads data from the internet into `/var/lib/fleet/vulndbs`. See Fleet's [server configuration](https://fleetdm.com/docs/configuration/fleet-server-configuration) for that job's settings.

### What it doesn't do

- It doesn't install MySQL, Valkey or Redis, or create the database and its user. `database_name` must exist, and `database_user` needs all privileges on it.
- It doesn't finish Fleet's setup, create the enroll secret or enroll hosts. See the sections above.
- It doesn't renew or distribute certificates. Self-signed ones last ten years, and osquery hosts need a copy; a new `server_name` means a new one, which every host then needs.
- It doesn't expose every Fleet setting. For what's left, such as SSO or SMTP, use Fleet's API or GitOps.
- It doesn't back up the database.
- Deleting the module leaves Fleet installed and running.
- It wasn't built for several Fleet servers behind one load balancer. Each host gets its own server, and each runs its own migrations, so pointing several at one database isn't something this circuit coordinates.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, or a host object with `address` and optional `host_key`, `user`, `port`, `private_key_file`, `jump_hosts` and `os`. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `fleet_version` | string | `"4.94.0"` | Fleet release to install. Raising it stops Fleet, migrates the database and starts the new release. Change `fleet_sha256` with it. |
| `fleet_sha256` | string | The 4.94.0 checksum | SHA-256 of `fleet_v<version>_linux.tar.gz`, from the release's `checksums.txt`. |
| `listen_address` | string | `"127.0.0.1"` | Address Fleet listens on. Other hosts can't enroll until you change it, and you should finish setup first. |
| `port` | number | `8080` | TCP port Fleet listens on. |
| `server_name` | string | `"localhost"` | Name or IP address osquery and browsers use to reach Fleet, which goes in the self-signed certificate. |
| `tls` | bool | `true` | Serve HTTPS. Set it to false only behind a reverse proxy that handles TLS, since osquery only talks to Fleet over TLS. |
| `tls_cert_file` | string | `null` | Certificate already on the host, readable by the `fleet` user. When null, the circuit makes a self-signed one. |
| `tls_key_file` | string | `null` | Private key for `tls_cert_file`, readable by the `fleet` user. |
| `database_address` | string | `"127.0.0.1:3306"` | MySQL server as `host:port`. |
| `database_name` | string | `"fleet"` | MySQL database, which must exist. |
| `database_user` | string | `"fleet"` | MySQL user, with all privileges on `database_name`. |
| `database_password` | string | Required | Password for `database_user`. Ephemeral: it never reaches state or the plan. |
| `redis_address` | string | `"127.0.0.1:6379"` | Redis or Valkey server as `host:port`. |
| `redis_password` | string | Required | Password for Redis or Valkey. Ephemeral. |
| `server_private_key` | string | Required | Key Fleet encrypts stored secrets with, at least 32 characters, such as the output of `openssl rand -base64 32`. Ephemeral. Keep a copy. |

## Outputs

| Name | Description |
| --- | --- |
| `url` | Address of Fleet, from `server_name` and `port`. |
| `tls_cert_file` | Certificate Fleet serves, for osquery's `server_certs`. Null when `tls` is false. |
| `config_file` | Fleet's settings file, `/etc/fleet/fleet.yml`, which holds no secrets. |

## Requirements

Requires Conn3x v0.6.9 or later and systemd on each host, amd64 only, since Fleet's release has one Linux build. Each host needs to reach GitHub for the download, and needs a MySQL server and a Redis or Valkey server it can log in to. Fleet asks for MySQL 8.0.44 or later and lists 8.0.44, 8.4.8 and 9.5.0 as tested, with 9.6.0 incompatible; this circuit doesn't check which one you have. On a droplet with 4 GB of memory, Fleet used about 115 MB just after a reboot, and the whole host, with MySQL and Valkey, about 900 MB. Those figures are from a host with one or two enrolled machines and no vulnerability scan run yet, so they're a floor.

### Distributions left out

- **Fedora.** Fleet's binary doesn't care, but circuit-mysql doesn't support Fedora because MySQL doesn't build for it, so the tested path doesn't exist there. The `os` validation rejects it.
- **arm64.** Fleet publishes no arm64 Linux server build or image. Enrolled hosts can be arm64 if osquery runs there, but that wasn't tested.

## Tested on

Ubuntu 24.04, Debian 13 and Rocky Linux 10, with Fleet 4.94.0, MySQL 8.4 from circuit-mysql, Valkey from circuit-valkey and osquery 5.24.0 from circuit-osquery, all on one host. CI applies [examples/local](examples/local) to each on amd64 and checks that the plan after it has no changes. It then completes Fleet's setup through its API, sets the enroll secret, enrolls the host with osquery, plans again, and checks these: the tier is free, setup is closed, a wrong enroll secret gets a 401, the host is listed and online, and it answers a live query. It also checks that no secret reached the state file. The same ran by hand in containers on an amd64 machine.

The same checks passed on Ubuntu 24.04 and Rocky Linux 10 droplets, the Rocky one with SELinux enforcing and no denials logged, and again after rebooting each, when the plan also had no changes.

By hand, on those droplets: Fleet on Ubuntu 24.04 with `listen_address = "0.0.0.0"` and `server_name` set to its IP address, with the Rocky Linux host enrolling over the network using a copy of the certificate. It was listed and online, and answered a live query. In a container on Ubuntu 24.04, an upgrade from Fleet 4.93.2 to 4.94.0 through `fleet_version` kept the admin and the enrolled host, and the checks passed afterwards.

Not tested: a reverse proxy with `tls = false`, certificates of your own, a database or Valkey on another host, arm64, and any device management of Apple, Windows or Android devices.

## License

MPL-2.0. See [LICENSE](LICENSE). Fleet's free version is MIT-licensed, apart from its `ee/` directory, which is under Fleet's commercial license.
