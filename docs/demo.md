# Demo end-to-end

Sequenza della demo richiesta dalla traccia (sezione 7), con comandi e risultati attesi. I comandi sono per PowerShell e si eseguono dalla radice del repository, una riga alla volta. Per ogni punto è indicata un'evidenza già presente nel repository, da usare se un passaggio non si può eseguire dal vivo.

## Preparazione (prima della demo)

Cluster acceso e ambienti già installati (README, sezioni 4 e 5.5). In una finestra PowerShell:

```powershell
$env:Path += ";$env:USERPROFILE\tools\helm\windows-amd64;$env:USERPROFILE\tools\mingit\cmd"
kubectl get nodes
kubectl get pods -A --no-headers | Where-Object { $c = $_ -split '\s+'; $r = $c[2].Split('/'); $c[3] -ne 'Completed' -and ($r[0] -ne $r[1] -or $c[3] -ne 'Running') }
```

Atteso: nodo `Ready`; il secondo comando non restituisce nulla (nessun pod in errore o non pronto: il filtro controlla anche la colonna `READY`). Dopo una sospensione del PC, tutti i pod ripartono: `adservice` può restare non pronto per un paio di minuti prima di riprendersi da solo.

Port-forward, ciascuno in una finestra dedicata (si interrompono se il PC va in sospensione: in quel caso vanno riavviati):

```powershell
kubectl port-forward svc/traefik 8082:80 -n traefik
kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring
kubectl port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 -n monitoring
kubectl port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 -n monitoring
```

Con il port-forward verso Traefik attivo:

```powershell
.\scripts\smoke-test.ps1
```

Atteso: `6/6 controlli superati`.

Schede del browser: `http://dev.boutique.localhost:8082`, `http://prod.boutique.localhost:8082`, Grafana (`http://localhost:3000`), Prometheus (`http://localhost:9090/alerts`), Alertmanager (`http://localhost:9093`). Login di Grafana: utente `admin`, password copiata negli appunti senza mostrarla, subito prima di inserirla:

```powershell
Set-Clipboard -Value (Get-Content "$env:USERPROFILE\grafana-admin-password.txt" -Raw).Trim()
```

Editor aperto su `kubernetes/environments/dev/kustomization.yaml` (punti 7-9).

## 1. Clonare il repository e spiegare la struttura

```powershell
git clone https://github.com/Kalejandros/kiratech-challenge.git
cd kiratech-challenge
tree kubernetes
```

Da mostrare: `base` (manifest upstream invariati + patch), `environments/dev` e `prod` (solo le differenze), `ingress/traefik`, `monitoring`; poi `src/frontend`, `scripts/`, `docs/` e `ai-usage/`. Struttura completa: README, sezione 2.

## 2. Build dell'immagine applicativa

```powershell
docker build -t boutique-frontend:v0.10.5-nonroot src\frontend
docker images boutique-frontend
docker inspect --format "{{.Config.User}}" boutique-frontend:v0.10.5-nonroot
docker run --rm boutique-frontend:v0.10.5-nonroot
```

Atteso: build completata (pochi secondi se gli strati sono in cache: righe `CACHED`); immagine di circa 41 MB su disco e 12 MB di contenuto compresso; utente `65532`; senza variabili d'ambiente il frontend si ferma con `panic: environment variable "PRODUCT_CATALOG_SERVICE_ADDR" not set`, perché la configurazione arriva dal manifest.

Piano B: [`run-nonroot.png`](screenshots/build/run-nonroot.png), [`run-senza-env.png`](screenshots/build/run-senza-env.png).

## 3. Installare la soluzione su Kubernetes

Prerequisiti (namespace e Secret creati fuori dal repository):

```powershell
kubectl get namespace development production
kubectl describe secret redis-auth -n development
```

Atteso: i due namespace `Active`; il Secret mostra `REDIS_PASSWORD: 24 bytes`, senza il valore.

Rendering, prova e applicazione:

```powershell
kubectl kustomize kubernetes/environments/dev | Select-String "image:"
kubectl apply -k kubernetes/environments/dev --dry-run=server
kubectl apply -k kubernetes/environments/dev
kubectl apply -k kubernetes/ingress/traefik
helm list -n monitoring
```

Atteso: immagini con registry e tag `v0.10.5` (Redis `redis:alpine`); dry-run senza errori; risorse `unchanged` perché gli ambienti sono già installati (`kubectl apply` porta il cluster allo stato descritto nei file, senza ricreare ciò che è già allineato); release `monitoring` in stato `deployed`, chart `kube-prometheus-stack-92.13.1`.

Piano B: [`prod-apply.png`](screenshots/tests/prod/prod-apply.png), [`traefik-installato.png`](screenshots/ingress/traefik-installato.png).

## 4. Verificare pod, service, ingress e configurazioni

