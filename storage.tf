resource "random_id" "suffix" {
  byte_length = 8
}

resource "google_storage_bucket" "ansible" {
  name = "ansible-${random_id.suffix.hex}"
}

resource "google_storage_bucket_object" "playbook" {
  for_each = fileset("${path.module}/ansible", "**")
  bucket   = google_storage_bucket.ansible.name
  name     = "ansible/${each.key}"
  source   = "${path.module}/ansible/${each.key}"
}