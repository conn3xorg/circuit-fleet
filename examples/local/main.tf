variable "port" {
  type    = number
  default = 2305
}

# The container's distribution: rocky, ubuntu or debian. depends_on below
# holds back reading the host until the apply, so the circuits take the
# distribution from here to plan.
variable "os" {
  type    = string
  default = "rocky"
}

# Off for the first apply: osquery can't enroll until setup.sh has finished
# Fleet's setup and set the enroll secret.
variable "enroll" {
  type    = bool
  default = false
}

# Example secrets only. Pass your own with -var or TF_VAR_ on a real host.
variable "db_password" {
  type      = string
  default   = "correct-horse-battery"
  ephemeral = true
  sensitive = true
}

variable "valkey_password" {
  type      = string
  default   = "staple-paper-clip"
  ephemeral = true
  sensitive = true
}

variable "server_private_key" {
  type      = string
  default   = "example-only-example-only-example-only"
  ephemeral = true
  sensitive = true
}

variable "enroll_secret" {
  type      = string
  default   = "example-enroll-secret"
  ephemeral = true
  sensitive = true
}

locals {
  host = { box = { address = "127.0.0.1", os = var.os } }
}

# Fleet is tested against MySQL 8.4, and doesn't list 9.7, circuit-mysql's
# default.
module "mysql" {
  source = "github.com/conn3xorg/circuit-mysql?ref=v0.1.0"

  hosts                = local.host
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  mysql_version  = "8.4"
  users          = ["fleet"]
  user_passwords = { fleet = var.db_password }
  databases      = ["fleet"]
  grants         = [{ user = "fleet", database = "fleet" }]
}

module "valkey" {
  source = "github.com/conn3xorg/circuit-valkey?ref=v0.1.0"

  hosts                = local.host
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  password = var.valkey_password
}

module "fleet" {
  source = "../.."

  depends_on = [module.mysql, module.valkey]

  hosts                = local.host
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  database_password  = var.db_password
  redis_password     = var.valkey_password
  server_private_key = var.server_private_key
}

# The same host enrolls in its own Fleet, trusting the self-signed certificate.
module "osquery" {
  source = "github.com/conn3xorg/circuit-osquery?ref=v0.1.0"

  depends_on = [module.fleet]

  hosts                = var.enroll ? local.host : {}
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  fleet = {
    address      = "localhost:8080"
    server_certs = module.fleet.tls_cert_file
  }
  enroll_secret = var.enroll_secret
}

output "url" {
  value = module.fleet.url
}
