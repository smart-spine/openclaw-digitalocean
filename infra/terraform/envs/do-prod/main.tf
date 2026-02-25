locals {
  ssh_public_key = trimspace(file(var.ssh_public_key_path))
}

resource "digitalocean_ssh_key" "deploy" {
  name       = "${var.project_name}-deploy-key"
  public_key = local.ssh_public_key
}

resource "digitalocean_droplet" "gateway" {
  name       = "${var.project_name}-gateway"
  region     = var.region
  size       = var.size
  image      = "ubuntu-24-04-x64"
  monitoring = true
  ssh_keys   = [digitalocean_ssh_key.deploy.id]
  tags       = [var.project_name, "openclaw"]
}

resource "digitalocean_firewall" "ssh_only" {
  name = "${var.project_name}-ssh-only"

  droplet_ids = [digitalocean_droplet.gateway.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.ssh_allowed_cidrs
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
