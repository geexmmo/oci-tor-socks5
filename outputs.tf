output "instance_ocid" {
  description = "Use with rotate-ip.sh"
  value       = oci_core_instance.proxy.id
}

output "public_ip" {
  value = oci_core_instance.proxy.public_ip
}

output "ssh_command" {
  value = "ssh -i ${pathexpand(var.ssh_private_key_path)} ubuntu@${oci_core_instance.proxy.public_ip}"
}

output "ssh_socks_command" {
  description = "Encrypted SOCKS5 over SSH (no microsocks needed)"
  value       = "ssh -N -D 1080 -i ${pathexpand(var.ssh_private_key_path)} ubuntu@${oci_core_instance.proxy.public_ip}"
}

output "socks5_endpoint" {
  description = "Only meaningful when enable_microsocks = true; otherwise use ssh_socks_command."
  value = var.enable_microsocks ? (
    "socks5://${var.socks_user}:${var.socks_password}@${oci_core_instance.proxy.public_ip}:1080"
  ) : "disabled (use ssh_socks_command)"
  sensitive = true
}
