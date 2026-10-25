ui            = true
disable_mlock = true
api_addr      = "http://vault3:8200"
cluster_addr  = "http://vault3:8201"

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1               # LAB ONLY: sin TLS. No usar asi en produccion.
}

storage "raft" {
  path    = "/vault/data"
  node_id = "vault3"
  retry_join { leader_api_addr = "http://vault1:8200" }
  retry_join { leader_api_addr = "http://vault2:8200" }
  retry_join { leader_api_addr = "http://vault3:8200" }
}
