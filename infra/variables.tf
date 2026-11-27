variable "project_id" {
  type    = string
  default = "libre-glance"
}

variable "region" {
  type    = string
  default = "europe-west9"
}

variable "scheduler_region" {
  description = "Cloud Scheduler is not available in every region."
  type        = string
  default     = "europe-west1"
}

variable "bundle_id" {
  type    = string
  default = "com.datally.libreGlance"
}

variable "apns_team_id" {
  type    = string
  default = "7536NF2Y6H"
}

variable "apns_key_id" {
  type    = string
  default = "9583USS5C2"
}

variable "image" {
  description = "Container image (built after the first apply). Empty = Cloud Run and Scheduler are not created yet."
  type        = string
  default     = ""
}
