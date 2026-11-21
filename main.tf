provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  region       = var.region
}

# Latest Ubuntu 24.04 image for the chosen shape (x86_64 for E2.1.Micro).
data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  cidr_block     = "10.0.0.0/16"
  display_name   = "socks-vcn"
  dns_label      = "socksvcn"
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "socks-igw"
  enabled        = true
}

resource "oci_core_route_table" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "socks-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

resource "oci_core_security_list" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "socks-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    protocol = "6" # TCP
    source   = var.admin_cidr
    tcp_options {
      min = 22
      max = 22
    }
  }

  dynamic "ingress_security_rules" {
    for_each = var.enable_microsocks ? [1] : []
    content {
      protocol = "6" # TCP
      source   = var.admin_cidr
      tcp_options {
        min = 1080
        max = 1080
      }
    }
  }
}

resource "oci_core_subnet" "this" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = "10.0.1.0/24"
  display_name               = "socks-subnet"
  dns_label                  = "socks"
  route_table_id             = oci_core_route_table.this.id
  security_list_ids          = [oci_core_security_list.this.id]
  prohibit_public_ip_on_vnic = false
}

resource "oci_core_instance" "proxy" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  shape               = var.shape
  display_name        = "socks-proxy"

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu.images[0].id
  }

  # assign_public_ip = true -> EPHEMERAL public IP (not pinned / not reserved).
  create_vnic_details {
    subnet_id        = oci_core_subnet.this.id
    assign_public_ip = true
    hostname_label   = "socks"
  }

  metadata = {
    ssh_authorized_keys = file(pathexpand(var.ssh_public_key_path))
    user_data = base64encode(
      var.enable_microsocks
      ? templatefile("${path.module}/cloud-init.yaml.tftpl", {
        socks_user     = var.socks_user
        socks_password = var.socks_password
      })
      : "#cloud-config\n"
    )
  }
}
