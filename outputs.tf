output "url" {
  description = "Address of Fleet, from server_name and port."
  value       = "${var.tls ? "https" : "http"}://${var.server_name}:${var.port}"
}

output "tls_cert_file" {
  description = "Certificate Fleet serves on each host, which osquery trusts through its server_certs. Null when tls is false."
  value       = var.tls ? local.cert : null
}

output "config_file" {
  description = "Fleet's settings file on each host. It holds no secrets."
  value       = local.config
}