```powershell
kubectl get pods -n development
kubectl get pods -n production
kubectl get svc -n development
kubectl get endpointslices -n development -l kubernetes.io/service-name=frontend
kubectl get pods -n traefik
kubectl get ingressclass
kubectl get ingress -A
kubectl get configmap -n development
kubectl kustomize kubernetes/environments/dev | Select-String "FRONTEND_MESSAGE"
```

Atteso: 11 pod `1/1 Running` in dev e 12 in prod (2 repliche del frontend); Service di tipo `ClusterIP`, nessuno esposto direttamente; l'EndpointSlice del frontend con l'indirizzo del pod pronto; il pod del controller Traefik `1/1 Running`; IngressClass `traefik` con controller `traefik.io/ingress-controller`; due Ingress con host `dev.boutique.localhost` e `prod.boutique.localhost` e `ADDRESS` valorizzato (lo scrive il controller quando prende in carico la regola); la ConfigMap `frontend-config-...` con il banner di dev (`kube-root-ca.crt` è creata da Kubernetes in ogni namespace).

Piano B: [`ingress-address.png`](screenshots/ingress/ingress-address.png), [`dev-get-pods.png`](screenshots/tests/dev/dev-get-pods.png).

## 5. Invocare gli endpoint applicativi principali

```powershell
.\scripts\smoke-test.ps1
curl.exe -s -o NUL -w "%{http_code}`n" -H "Host: dev.boutique.localhost" http://localhost:8082/
curl.exe -s -o NUL -w "%{http_code}`n" -H "Host: prod.boutique.localhost" http://localhost:8082/
curl.exe -s -o NUL -w "%{http_code}`n" -H "Host: test.boutique.localhost" http://localhost:8082/
curl.exe -s -H "Host: dev.boutique.localhost" http://localhost:8082/_healthz
```

Atteso: smoke test `6/6`; poi `200`, `200`, `404` (host senza regola), `ok`. Un codice `000` indica che `curl` non ha ricevuto risposta: port-forward verso Traefik non attivo.

Nel browser: home di dev (con il banner) e di prod (senza), aggiunta di un prodotto al carrello, cambio di valuta, checkout fino a "Your order is complete!". Il checkout attraversa frontend, checkout, carrello, Redis, catalogo, valute, spedizione, pagamento ed email.

```powershell
kubectl logs deploy/emailservice -n production --tail=5
```

Atteso: la riga `A request to send order confirmation email ... has been received` (emailservice è in *dummy mode*: nessuna email esce dal cluster).

Piano B: [`curl-host.png`](screenshots/ingress/curl-host.png), [`prod-checkout.png`](screenshots/tests/prod/prod-checkout.png).

## 6. Health check, readiness, log e metriche

```powershell
kubectl describe pod -n development -l app=frontend | Select-String "Liveness|Readiness"
kubectl logs deploy/frontend -n development --tail=5
kubectl top pods -n development
.\scripts\frontend-metrics.ps1
```

Atteso: probe di liveness e readiness HTTP su `/_healthz` (`delay=10s`, `period=10s`, `#failure=3`); log JSON strutturati, con le richieste delle probe distinte dal campo `session` e orari in UTC; consumi di CPU e memoria; riepilogo di latenza ricavato dai log. Mediana e 95° percentile sono più rappresentativi della media, che una sola richiesta lenta (la prima dopo un periodo di inattività) può falsare.

In Grafana: dashboard `Kubernetes / Compute Resources / Namespace (Pods)`, namespace `development` e poi `production`. In Prometheus: regola `BoutiqueFrontendDown` in stato `INACTIVE`.

Piano B: [`grafana-namespace-dev.png`](screenshots/monitoring/grafana-namespace-dev.png), [`frontend-metrics.png`](screenshots/metriche/frontend-metrics.png).

## 7. Aggiornamento applicativo e rollout

Nel file `kubernetes/environments/dev/kustomization.yaml`, nel blocco `images:` **del solo frontend**, cambiare `newTag: v0.10.5` in `newTag: v0.10.4`. Poi:

```powershell
kubectl kustomize kubernetes/environments/dev | Select-String "frontend:v"
kubectl apply -k kubernetes/environments/dev
kubectl rollout status deployment/frontend -n development
kubectl rollout history deployment/frontend -n development
kubectl get rs -n development -l app=frontend
```

Atteso: solo il frontend passa a `v0.10.4`; `deployment.apps/frontend configured`, tutto il resto `unchanged`; rollout completato (le righe `old replicas are pending termination` mostrano il rolling update: il pod vecchio viene spento dopo che il nuovo è pronto); una nuova revisione in cima alla history (i numeri dipendono dalle prove precedenti); il ReplicaSet nuovo con 1 replica e i vecchi a 0. Il port-forward verso Traefik non si interrompe: Traefik segue gli endpoint del Service.

Piano B: [`update-v0104.png`](screenshots/update-rollback/update-v0104.png).

## 8. Failure scenario e troubleshooting

Nello stesso file, `newTag: v0.10.4` → `newTag: v0.10.99` (tag inesistente). Poi:

