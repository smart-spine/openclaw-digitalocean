output "server_ip" {
  description = "Public IPv4 address of the OpenClaw droplet."
  value       = digitalocean_droplet.gateway.ipv4_address
}

output "ssh_command" {
  description = "SSH command for bootstrap access."
  value       = "ssh -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -i secrets/do_ssh_key root@${digitalocean_droplet.gateway.ipv4_address}"
}
