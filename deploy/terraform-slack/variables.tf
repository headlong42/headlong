variable "aws_region" {
  description = "AWS region for the VM"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type (Graviton/arm64 assumed by the AMI filter)"
  type        = string
  default     = "t4g.large"
}

variable "root_volume_gb" {
  description = "Root EBS volume size (gp3)"
  type        = number
  default     = 40
}

variable "shellm_repo" {
  description = "Git repo to deploy"
  type        = string
  default     = "https://github.com/laude-institute/headlong.git"
}

variable "shellm_branch" {
  description = "Branch to deploy"
  type        = string
  default     = "main"
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (Zero Trust dashboard URL or account home)"
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Zone ID of the domain (overview page of the zone)"
  type        = string
}

variable "domain" {
  description = "The zone's domain, e.g. example.com"
  type        = string
}

variable "subdomain" {
  description = "Subdomain for the viewer, e.g. agents -> agents.example.com"
  type        = string
  default     = "agents"
}

variable "dash_subdomain" {
  description = "Hostname label for the dash (dash_subdomain.domain). Defaults to subdomain. Split out so a persona's public name can change without renaming the AWS resources (SNS topic, alarms, lambda, instance) that subdomain also names — renaming those replaces them."
  type        = string
  default     = ""
}

# Extra hostnames served by the same box and tunnel beside the primary ones,
# each with its own DNS record (in the zone given as the value) and its own
# Access app on the same allowlist. For a persona that renamed its public
# hostnames and keeps the old ones alive: a phone PWA is pinned to the origin
# it was installed from, so a redirect would not keep it working, but a second
# ingress does. Empty by default.
variable "extra_dash_hosts" {
  description = "Additional dash hostnames: hostname => { zone_id, name } where name is the record label inside that zone, e.g. \"slack.shellm.net\" => { zone_id = \"...\", name = \"slack\" }."
  type        = map(object({ zone_id = string, name = string }))
  default     = {}
}

variable "extra_chat_hosts" {
  description = "Additional phone-chat hostnames, same shape as extra_dash_hosts; each gets the public-assets bypass the PWA needs."
  type        = map(object({ zone_id = string, name = string }))
  default     = {}
}

variable "chat_subdomain" {
  description = "Extra hostname for the phone chat PWA (chat -> chat.example.com), served by the same box and tunnel with its own Access app. Set to \"\" to disable."
  type        = string
  default     = "chat"
}

variable "allowed_emails" {
  description = "Emails allowed through Cloudflare Access"
  type        = list(string)
}

variable "allowed_email_domains" {
  description = "Whole email domains allowed through Cloudflare Access (e.g. [\"laude.org\"]); pair with the Google IdP so domain users get SSO instead of OTP"
  type        = list(string)
  default     = []
}

variable "google_oauth_client_id" {
  description = "Google OAuth client id for the Access Google IdP; empty leaves the stack OTP-only. See README for the manual Google Cloud setup."
  type        = string
  default     = ""
}

variable "google_oauth_client_secret" {
  description = "Secret for google_oauth_client_id"
  type        = string
  default     = ""
  sensitive   = true
}

variable "access_session_duration" {
  description = "How long an Access login lasts"
  type        = string
  default     = "168h"
}

variable "env_parameter" {
  description = <<-EOT
    Name of an SSM SecureString parameter holding the FULL contents of the
    box's root .env (ANTHROPIC_API_KEY, OPENAI_API_KEY, OPENAI_ORG,
    GEMINI_API_KEY, OPENROUTER_API_KEY, ...). Create/update it out-of-band
    from your local shellm/.env (never enters Terraform state):
      aws ssm put-parameter --name /shellm/env --type SecureString \
          --value "$(cat /path/to/headlong/.env)" --overwrite \
          --region <region>
    First boot writes it to /opt/shellm/app/.env, so instance rebuilds
    self-heal. NOTE: user-data runs once per instance — after changing the
    parameter, either force a rebuild:
      terraform apply -replace=aws_instance.shellm
    or update the running box in place over SSM:
      aws ssm start-session --target <instance-id> --region <region>
      # then on the box: re-run the fetch and restart headlong-web
    Set to "" to disable.
  EOT
  type        = string
  default     = "/shellm/env"
}

variable "alert_email" {
  description = <<-EOT
    Optional email fallback for the box-down SNS alerts (alerting.tf) —
    the primary path is Slack via Lambda. SNS emails a confirmation link
    on first apply; the subscription is inert until it is clicked. Set to
    "" to disable.
  EOT
  type        = string
  default     = ""
}
