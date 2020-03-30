output "http_url" {
  value = "http://${module.gce-lb-http.external_ip}"
}