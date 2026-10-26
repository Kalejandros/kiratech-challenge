# Smoke test: verifica rapida che dev e prod rispondano dopo un intervento.
# Prerequisito: port-forward verso Traefik attivo (kubectl port-forward svc/traefik 8082:80 -n traefik)
param([int]$Port = 8082)

$script:ok = 0
$script:tot = 0

function Check($nome, $condizione, $dettaglio) {
  $script:tot++
  if ($condizione) { $script:ok++; Write-Host "[OK] $nome - $dettaglio" -ForegroundColor Green }
  else { Write-Host "[KO] $nome - $dettaglio" -ForegroundColor Red }
}

function Codice($hostName, $path) {
  curl.exe -s -o NUL -w "%{http_code}" --max-time 10 -H "Host: $hostName" "http://localhost:$Port$path"
}

# 1. Pod pronti in ogni ambiente
foreach ($ns in "development", "production") {
  $righe = @(kubectl get pods -n $ns --no-headers)
  $pronti = @($righe | Where-Object {
    $c = $_ -split '\s+'
    $r = $c[1].Split('/')
    ($r[0] -eq $r[1]) -and ($c[2] -eq 'Running')
  }).Count
  Check "pod $ns" (($righe.Count -gt 0) -and ($pronti -eq $righe.Count)) "$pronti/$($righe.Count) pronti"
}

# 2. Raggiungibilita di Traefik (port-forward)
$prova = Codice "dev.boutique.localhost" "/"
if ($prova -eq "000") {
  Write-Host "[KO] Traefik non raggiungibile su localhost:$Port - avviare il port-forward" -ForegroundColor Red
  exit 1
}

# 3. Endpoint attraverso l'Ingress
$c = Codice "dev.boutique.localhost" "/";   Check "home dev" ($c -eq "200") "HTTP $c"
$c = Codice "prod.boutique.localhost" "/";  Check "home prod" ($c -eq "200") "HTTP $c"
$c = Codice "test.boutique.localhost" "/";  Check "host senza regola" ($c -eq "404") "HTTP $c (atteso 404)"
$h = curl.exe -s --max-time 10 -H "Host: dev.boutique.localhost" "http://localhost:$Port/_healthz"
Check "health check dev" ($h -eq "ok") "risposta '$h'"

Write-Host ""
Write-Host "RISULTATO: $script:ok/$script:tot controlli superati"
if ($script:ok -ne $script:tot) { exit 1 }
