ui            = true
disable_mlock = true
api_addr      = "http://vault3_site2:8200"
cluster_addr  = "http://vault3_site2:8201"

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1               # LAB ONLY: sin TLS. No usar así en producción.
}

storage "raft" {
  path    = "/vault/data"
  node_id = "vault3_site2"
  retry_join { leader_api_addr = "http://vault1_site2:8200" }
  retry_join { leader_api_addr = "http://vault2_site2:8200" }
  retry_join { leader_api_addr = "http://vault3_site2:8200" }
}
