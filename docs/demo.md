# Demo end-to-end

Sequenza della demo richiesta dalla traccia (sezione 7), con comandi e risultati attesi. I comandi sono per PowerShell e si eseguono dalla radice del repository. Per ogni punto è indicata un'evidenza già presente nel repository, da usare se un passaggio non si può eseguire dal vivo.

Durata indicativa: 35-40 minuti.

## Preparazione (prima della demo)

Cluster acceso e ambienti già installati (README, sezioni 4 e 5.5). In una finestra PowerShell:

```powershell
$env:Path += ";$env:USERPROFILE\tools\helm\windows-amd64;$env:USERPROFILE\tools\mingit\cmd"
kubectl get nodes
kubectl get pods -A | Select-String -NotMatch "Running|Completed"
```

Atteso: nodo `Ready`; il secondo comando mostra solo l'intestazione (nessun pod in errore).

Port-forward, ciascuno in una finestra dedicata:

```powershell
kubectl port-forward svc/traefik 8082:80 -n traefik
kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring
kubectl port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 -n monitoring
kubectl port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 -n monitoring
```

Schede del browser: `http://dev.boutique.localhost:8082`, `http://prod.boutique.localhost:8082`, Grafana (`http://localhost:3000`), Prometheus (`http://localhost:9090/alerts`), Alertmanager (`http://localhost:9093`). Login di Grafana: utente `admin`, password copiata negli appunti senza mostrarla:

```powershell
Set-Clipboard -Value (Get-Content "$env:USERPROFILE\grafana-admin-password.txt" -Raw).Trim()
```

Editor aperto su `kubernetes/environments/dev/kustomization.yaml` (punti 7-9).

## 1. Clonare il repository e spiegare la struttura (3 min)

```powershell
git clone https://github.com/Kalejandros/kiratech-challenge.git
cd kiratech-challenge
tree kubernetes
```

Da mostrare: `base` (manifest upstream invariati + patch), `environments/dev` e `prod` (solo le differenze), `ingress/traefik`, `monitoring`; poi `docs/` e `ai-usage/`. Struttura completa: README, sezione 2.

## 2. Build dell'immagine applicativa (3 min)

```powershell
docker build -t boutique-frontend:v0.10.5-nonroot src\frontend
docker images boutique-frontend
docker inspect --format "{{.Config.User}}" boutique-frontend:v0.10.5-nonroot
docker run --rm boutique-frontend:v0.10.5-nonroot
```

Atteso: build completata (più veloce se gli strati sono in cache), immagine di circa 12 MB, utente `65532`; senza variabili d'ambiente il frontend si ferma con `panic: environment variable "PRODUCT_CATALOG_SERVICE_ADDR" not set`, perché la configurazione arriva dal manifest.

Piano B: [`run-nonroot.png`](screenshots/build/run-nonroot.png), [`run-senza-env.png`](screenshots/build/run-senza-env.png).

## 3. Installare la soluzione su Kubernetes (4 min)

Prerequisiti (namespace e Secret creati fuori dal repository):

```powershell
kubectl get namespace development production
kubectl describe secret redis-auth -n development
```

Atteso: i due namespace; il Secret mostra `REDIS_PASSWORD: 24 bytes`, senza il valore.

Rendering, prova e applicazione:

```powershell
kubectl kustomize kubernetes/environments/dev | Select-String "image:"
kubectl apply -k kubernetes/environments/dev --dry-run=server
kubectl apply -k kubernetes/environments/dev
kubectl apply -k kubernetes/ingress/traefik
helm list -n monitoring
```

Atteso: immagini con registry e tag `v0.10.5`; dry-run senza errori; risorse `unchanged` perché gli ambienti sono già installati (`kubectl apply` porta il cluster allo stato descritto nei file, senza ricreare ciò che è già allineato); release `monitoring` in stato `deployed`.

Piano B: [`prod-apply.png`](screenshots/tests/prod/prod-apply.png), [`traefik-installato.png`](screenshots/ingress/traefik-installato.png).

## 4. Verificare pod, service, ingress e configurazioni (4 min)

