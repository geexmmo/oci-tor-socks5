variable "tenancy_ocid" {
  description = "Tenancy OCID (from ~/.oci/config or the console)"
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment to create the VM and networking in"
  type        = string
}

variable "region" {
  description = "OCI region identifier"
  type        = string
  default     = "us-phoenix-1"
}

variable "availability_domain" {
  description = "Availability domain. VM.Standard.E2.1.Micro is only offered in one AD per region; if launch fails with 'out of host capacity', try AD-1/AD-2/AD-3."
  type        = string
  default     = "CWjj:PHX-AD-2"
}

variable "shape" {
  description = "Instance shape. E2.1.Micro = Always Free x86 (2 free per tenancy)."
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}

variable "admin_cidr" {
  description = "Your public IP in CIDR notation, allowed to reach SSH (22) and SOCKS5 (1080). e.g. 203.0.113.7/32"
  type        = string
}

variable "ssh_public_key_path" {
  description = "Public key installed for the ubuntu user"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_private_key_path" {
  description = "Private key used in the generated ssh command (kept local)"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "enable_microsocks" {
  description = "Install a standalone SOCKS5 daemon (microsocks) on port 1080. Not needed if you use `ssh -D`."
  type        = bool
  default     = false
}

variable "socks_user" {
  description = "SOCKS5 username"
  type        = string
  default     = "proxy"
}

variable "socks_password" {
  description = "SOCKS5 password"
  type        = string
  sensitive   = true
}