```powershell
kubectl apply -k kubernetes/environments/dev
kubectl rollout status deployment/frontend -n development --timeout=60s
kubectl get pods -n development -l app=frontend
kubectl get events -n development --sort-by=.lastTimestamp | Select-String "v0.10.99"
1..10 | ForEach-Object { curl.exe -s -o NUL -w "%{http_code} " -H "Host: dev.boutique.localhost" http://localhost:8082/ }
```

Atteso: `rollout status` in timeout; un pod nuovo `0/1 ErrImagePull` o `ImagePullBackOff` e il vecchio `1/1 Running`; negli eventi la sequenza `Pulling` → `Failed` con `code = NotFound ... not found` → `ImagePullBackOff` (il registry ha risposto e il tag non esiste: non è un problema di rete); dieci risposte `200`, perché il pod nuovo non è mai `Ready` e non riceve traffico. Per lo stesso motivo l'allarme `BoutiqueFrontendDown` non scatta: il servizio è disponibile.

Piano B: [`guasto-describe-notfound.png`](screenshots/update-rollback/guasto-describe-notfound.png), [`guasto-servizio-disponibile.png`](screenshots/update-rollback/guasto-servizio-disponibile.png).

## 9. Rollback

Rollback di emergenza:

```powershell
kubectl rollout undo deployment/frontend -n development
kubectl rollout status deployment/frontend -n development
kubectl rollout history deployment/frontend -n development
kubectl get pods -n development -l app=frontend
```

Atteso: `rolled back` e rollout completato in pochi secondi, perché il pod della versione precedente era ancora in esecuzione (è lo stesso pod di prima del guasto, non ricreato); `undo` copia la revisione precedente in una nuova revisione in cima alla history; un avviso su `last-applied-configuration`: il file dice ancora `v0.10.99`, e un nuovo `apply` reintrodurrebbe il guasto.

Riallineamento del repository: nel file, `newTag: v0.10.99` → `newTag: v0.10.5` (versione di partenza, uguale a prod). Poi:

```powershell
kubectl kustomize kubernetes/environments/dev | Select-String "frontend:v"
kubectl apply -k kubernetes/environments/dev
kubectl rollout status deployment/frontend -n development
```

Atteso: dev di nuovo su `v0.10.5`, allineato al repository e a prod.

Facoltativo, per mostrare l'allarme:

```powershell
kubectl scale deployment/frontend --replicas=0 -n development
kubectl scale deployment/frontend --replicas=1 -n development
```

Tra i due comandi: in Prometheus la regola passa da `PENDING` a `FIRING` e l'allarme compare in Alertmanager.

Piano B: [`rollback-undo.png`](screenshots/update-rollback/rollback-undo.png), [`prometheus-alert-firing.png`](screenshots/monitoring/prometheus-alert-firing.png).

## 10. Valutazione Krateo

Documento: [`krateo.md`](krateo.md). Punti da presentare: il golden path "Ambiente Online Boutique" e cosa diventa template (sezione 3); i parametri esposti al team consumer (sezione 4); il prerequisito della conversione in chart Helm (sezione 5); YAML concettuale e componenti esterni al cluster (sezione 6); il diagramma (sezione 7); la distinzione tra blueprint, PoC e adozione (sezione 8); la raccomandazione: non subito, prima chart Helm e PoC, poi pilota con più team (sezione 10).

## 11. Esempio concreto di utilizzo dell'AI

Caso: le immagini "bloccate dalla rete" ([`ai-usage.md`](../ai-usage/ai-usage.md), sezione 5).

- **Input:** pod in `ImagePullBackOff` tranne Redis.
- **Ragionamento e output:** la prima risposta indicava un blocco della rete aziendale; plausibile, ma non verificata.
- **Verifica:** messaggio completo dell'evento e test di raggiungibilità del registry.
- **Valore:** causa vera individuata (immagini senza registry), progetto sbloccato, controllo automatico aggiunto alla pipeline.

Riproduzione dal vivo dell'errore originale (attendere una decina di secondi tra il primo e il secondo comando):

```powershell
kubectl run test-senza-registry --image=frontend --restart=Never -n development
kubectl get events -n development --sort-by=.lastTimestamp | Select-String "test-senza-registry"
kubectl delete pod test-senza-registry -n development
```

Atteso: `pull access denied` su `docker.io/library/frontend:latest`: il nome breve dell'immagine viene completato verso Docker Hub, che risponde che il repository non esiste. Il registry era raggiungibile: il problema era il nome, non la rete.

Piano B: [`describe-pull-access-denied.png`](screenshots/troubleshooting/describe-pull-access-denied.png).

## Verifica finale

```powershell
kubectl get pods -n development
kubectl kustomize kubernetes/environments/dev | Select-String "frontend:v"
.\scripts\smoke-test.ps1
```

Atteso: 11 pod `1/1 Running`, frontend su `v0.10.5` e smoke test `6/6`: ambiente lasciato come all'inizio.