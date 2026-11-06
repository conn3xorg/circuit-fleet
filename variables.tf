variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux or rhel. CentOS Linux reached end of life on 30 June 2024: use Rocky Linux."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "fleet_version" {
  type        = string
  default     = "4.94.0"
  nullable    = false
  description = "Fleet release to install, such as \"4.94.0\". Raising it stops Fleet, runs its database migrations and starts the new release. Change fleet_sha256 with it."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.fleet_version))
    error_message = "fleet_version must be a full release, such as \"4.94.0\"."
  }
}

variable "fleet_sha256" {
  type        = string
  default     = "c5a5e43b0ae7f9bafd60e9fed304d52a40e541db259cb02adae1d329ea21fd0e"
  nullable    = false
  description = "SHA-256 of fleet_v<version>_linux.tar.gz, from the release's checksums.txt."

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.fleet_sha256))
    error_message = "fleet_sha256 must be 64 lowercase hex characters."
  }
}

variable "listen_address" {
  type        = string
  default     = "127.0.0.1"
  description = "Address Fleet listens on. Set it to \"0.0.0.0\" or a private address once setup is done, or hosts elsewhere can't enroll. Until setup is done, whoever reaches Fleet first can create its admin."

  validation {
    condition     = can(regex("^[0-9A-Fa-f.:]+$", var.listen_address))
    error_message = "listen_address must be an IP address."
  }
}

variable "port" {
  type        = number
  default     = 8080
  description = "TCP port Fleet listens on."

  validation {
    condition     = var.port >= 1 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be a port number from 1 to 65535."
  }
}

variable "server_name" {
  type        = string
  default     = "localhost"
  description = "Name or IP address osquery and browsers use to reach Fleet. It goes in the self-signed certificate. Changing it makes a new one."

  validation {
    condition     = can(regex("^[a-zA-Z0-9.:-]+$", var.server_name))
    error_message = "server_name must be a host name or IP address, without a scheme or port."
  }
}

variable "tls" {
  type        = bool
  default     = true
  description = "Serve HTTPS. Set it to false only behind a reverse proxy that handles TLS: osquery only talks to Fleet over TLS."
}

variable "tls_cert_file" {
  type        = string
  default     = null
  description = "Certificate already on the host, readable by the fleet user. When null, the circuit makes a self-signed one for server_name."

  validation {
    condition     = var.tls_cert_file == null || can(regex("^/[^[:space:]]*$", coalesce(var.tls_cert_file, "-")))
    error_message = "tls_cert_file must be an absolute path without spaces."
  }

  validation {
    condition     = (var.tls_cert_file == null) == (var.tls_key_file == null)
    error_message = "Set tls_cert_file and tls_key_file together."
  }
}

variable "tls_key_file" {
  type        = string
  default     = null
  description = "Private key for tls_cert_file, already on the host, readable by the fleet user."

  validation {
    condition     = var.tls_key_file == null || can(regex("^/[^[:space:]]*$", coalesce(var.tls_key_file, "-")))
    error_message = "tls_key_file must be an absolute path without spaces."
  }
}

variable "database_address" {
  type        = string
  default     = "127.0.0.1:3306"
  description = "MySQL server as host:port."

  validation {
    condition     = can(regex("^[a-zA-Z0-9.:_\\[\\]-]+:[0-9]+$", var.database_address))
    error_message = "database_address must be host:port, such as \"127.0.0.1:3306\"."
  }
}

variable "database_name" {
  type        = string
  default     = "fleet"
  description = "MySQL database. It must exist already."

  validation {
    condition     = can(regex("^[a-zA-Z0-9_]+$", var.database_name))
    error_message = "database_name may use letters, digits and _."
  }
}

variable "database_user" {
  type        = string
  default     = "fleet"
  description = "MySQL user, with all privileges on database_name."

  validation {
    condition     = can(regex("^[a-zA-Z0-9_]+$", var.database_user))
    error_message = "database_user may use letters, digits and _."
  }
}

variable "database_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  nullable    = false
  description = "Password for database_user. Pass it at run time with -var or TF_VAR_database_password; it never reaches state or the plan."

  validation {
    condition     = length(var.database_password) > 0
    error_message = "database_password can't be empty."
  }
}

variable "redis_address" {
  type        = string
  default     = "127.0.0.1:6379"
  description = "Redis or Valkey server as host:port."

  validation {
    condition     = can(regex("^[a-zA-Z0-9.:_\\[\\]-]+:[0-9]+$", var.redis_address))
    error_message = "redis_address must be host:port, such as \"127.0.0.1:6379\"."
  }
}

variable "redis_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  nullable    = false
  description = "Password for Redis or Valkey. Pass it at run time with -var or TF_VAR_redis_password; it never reaches state or the plan."

  validation {
    condition     = length(var.redis_password) > 0 && !can(regex("[\\r\\n]", var.redis_password))
    error_message = "redis_password can't be empty or contain a line break."
  }
}

variable "server_private_key" {
  type        = string
  ephemeral   = true
  sensitive   = true
  nullable    = false
  description = "Key Fleet encrypts the secrets it stores with, at least 32 bytes, such as the output of openssl rand -base64 32. Keep a copy: secrets encrypted with it can't be read without it. Pass it at run time with -var or TF_VAR_server_private_key; it never reaches state or the plan."

  validation {
    condition     = length(var.server_private_key) >= 32 && !can(regex("[\\r\\n]", var.server_private_key))
    error_message = "server_private_key must be at least 32 characters, on one line."
  }
}