```powershell
kubectl get pods -n development
kubectl get pods -n production
kubectl get svc -n development
kubectl get endpointslices -n development -l kubernetes.io/service-name=frontend
kubectl get ingressclass
kubectl get ingress -A
kubectl get configmap -n development
kubectl kustomize kubernetes/environments/dev | Select-String "FRONTEND_MESSAGE"
```

Atteso: 11 pod `1/1 Running` in dev e 12 in prod (2 repliche del frontend); Service di tipo `ClusterIP`; l'EndpointSlice del frontend con l'indirizzo del pod; IngressClass `traefik`; due Ingress con host `dev.boutique.localhost` e `prod.boutique.localhost` e `ADDRESS` valorizzato; la ConfigMap `frontend-config-...` con il banner di dev.

Piano B: [`ingress-address.png`](screenshots/ingress/ingress-address.png), [`dev-get-pods.png`](screenshots/tests/dev/dev-get-pods.png).

## 5. Invocare gli endpoint applicativi principali (4 min)

```powershell
curl.exe -s -o NUL -w "%{http_code}`n" -H "Host: dev.boutique.localhost" http://localhost:8082/
curl.exe -s -o NUL -w "%{http_code}`n" -H "Host: prod.boutique.localhost" http://localhost:8082/
curl.exe -s -o NUL -w "%{http_code}`n" -H "Host: test.boutique.localhost" http://localhost:8082/
curl.exe -s -H "Host: dev.boutique.localhost" http://localhost:8082/_healthz
```

Atteso: `200`, `200`, `404` (host senza regola), `ok`.

Nel browser: home di dev (con il banner) e di prod (senza), aggiunta di un prodotto al carrello, cambio di valuta, checkout fino a "Your order is complete!". Il checkout attraversa frontend, checkout, carrello, Redis, catalogo, valute, spedizione, pagamento ed email.

```powershell
kubectl logs deploy/emailservice -n production --tail=5
```

Atteso: la richiesta di conferma ordine ricevuta da emailservice (in *dummy mode*).

Piano B: [`curl-host.png`](screenshots/ingress/curl-host.png), [`prod-checkout.png`](screenshots/tests/prod/prod-checkout.png).

## 6. Health check, readiness, log e metriche (5 min)

```powershell
kubectl describe pod -n development -l app=frontend | Select-String "Liveness|Readiness"
kubectl logs deploy/frontend -n development --tail=5
kubectl top pods -n development
.\scripts\frontend-metrics.ps1
```

Atteso: probe di liveness e readiness su `/_healthz`; log JSON strutturati (richieste delle probe con stato 200); consumi di CPU e memoria; riepilogo di latenza (mediana, 95° percentile) ricavato dai log.

In Grafana: dashboard `Kubernetes / Compute Resources / Namespace (Pods)`, namespace `development` e poi `production`. In Prometheus: regola `BoutiqueFrontendDown` in stato `INACTIVE`.

Piano B: [`grafana-namespace-dev.png`](screenshots/monitoring/grafana-namespace-dev.png), [`frontend-metrics.png`](screenshots/metriche/frontend-metrics.png).

## 7. Aggiornamento applicativo e rollout (3 min)

Nel file `kubernetes/environments/dev/kustomization.yaml`, nel blocco `images:` **del solo frontend**, cambiare `newTag: v0.10.5` in `newTag: v0.10.4`. Poi:

```powershell
kubectl kustomize kubernetes/environments/dev | Select-String "frontend:v"
kubectl apply -k kubernetes/environments/dev
kubectl rollout status deployment/frontend -n development
kubectl rollout history deployment/frontend -n development
kubectl get rs -n development -l app=frontend
```

Atteso: solo il frontend passa a `v0.10.4`; `deployment.apps/frontend configured`; rollout completato; una nuova revisione nella history; il ReplicaSet nuovo con 1 replica e il vecchio a 0. Il port-forward verso Traefik non si interrompe: Traefik segue gli endpoint del Service.

Piano B: [`update-v0104.png`](screenshots/update-rollback/update-v0104.png).

## 8. Failure scenario e troubleshooting (5 min)

Nello stesso file, `newTag: v0.10.4` → `newTag: v0.10.99` (tag inesistente). Poi:

```powershell
kubectl apply -k kubernetes/environments/dev
kubectl rollout status deployment/frontend -n development --timeout=60s
kubectl get pods -n development -l app=frontend
kubectl describe pod -n development -l app=frontend | Select-String "Image:|NotFound|Back-off"
1..10 | ForEach-Object { curl.exe -s -o NUL -w "%{http_code} " -H "Host: dev.boutique.localhost" http://localhost:8082/ }
```

Atteso: `rollout status` in timeout; un pod nuovo `0/1 ImagePullBackOff` e il vecchio `1/1 Running`; messaggio `NotFound` (registry raggiunto, tag inesistente: non è un problema di rete); dieci risposte `200`, perché il pod nuovo non è mai `Ready` e non riceve traffico. Per lo stesso motivo l'allarme `BoutiqueFrontendDown` non scatta: il servizio è disponibile.

Piano B: [`guasto-describe-notfound.png`](screenshots/update-rollback/guasto-describe-notfound.png), [`guasto-servizio-disponibile.png`](screenshots/update-rollback/guasto-servizio-disponibile.png).

## 9. Rollback (4 min)

Rollback di emergenza:

```powershell
kubectl rollout undo deployment/frontend -n development
kubectl rollout status deployment/frontend -n development
kubectl rollout history deployment/frontend -n development
```

Atteso: `rolled back` e rollout completato in pochi secondi (il pod della versione precedente era ancora in esecuzione); avviso su `last-applied-configuration`: il file dice ancora `v0.10.99`.

Riallineamento del repository: nel file, `newTag: v0.10.99` → `newTag: v0.10.5` (versione di partenza, uguale a prod). Poi:

```powershell
kubectl kustomize kubernetes/environments/dev | Select-String "frontend:v"
kubectl apply -k kubernetes/environments/dev
kubectl rollout status deployment/frontend -n development
```

Atteso: dev di nuovo su `v0.10.5`, allineato al repository e a prod.

Facoltativo, per mostrare l'allarme (circa 3 minuti di attesa):

```powershell
kubectl scale deployment/frontend --replicas=0 -n development
kubectl scale deployment/frontend --replicas=1 -n development
```

Tra i due comandi: in Prometheus la regola passa da `PENDING` a `FIRING` e l'allarme compare in Alertmanager.

Piano B: [`rollback-undo.png`](screenshots/update-rollback/rollback-undo.png), [`prometheus-alert-firing.png`](screenshots/monitoring/prometheus-alert-firing.png).

## 10. Valutazione Krateo (4 min)

Documento: [`krateo.md`](krateo.md). Punti da presentare: il golden path "Ambiente Online Boutique" e cosa diventa template (sezione 3); i parametri esposti al team consumer (sezione 4); il prerequisito della conversione in chart Helm (sezione 5); YAML concettuale e componenti esterni al cluster (sezione 6); il diagramma (sezione 7); la distinzione tra blueprint, PoC e adozione (sezione 8); la raccomandazione: non subito, prima chart Helm e PoC, poi pilota con più team (sezione 10).

## 11. Esempio concreto di utilizzo dell'AI (4 min)

Caso: le immagini "bloccate dalla rete" ([`ai-usage.md`](../ai-usage/ai-usage.md), sezione 5).

- **Input:** pod in `ImagePullBackOff` tranne Redis.
- **Ragionamento e output:** la prima risposta indicava un blocco della rete aziendale; plausibile, ma non verificata.
- **Verifica:** messaggio completo dell'evento e test di raggiungibilità del registry.
- **Valore:** causa vera individuata (immagini senza registry), progetto sbloccato, controllo automatico aggiunto alla pipeline.

Riproduzione dal vivo dell'errore originale:

```powershell
kubectl run test-senza-registry --image=frontend --restart=Never -n development
kubectl describe pod test-senza-registry -n development | Select-String "Failed|denied|docker.io"
kubectl delete pod test-senza-registry -n development
```

Atteso: `pull access denied` su `docker.io/library/frontend`: il nome breve dell'immagine viene completato verso Docker Hub, dove quel repository non esiste.

Piano B: [`describe-pull-access-denied.png`](screenshots/troubleshooting/describe-pull-access-denied.png).

## Verifica finale

```powershell
kubectl get pods -n development
kubectl kustomize kubernetes/environments/dev | Select-String "frontend:v"
```

Atteso: 11 pod `1/1 Running` e frontend su `v0.10.5`: ambiente lasciato come all'inizio.