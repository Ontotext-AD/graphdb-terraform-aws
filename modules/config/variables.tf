# REQUIRED parameters

variable "resource_name_prefix" {
  description = "Resource name prefix used for tagging and naming AWS resources."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]+$", var.resource_name_prefix)) && !can(regex("^-", var.resource_name_prefix))
    error_message = "Resource name prefix cannot start with a hyphen and can only contain letters, numbers, and hyphens."
  }
}

# OPTIONAL parameters

variable "graphdb_admin_password" {
  description = "Password for the 'admin' user in GraphDB."
  type        = string
  default     = null
  sensitive   = true

  # validation {
  #   condition     = length(var.graphdb_admin_password) >= 5 && can(regex("[0-9]", var.graphdb_admin_password))
  #   error_message = "Password must be at least 5 characters long and contain at least one number."
  # }
}

variable "graphdb_cluster_token" {
  description = "Cluster token used for authenticating the communication between the nodes."
  default     = null
  sensitive   = true
}

variable "graphdb_license_path" {
  description = "Local path to a file, containing a GraphDB Enterprise license."
  type        = string
  default     = null
}

variable "graphdb_lb_dns_name" {
  description = "The DNS name of the load balancer for the GraphDB nodes."
  type        = string
  default     = ""
}
