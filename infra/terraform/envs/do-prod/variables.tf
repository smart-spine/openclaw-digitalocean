variable "project_name" {
  description = "Prefix for DigitalOcean resource names."
  type        = string
  default     = "openclaw"
}

variable "region" {
  description = "DigitalOcean region slug."
  type        = string
  default     = "nyc1"
}

variable "size" {
  description = "DigitalOcean Droplet size slug."
  type        = string
  default     = "s-1vcpu-2gb"
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to connect to SSH (tcp/22)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_public_key_path" {
  description = "Absolute path to the local SSH public key file."
  type        = string
}
