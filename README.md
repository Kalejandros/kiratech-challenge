# Cloud-Native Challenge L2 - Kiratech

Questo repository contiene la configurazione Kubernetes (Kustomize) e la documentazione tecnica per il deployment di Google Cloud Online Boutique su un cluster locale (Docker Desktop), con due ambienti logici: `dev` e `prod`.

> Le parti marcate **[DA COMPLETARE]** non sono ancora state eseguite o provate: vanno completate prima della consegna.

---

## Indice

1. [Scelta dell'applicazione](#1-scelta-dellapplicazione)
2. [Struttura del repository](#2-struttura-del-repository)
3. [Prerequisiti](#3-prerequisiti)
4. [Installazione e test](#4-installazione-e-test-ambiente-dev)
   - [Build dell'immagine del frontend](#47-build-dellimmagine-del-frontend)
5. [Verifica: health check, log, metriche](#5-verifica-health-check-log-metriche)
6. [Update, rollout e rollback](#6-update-rollout-e-rollback)
7. [Troubleshooting: problemi incontrati](#7-troubleshooting-problemi-incontrati)
8. [Sicurezza e configurazione](#8-sicurezza-e-configurazione)
9. [Pipeline CI: validazione dei manifest](#9-pipeline-ci-validazione-dei-manifest)
10. [Limiti noti e punti aperti](#10-limiti-noti-e-punti-aperti)
11. [Documentazione di dettaglio](#11-documentazione-di-dettaglio)

---

## 1. Scelta dell'applicazione

**Applicazione:** Online Boutique di Google Cloud. Repository originale: <https://github.com/GoogleCloudPlatform/microservices-demo>

**Dominio:** e-commerce dimostrativo composto da dieci microservizi (frontend web, catalogo prodotti, carrello, checkout, pagamento simulato, spedizione, email, valute, raccomandazioni, annunci) più Redis per i carrelli. I servizi sono scritti in linguaggi diversi (Go, C#, Node.js, Python, Java) e comunicano via gRPC; il frontend espone HTTP verso l'utente.

**Perché:** è l'applicazione consigliata dalla traccia ed è adatta a una prova L2: è multi-servizio, nasce per Kubernetes, ha dipendenze reali tra i servizi (il checkout ne chiama sei), un componente stateful (Redis), health check nativi e log strutturati. Permette quindi di esercitare deploy, networking, configurazione, sicurezza e troubleshooting su un caso realistico.

**Parti usate:** i manifest Kubernetes della cartella `kubernetes-manifests/` del repository originale, copiati in `kubernetes/base/` senza modifiche, con le immagini ufficiali pubblicate da Google (versione `v0.10.5`). Il `loadgenerator` non è incluso nel deploy. Del codice sorgente è incluso solo quello del frontend (`src/frontend/`, invariato tranne il Dockerfile), usato per la build dell'immagine (sezione 4.7).

**Modifiche rispetto all'originale** (tutte tramite Kustomize, i manifest upstream restano invariati):
- due overlay, `dev` e `prod`, con namespace, immagini con registry e tag espliciti, repliche, limiti e configurazione per ambiente;
- patch di sicurezza nella base: password per Redis da un Secret esterno al repository, token dei ServiceAccount disattivato, ServiceAccount dedicato a Redis, rimozione del Service LoadBalancer upstream;
- risorse aggiunte: Ingress, ruolo RBAC di sola lettura per il supporto operativo;
- metrics-server per le metriche di risorse, uno script per una metrica applicativa ricavata dai log, una pipeline di validazione dei manifest (sezione 9);
- Dockerfile del frontend con immagine di base non root e fissata per digest (sezione 4.7).

## 2. Struttura del repository

```text
.
├── .github/workflows/
│   └── validate-manifests.yml      Pipeline CI: validazione dei manifest
├── kubernetes/
│   ├── base/
│   │   ├── <servizio>.yaml         Manifest upstream di Online Boutique (invariati)
│   │   ├── security-rbac.yaml      ServiceAccount di Redis, ruolo di sola lettura per il supporto L2
│   │   ├── ingress.yaml            Ingress (classe nginx)
│   │   └── kustomization.yaml      Elenco delle risorse e patch di sicurezza
│   ├── environments/
│   │   ├── dev/                    Overlay dev: namespace development, immagini, banner di ambiente
│   │   └── prod/                   Overlay prod: namespace production, 2 repliche del frontend, limiti di memoria
│   └── monitoring/
│       └── metrics-server/         metrics-server v0.9.0 + patch per il cluster locale
├── scripts/
│   └── frontend-metrics.ps1        Metrica applicativa ricavata dai log del frontend
├── src/
│   └── frontend/                   Codice del frontend (upstream v0.10.5) con Dockerfile modificato
├── docs/
│   ├── architecture.md             Documento architetturale
│   ├── log-and-analysis/           Output completi di log e describe
│   └── screenshots/                Evidenze, una cartella per argomento
└── ai-usage/
    └── ai-usage.md                 Uso dell'AI nel progetto
```

Gli overlay non usano `namePrefix` (sezione 7, caso 3): dev e prod sono isolati tramite namespace. Le password di Redis non sono nel repository: si generano e si caricano nel cluster durante l'installazione (sezione 8.2).

## 3. Prerequisiti

- **Docker Desktop** con Kubernetes abilitato. Ambiente di test: nodo singolo `desktop-control-plane`, Kubernetes v1.36.1.
- **kubectl**, che include Kustomize (`kubectl kustomize`, `kubectl apply -k`).
- **PowerShell** (testato con Windows PowerShell 5.1): i comandi del README sono scritti per PowerShell.
- **Accesso di rete in uscita** sulla porta 443 verso `us-central1-docker.pkg.dev` (immagini di Online Boutique) e Docker Hub (`redis:alpine`).
- **Permessi di amministratore sul cluster**, non sul PC: servono per creare namespace, Secret e risorse RBAC e per le verifiche con `kubectl auth can-i --as`. Docker Desktop li concede di default all'utente locale.
- **Git** facoltativo: in alternativa si scarica il repository come ZIP da GitHub.
- **Per la build dell'immagine** (sezione 4.7): accesso a Docker Hub, `gcr.io` e `proxy.golang.org` (dipendenze Go).

## 4. Installazione e test (ambiente dev)

### 4.1 Verifica del cluster
```powershell
kubectl cluster-info
kubectl get nodes
```
Evidenze: [`dev-cluster-info.png`](docs/screenshots/tests/dev/dev-cluster-info.png), [`dev-get-nodes.png`](docs/screenshots/tests/dev/dev-get-nodes.png).

### 4.2 Verifica del rendering dei manifest

```powershell
kubectl kustomize kubernetes/environments/dev
kubectl kustomize kubernetes/environments/dev | Select-String "image:"
```
Le immagini devono avere il formato `us-central1-docker.pkg.dev/google-samples/microservices-demo/<servizio>:v0.10.5` (Redis resta `redis:alpine`).

### 4.3 Creazione del namespace, del Secret e dry-run

Namespace e Secret non sono inclusi nei manifest e vanno creati una volta. La password di Redis è generata e salvata fuori dal progetto (dettagli nella sezione 8.2):

```powershell
kubectl create namespace development
$pw = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 24 | ForEach-Object {[char]$_})
Set-Content -Path "$env:USERPROFILE\redis-password-dev.txt" -Value $pw -NoNewline -Encoding ascii
kubectl create secret generic redis-auth -n development --from-file=REDIS_PASSWORD="$env:USERPROFILE\redis-password-dev.txt"
kubectl apply -k kubernetes/environments/dev --dry-run=client
```

### 4.4 Deploy
```powershell

kubectl apply -k kubernetes/environments/dev
kubectl get pods -n development
kubectl get svc -n development
kubectl get endpoints -n development
```
Dopo circa uno o due minuti tutti gli 11 pod risultano in `1/1 Running`.

Evidenze: [`dev-get-pods.png`](docs/screenshots/tests/dev/dev-get-pods.png), [`dev-get-svc.png`](docs/screenshots/tests/dev/dev-get-svc.png), [`dev-get-endpoints.png`](docs/screenshots/tests/dev/dev-get-endpoints.png)

### 4.5 Accesso all'applicazione

L'Ingress `boutique-ingress` dichiara la classe `nginx`, ma nel cluster non è installato alcun ingress controller: `kubectl get ingressclass` non restituisce risorse, non ci sono pod di ingress in nessun namespace e l'Ingress non ha un indirizzo assegnato (colonna `ADDRESS` vuota). L'oggetto è quindi accettato ma non instrada traffico.

Il Service `frontend` è di tipo ClusterIP, raggiungibile solo dall'interno del cluster. Per i test si usa quindi il port-forward, da lasciare aperto in una finestra dedicata:

```powershell
kubectl port-forward svc/frontend 8080:80 -n development
```

Poi aprire <http://localhost:8080>. Test end-to-end: aggiungere un prodotto al carrello e verificare la conversione di valuta da USD a EUR (attraversa frontend, catalogo, carrello, Redis e servizio valute).

Evidenze: [`dev-ingress-no-controller.png`](docs/screenshots/tests/dev/dev-ingress-no-controller.png), [`dev-home.png`](docs/screenshots/tests/dev/dev-home.png), [`dev-cart.png`](docs/screenshots/tests/dev/dev-cart.png).

### 4.6 Ambiente prod

L'overlay `kubernetes/environments/prod` riusa la stessa base di dev e cambia solo ciò che distingue l'ambiente:

| | dev | prod |
|---|---|---|
| Namespace | `development` | `production` |
| Repliche frontend | 1 | 2 |
| Etichetta `environment` | `dev` | `prod` |
| Memory limit frontend | 128Mi | 256Mi |
| Banner `FRONTEND_MESSAGE` | sì | no |
| Immagini | `v0.10.5` | `v0.10.5` |

```powershell
kubectl create namespace production
$pw = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 24 | ForEach-Object {[char]$_})
Set-Content -Path "$env:USERPROFILE\redis-password-prod.txt" -Value $pw -NoNewline -Encoding ascii
kubectl create secret generic redis-auth -n production --from-file=REDIS_PASSWORD="$env:USERPROFILE\redis-password-prod.txt"
kubectl apply -k kubernetes/environments/prod --dry-run=server
kubectl apply -k kubernetes/environments/prod
kubectl get pods -n production
kubectl port-forward svc/frontend 8081:80 -n production
```

Il frontend di prod è raggiungibile su <http://localhost:8081>, quello di dev su <http://localhost:8080>: i due ambienti possono restare attivi insieme.

Test end-to-end: aggiunta di un prodotto al carrello e checkout completato (pagina "Your order is complete!", con numero di conferma e tracking), a conferma che tutta la catena di servizi funziona nell'ambiente `production`.

Il log di `emailservice` conferma il passaggio dell'ordine nella catena dei servizi: il servizio è avviato in *dummy mode* (l'invio dell'email è simulato, nessun messaggio esce dal cluster) e registra la richiesta di conferma ordine ricevuta dal checkout. I log sono in formato JSON strutturato (`severity`, `name`, `message`).

```powershell
kubectl logs deploy/emailservice -n production --tail=20
```

Evidenze:
- [`prod-create-namespace.png`](docs/screenshots/tests/prod/prod-create-namespace.png), [`prod-kustomize-render.png`](docs/screenshots/tests/prod/prod-kustomize-render.png), [`prod-dry-run-server.png`](docs/screenshots/tests/prod/prod-dry-run-server.png): preparazione e dry-run
- [`prod-apply.png`](docs/screenshots/tests/prod/prod-apply.png), [`prod-get-pods.png`](docs/screenshots/tests/prod/prod-get-pods.png), [`prod-get-svc.png`](docs/screenshots/tests/prod/prod-get-svc.png): deploy
- [`prod-home.png`](docs/screenshots/tests/prod/prod-home.png), [`prod-cart.png`](docs/screenshots/tests/prod/prod-cart.png), [`prod-checkout.png`](docs/screenshots/tests/prod/prod-checkout.png): test end-to-end
- [`prod-emailservice-logs.png`](docs/screenshots/tests/prod/prod-emailservice-logs.png): log di emailservice

### 4.7 Build dell'immagine del frontend

Il cluster usa le immagini ufficiali pubblicate da Google. Per la build, il codice del frontend è stato copiato dal repository originale alla stessa versione (`v0.10.5`, scaricata per tag e non dal ramo principale) in `src/frontend/`. Il codice è invariato; l'unico file modificato è il Dockerfile.

**Il Dockerfile è multi-stage:**
- **stadio `builder`**: parte da `golang:1.25.6-alpine` fissata per digest, scarica le dipendenze (`go mod download`) **prima** di copiare il codice, così lo strato delle dipendenze resta in cache se cambia solo il codice, e compila un binario statico (`CGO_ENABLED=0`, `-ldflags="-s -w"`);
- **stadio finale**: immagine *distroless*, senza shell né gestore di pacchetti, in cui vengono copiati solo il binario, i template HTML e i file statici. Il compilatore non finisce nell'immagine finale.

**Modifiche rispetto al Dockerfile upstream:**

| | Upstream | Questo repository |
|---|---|---|
| Immagine finale | `gcr.io/distroless/static`, senza digest | `gcr.io/distroless/static:nonroot@sha256:d6206787...`, fissata per digest |
| Utente predefinito | `0` (root) | `65532` (`nonroot`) |
| Metadati | — | Etichette OCI: sorgente, versione, descrizione |

Nel cluster il container gira comunque come utente 1000 (`runAsUser` nel manifest); l'immagine `nonroot` rende sicura anche l'esecuzione fuori da Kubernetes. Il digest fissa l'immagine di base byte per byte: gli aggiornamenti di sicurezza vanno quindi applicati aggiornando il digest in modo esplicito (es. con Dependabot o Renovate).

**Build e verifica:**

```powershell
docker build -t boutique-frontend:v0.10.5-nonroot src\frontend
docker images boutique-frontend
docker inspect --format "{{.Config.User}}" boutique-frontend:v0.10.5-nonroot
docker inspect --format "{{json .Config.Labels}}" boutique-frontend:v0.10.5-nonroot
```

- Immagine finale: **12 MB** compressi (circa 41 MB su disco), contro i circa 60 MB del solo stadio di compilazione.
- Prima build 83 secondi; la seconda 25 secondi, perché `go mod download` è stato riutilizzato dalla cache. La compilazione è stata rifatta perché `COPY . .` include anche il Dockerfile, appena modificato: aggiungere `Dockerfile` al `.dockerignore` eviterebbe di invalidare quello strato.
- Utente `65532` ed etichette OCI presenti.

**Configurazione tramite variabili d'ambiente.** L'immagine non contiene indirizzi né configurazione: arrivano a runtime, nel cluster dal manifest. Senza variabili il frontend si rifiuta di partire e indica quale manca:

```powershell
docker run --name frontend-test boutique-frontend:v0.10.5-nonroot
```

Risultato: `panic: environment variable "PRODUCT_CATALOG_SERVICE_ADDR" not set`. Con le stesse variabili del manifest il server parte e l'health check risponde:

```powershell
docker run -d --name frontend-nonroot -p 9090:8080 -e PORT=8080 -e PRODUCT_CATALOG_SERVICE_ADDR=productcatalogservice:3550 -e CURRENCY_SERVICE_ADDR=currencyservice:7000 -e CART_SERVICE_ADDR=cartservice:7070 -e RECOMMENDATION_SERVICE_ADDR=recommendationservice:8080 -e SHIPPING_SERVICE_ADDR=shippingservice:50051 -e CHECKOUT_SERVICE_ADDR=checkoutservice:5050 -e AD_SERVICE_ADDR=adservice:9555 -e SHOPPING_ASSISTANT_SERVICE_ADDR=shoppingassistantservice:80 boutique-frontend:v0.10.5-nonroot
(Invoke-WebRequest http://localhost:9090/_healthz -UseBasicParsing).Content
docker rm -f frontend-nonroot
```

Risultato: `starting server on :8080` nei log e `ok` dall'health check. I log contengono due righe di errore sul metadata server `169.254.169.254`: all'avvio il frontend prova a leggere nome del cluster e zona dal metadata server di Google Cloud, che fuori da GCP non esiste. Sono innocue: il server prosegue con quei campi vuoti.

**Uso nel cluster.** Un pod con l'immagine locale e `imagePullPolicy: Never` resta in `ErrImageNeverPull`: il nodo del cluster di Docker Desktop (basato su kind) ha un archivio di immagini separato da quello di Docker sul PC. Per usare l'immagine nel cluster va pubblicata su un registry; un riferimento senza registry sarebbe comunque bloccato dalla pipeline (sezione 9).

Evidenze:
- [`run-senza-env.png`](docs/screenshots/build/run-senza-env.png): avvio senza variabili d'ambiente
- [`run-con-env.png`](docs/screenshots/build/run-con-env.png): immagine originale, health check `ok`, home `500`, utente `0` (root)
- [`run-nonroot.png`](docs/screenshots/build/run-nonroot.png): immagine `nonroot`, utente `65532`, etichette OCI, health check `ok`
- [`cluster-non-vede-immagine.png`](docs/screenshots/build/cluster-non-vede-immagine.png): `ErrImageNeverPull` nel cluster

## 5. Verifica: health check, log, metriche

### 5.1 Health check

```powershell
Invoke-WebRequest http://localhost:8080/_healthz -UseBasicParsing
```

Risposta attesa: `StatusCode 200`, contenuto `ok`. 
Lo stesso endpoint è usato dalle probe di liveness e readiness del frontend; gli altri servizi usano probe gRPC native di Kubernetes.

Evidenza: [`dev-health-check.png`](docs/screenshots/tests/dev/dev-health-check.png).

### 5.2 Log

Il nome dei pod ha un suffisso casuale, quindi si interrogano i Deployment.

**Frontend (log strutturati JSON):**

```powershell
kubectl logs deploy/frontend -n development --tail=50
```

I log sono in formato JSON strutturato (`http.req.path`, `http.resp.status`, `severity`, `timestamp`). Il file contiene le richieste a `/_healthz` con sessione `x-readiness-probe` e `x-liveness-probe`, tutte con stato 200: sono le probe di Kubernetes, ciascuna ogni 10 secondi, come configurato nel `describe` (sezione 5.3). Output completo: [`frontend-logs.txt`](docs/log-and-analysis/frontend-logs.txt)

**Redis:**

```powershell
kubectl logs deploy/redis-cart -n development
```

Righe significative: `Ready to accept connections tcp` (avvio corretto) e `WARNING: Redis does not require authentication and is not protected by network restrictions`.
Il warning si riferisce alla configurazione upstream: dopo l'introduzione della password (sezione 8.2) Redis richiede autenticazione.

Output completo: [`redis-cart-logs.txt`](docs/log-and-analysis/redis-cart-logs.txt)

### 5.3 Stato del pod (`describe`)

```powershell
kubectl describe pod -l app=frontend -n development
```

Output completo: [`frontend-describe.txt`](docs/log-and-analysis/frontend-describe.txt)

Cosa si legge nell'output:
- probe di **liveness** e **readiness** HTTP su `/_healthz` (delay 10s, period 10s, 3 fallimenti consentiti): corrispondono alle richieste che compaiono nei log del frontend (sezione 5.2);
- pod `Running`, `Ready: True`, tutte le condizioni `True`;
- ServiceAccount dedicato (`frontend`) e risorse definite (requests 100m / 64Mi, limits 200m / 128Mi);
- immagine `frontend:v0.10.5` (stato precedente alle prove della sezione 6).

Il contatore di riavvii è 1: il container è stato ricreato (evento `SandboxChanged`, exit code 255, senza errore applicativo). È coerente con un riavvio del runtime locale (ipotesi non verificata); Kubernetes ha riportato il pod in `Ready` autonomamente.

### 5.4 Metriche

Il frontend di Online Boutique non espone metriche Prometheus di default. Le metriche disponibili sono due: risorse dei pod (metrics-server) e una metrica applicativa ricavata dai log.

#### Risorse di nodo e pod (metrics-server)

Docker Desktop non include metrics-server: prima dell'installazione `kubectl top nodes` e `kubectl top pods` restituiscono `error: Metrics API not available`, perché l'API `metrics.k8s.io` non è registrata nel cluster.

Evidenza: [`top-senza-metrics-server.png`](docs/screenshots/metriche/top-senza-metrics-server.png)

metrics-server (versione fissa v0.9.0) è in `kubernetes/monitoring/metrics-server/`: il manifest ufficiale `components.yaml` non modificato e una `kustomization.yaml` che aggiunge `--kubelet-insecure-tls` (vedi sezione 7, caso 5).
L'opzione serve sul cluster locale Docker Desktop per un errore di verifica del certificato dei nodi e non è adatta a produzione.

```powershell
kubectl apply -k kubernetes/monitoring/metrics-server
kubectl top nodes
kubectl top pods -n development
kubectl top pods -n production
```

| Comando | Cosa fa | Come leggere l'output |
|---|---|---|
| `kubectl apply -k <cartella>` | Costruisce i manifest con Kustomize e li applica al cluster | `unchanged` = la risorsa corrisponde già a quella nel repository; `configured` = è stata aggiornata |
| `kubectl top nodes` | Mostra CPU e memoria usate dal nodo | `3%` e `19%` = quota della capacità totale |
| `kubectl top pods -n <namespace>` | Mostra CPU e memoria usate da ogni pod | `1m` = un millesimo di core; i valori vanno confrontati con requests e limits dei manifest |

Risultati: i consumi sono molto inferiori ai limiti (per esempio frontend 6Mi su 128Mi) e la CPU usata (1-6m) è molto più bassa delle requests (100-200m), con traffico quasi nullo. In prod il frontend ha due repliche, come definito nell'overlay.

Evidenze: 
[`apply.png`](docs/screenshots/metriche/apply.png) (installazione), [`pod-running.png`](docs/screenshots/metriche/pod-running.png) (pod in esecuzione), [`top-nodes.png`](docs/screenshots/metriche/top-nodes.png), [`dev-prod-top-pods.png`](docs/screenshots/metriche/dev-prod-top-pods.png), [`kustomize-render.png`](docs/screenshots/metriche/kustomize-render.png) (rendering con la patch)

#### Metrica applicativa derivata dai log

```powershell
.\scripts\frontend-metrics.ps1
```

| Passo dello script | Cosa fa |
|---|---|
| `kubectl logs deploy/frontend -n development --tail=1000` | Legge le ultime 1000 righe di log del frontend |
| Filtro `request complete` ed esclusione di `_healthz` | Tiene solo le richieste concluse e scarta le probe di Kubernetes |
| `ConvertFrom-Json` | Trasforma ogni riga JSON in oggetto per leggerne i campi |
| `Group-Object` / `Measure-Object` | Conta richieste per stato e percorso e calcola minimo, media e massimo della latenza (`http.resp.took_ms`) |
|Ordinamento dei valori di latenza | Calcola mediana, 95° percentile e le 5 richieste più lente con l'orario |

Su 35 richieste alla home (`/`), tutte con stato `200`, la latenza è risultata di 23 ms al minimo, 32 ms di mediana, 61 ms in media, 165 ms al 95° percentile e 515 ms al massimo. 
Le richieste più lente sono ravvicinate e la più lenta è la prima del gruppo: è coerente con l'apertura a freddo delle connessioni verso gli altri servizi(ipotesi, non verificata).
In una prima esecuzione era stato registrato un massimo di 6871 ms; non è più ricostruibile perché la richiesta è uscita dalla finestra dei log analizzata, quindi la causa non è determinata.

Non è una metrica esposta in tempo reale: per esporla servirebbe strumentare il frontend con le librerie Prometheus (vedi sezione 10).

Evidenza: 
[`frontend-metrics.png`](docs/screenshots/metriche/frontend-metrics.png), output completo: [`frontend-metrics.txt`](docs/log-and-analysis/frontend-metrics.txt)

## 6. Update, rollout e rollback

Tutte le prove sono state eseguite sul frontend dell'ambiente dev. Il tag dell'immagine si cambia nel blocco `images:` di `kubernetes/environments/dev/kustomization.yaml` (campo `newTag`), così ogni modifica passa dal repository.

Evidenze: `docs/screenshots/update-rollback/`.

### 6.1 Strategia di rollout

Il Deployment del frontend usa la strategia predefinita `RollingUpdate` con `maxSurge: 25%` e `maxUnavailable: 25%`. Con una sola replica i valori diventano 1 pod in più (arrotondamento per eccesso) e 0 pod non disponibili (arrotondamento per difetto): Kubernetes crea prima il pod nuovo e spegne quello vecchio solo quando il nuovo è `Ready`. È questo comportamento che protegge il servizio nel failure scenario (6.3).

I ReplicaSet delle versioni precedenti restano nel cluster a 0 repliche (`revisionHistoryLimit`, default 10) e sono la base del rollback.

### 6.2 Update: frontend da v0.10.5 a v0.10.4

Nel `kustomization.yaml` di dev il `newTag` del frontend passa da `v0.10.5` a `v0.10.4`. La versione precedente è scelta solo perché è disponibile nel registry: serve a provare il meccanismo di update, non a introdurre funzionalità.

```powershell
kubectl kustomize kubernetes/environments/dev | Select-String "frontend:v"
kubectl apply -k kubernetes/environments/dev
kubectl rollout status deployment/frontend -n development
kubectl rollout history deployment/frontend -n development
kubectl get rs -n development -l app=frontend
```

Risultato: rollout completato, revisioni 1 (`v0.10.5`) e 2 (`v0.10.4`). Il ReplicaSet di `v0.10.4` ha 1 replica, quello di `v0.10.5` resta a 0.

Evidenza: [`update-v0104.png`](docs/screenshots/update-rollback/update-v0104.png)

### 6.3 Failure scenario: tag inesistente

Si imposta `newTag: v0.10.99`, un tag che non esiste nel registry, e si applica:

```powershell
kubectl apply -k kubernetes/environments/dev
kubectl rollout status deployment/frontend -n development --timeout=60s
kubectl rollout history deployment/frontend -n development --revision=3
kubectl get pods -n development -l app=frontend -o wide
kubectl get rs -n development -l app=frontend
```

Cosa si osserva:
- `rollout status` va in timeout (`1 old replicas are pending termination`): il rollout non si completa;
- la history ha una revisione 3 con immagine `frontend:v0.10.99`;
- il pod nuovo è `0/1 ImagePullBackOff`, il pod vecchio (`v0.10.4`) resta `1/1 Running`;
- il ReplicaSet nuovo ha `DESIRED 1 / READY 0`, quello di `v0.10.4` `READY 1`.

**Impatto sul servizio: nessuno.** Il pod nuovo non diventa mai `Ready`, quindi non entra negli endpoint del Service, che contengono solo l'IP del pod vecchio:

```powershell
kubectl get endpoints frontend -n development
1..10 | ForEach-Object { (Invoke-WebRequest http://localhost:8080/ -UseBasicParsing).StatusCode }
kubectl logs <pod-v0.10.4> -n development --tail=5
```

10 richieste su 10 restituiscono `200`; i log del pod vecchio mostrano `GET /` con stato 200 e le probe `/_healthz` regolari.

> Su Kubernetes 1.33+ `kubectl get endpoints` stampa un avviso di deprecazione; l'equivalente attuale è `kubectl get endpointslices -n development -l kubernetes.io/service-name=frontend`.

**Diagnosi:**

```powershell
kubectl describe pod <pod-v0.10.99> -n development | Select-String "Image:|Failed|Back-off|not found|Events"
kubectl get events -n development --sort-by=.lastTimestamp
```

Gli eventi mostrano la sequenza `Pulling` → `ErrImagePull` → `BackOff` / `ImagePullBackOff`, con il messaggio `code = NotFound ... not found`. `NotFound` significa che il registry è stato raggiunto ma il tag non esiste: il problema è nel manifest, non nella rete (un problema di rete darebbe un timeout, un problema di nome o di permessi darebbe `pull access denied`; vedi sezione 7).

Kubernetes non esegue un rollback automatico: dopo `progressDeadlineSeconds` (default 600 s) il Deployment segna la condizione `Progressing=False` con motivo `ProgressDeadlineExceeded`, ma il pod rotto resta finché non si interviene.

Evidenze:
- [`guasto-revisione3.png`](docs/screenshots/update-rollback/guasto-revisione3.png): history e dettaglio della revisione 3
- [`guasto-stato-pod-endpoints.png`](docs/screenshots/update-rollback/guasto-stato-pod-endpoints.png): timeout, pod, ReplicaSet, endpoint
- [`guasto-immagine-ready.png`](docs/screenshots/update-rollback/guasto-immagine-ready.png): immagine e readiness dei due pod
- [`guasto-servizio-disponibile.png`](docs/screenshots/update-rollback/guasto-servizio-disponibile.png): 10 richieste con stato 200
- [`guasto-log-pod-vecchio.png`](docs/screenshots/update-rollback/guasto-log-pod-vecchio.png): log del pod `v0.10.4`
- [`guasto-describe-notfound.png`](docs/screenshots/update-rollback/guasto-describe-notfound.png): errore `NotFound`
- [`guasto-eventi.png`](docs/screenshots/update-rollback/guasto-eventi.png): cronologia degli eventi

### 6.4 Rollback imperativo (`kubectl rollout undo`)

```powershell
kubectl rollout undo deployment/frontend -n development
kubectl rollout status deployment/frontend -n development
kubectl get rs -n development -l app=frontend -o wide
kubectl rollout history deployment/frontend -n development
```

Risultato:
- `rolled back` e `successfully rolled out` in pochi secondi: il pod `v0.10.4` era già in esecuzione, il ReplicaSet di `v0.10.99` viene portato a 0 e il pod rotto eliminato;
- il pod del frontend è lo stesso di prima del guasto (stessa età del ReplicaSet di `v0.10.4`): non è mai stato ricreato;
- la history diventa **1, 3, 4**: `undo` torna alla revisione precedente (2), ne copia il template in una nuova revisione (4) e la 2 non compare più.

kubectl stampa un avviso: il Deployment era gestito con `kubectl apply` e `rollout undo` non aggiorna l'annotazione `kubectl.kubernetes.io/last-applied-configuration`. Dopo l'undo il cluster è su `v0.10.4`, mentre l'annotazione e il file nel repository indicano ancora `v0.10.99`: un `kubectl apply -k` lanciato a questo punto reintrodurrebbe il guasto.

Evidenze: [`rollback-undo.png`](docs/screenshots/update-rollback/rollback-undo.png), [`rollback-verifica.png`](docs/screenshots/update-rollback/rollback-verifica.png)

### 6.5 Rollback dichiarativo (riallineamento del repository)

Si riporta `newTag` a `v0.10.4` nel file e si riapplica:

```powershell
kubectl kustomize kubernetes/environments/dev | Select-String "frontend:v"
kubectl apply -k kubernetes/environments/dev
kubectl rollout history deployment/frontend -n development
```

Il frontend risulta `configured` perché viene aggiornata l'annotazione `last-applied-configuration`, ma la history resta 1, 3, 4: il template dei pod non cambia, quindi non parte un nuovo rollout e il pod non viene toccato. Repository e cluster sono di nuovo allineati.

Al termine delle prove il frontend di dev è stato riportato a `v0.10.5` con un normale update dichiarativo. Kubernetes ha riutilizzato il ReplicaSet della revisione 1, rinumerandolo come revisione 5 (history finale: 3, 4, 5), quindi dev e prod sono di nuovo sulla stessa versione.

> `kubectl diff -k` sarebbe il controllo naturale prima dell'apply, ma su Windows richiede un programma `diff` nel PATH (per esempio quello di Git for Windows) o la variabile `KUBECTL_EXTERNAL_DIFF`. Nell'ambiente di test non era disponibile, quindi la verifica è stata fatta sul rendering di `kubectl kustomize`.

Evidenza: [`rollback-dichiarativo.png`](docs/screenshots/update-rollback/rollback-dichiarativo.png)

### 6.6 Perché due metodi 

| | `kubectl rollout undo` | file + `kubectl apply -k` |
|---|---|---|
| Ruolo | Emergenza: ripristina subito il servizio | Riallinea la fonte di verità |
| Velocità | Immediato, non richiede modifiche al repository | Richiede modifica del file e commit |
| Stato del repository | Resta disallineato | Repository e cluster coerenti |

Il primo ferma il danno, il secondo chiude il disallineamento: vanno usati in sequenza. In un flusso GitOps (pipeline o Argo CD/Flux) il rollback di riferimento è un `git revert` del commit che ha introdotto il guasto, riapplicato automaticamente; `rollout undo` resta la leva rapida, da seguire sempre con il riallineamento del repository, altrimenti il deploy successivo ripristina la versione rotta.

Possibili miglioramenti:
- annotazione `kubernetes.io/change-cause` sul template, per una history leggibile (oggi la colonna `CHANGE-CAUSE` è `<none>`);
- `progressDeadlineSeconds` più basso e `kubectl rollout status --timeout` nella pipeline, per accorgersi subito di un rollout bloccato.

## 7. Troubleshooting: problemi incontrati

Problemi reali emersi durante il lavoro. Per ognuno: sintomo, ipotesi iniziale, verifica, causa, soluzione. Dove il problema originale non era più presente nel cluster, la causa è stata riprodotta in piccolo (pod di prova o solo rendering, senza modificare gli ambienti).

Metodo seguito, dal generale al particolare: `kubectl get pods` (quale componente è in errore) → `kubectl describe` / `kubectl get events` (perché) → `kubectl logs` (cosa vede l'applicazione) → una verifica mirata che conferma o smentisce l'ipotesi.

| # | Sintomo | Causa | Soluzione |
|---|---|---|---|
| 1 | Tutti i pod in `ImagePullBackOff` tranne Redis | Immagini senza registry e tag, risolte su Docker Hub | Blocco `images:` con registry e tag espliciti |
| 2 | `ImagePullBackOff` con `NotFound` | Tag `v0.10.6` non pubblicato nel registry | Tag `v0.10.5` |
| 3 | Errore 500 sul frontend | `namePrefix` rinomina i Service ma non gli indirizzi nelle variabili d'ambiente | Rimosso `namePrefix`, isolamento tramite namespace |
| 4 | `rollout undo` → `no rollout history found` | `set image` con la stessa immagine non crea una nuova revisione | Nessun errore reale: serve una revisione precedente |
| 5 | `kubectl top` → Metrics API non disponibile | metrics-server non riesce a verificare il certificato dei kubelet | `--kubelet-insecure-tls`, solo in locale |

### 7.1 Caso 1 — `ImagePullBackOff` su tutti i servizi tranne Redis

**Sintomo:** dopo il primo deploy (allora con `namePrefix: dev-`) tutti i pod erano `0/1 ImagePullBackOff`, tranne `redis-cart` in `Running`.

**Ipotesi iniziale (errata):** blocco della rete aziendale. Sembrava confermata da due indizi: durante la configurazione Windows aveva chiesto un'autorizzazione di accesso alla rete che non è stato possibile concedere, e Redis funzionava. In realtà Redis funzionava solo perché la sua immagine (`redis:alpine`) era già presente in cache sul nodo.

**Verifica:** i manifest originali usano nomi di immagine brevi (`image: frontend`), sostituiti di norma dagli strumenti di build del progetto upstream. Riprodotto con un pod di prova:

```powershell
kubectl run test-senza-registry --image=frontend --restart=Never -n development
kubectl describe pod test-senza-registry -n development | Select-String "Image:|Failed|denied|docker.io|BackOff"
kubectl delete pod test-senza-registry -n development
```

**Causa:** senza registry e senza tag Kubernetes completa il nome in `docker.io/library/frontend:latest`, un repository che su Docker Hub non esiste. Il messaggio `pull access denied, repository does not exist or may require authorization ... insufficient_scope` fa pensare a un problema di permessi, ma è la risposta del server: la rete funzionava.

**Soluzione:** blocco `images:` negli overlay con registry e tag espliciti per ogni servizio:

```yaml
images:
  - name: frontend
    newName: us-central1-docker.pkg.dev/google-samples/microservices-demo/frontend
    newTag: v0.10.5
```

**Cosa insegna:** leggere il messaggio completo dell'evento, non solo lo stato. Un servizio che funziona non prova che la rete sia aperta: la sua immagine può essere in cache.

Evidenze:
- [`imagepullbackoff-pod.png`](docs/screenshots/troubleshooting/imagepullbackoff-pod.png): pod in errore, Redis in esecuzione
- [`describe-pull-access-denied.png`](docs/screenshots/troubleshooting/describe-pull-access-denied.png): riproduzione dell'errore

### 7.2 Caso 2 — Tag `v0.10.6` inesistente nel registry

**Sintomo:** con le immagini corrette ma tag `v0.10.6` i pod restavano in `ImagePullBackOff`.

**Ipotesi iniziale:** `v0.10.6` è l'ultima release su GitHub, quindi doveva essere utilizzabile (indicazione arrivata dall'assistente AI e non verificata subito, vedi [`ai-usage`](ai-usage/ai-usage.md)).

**Verifica:**

```powershell
Test-NetConnection us-central1-docker.pkg.dev -Port 443
kubectl run test-tag-v0106 --image=us-central1-docker.pkg.dev/google-samples/microservices-demo/frontend:v0.10.6 --restart=Never -n development
kubectl describe pod test-tag-v0106 -n development | Select-String "Image:|Failed|NotFound|not found|BackOff"
kubectl delete pod test-tag-v0106 -n development
```

`TcpTestSucceeded : True` indica che il registry è raggiungibile (il test parte da Windows; la conferma definitiva è che le immagini `v0.10.5` dello stesso registry vengono scaricate). L'errore è `code = NotFound ... v0.10.6: not found`.

**Causa:** la release `v0.10.6` esiste su GitHub, ma le immagini corrispondenti non sono pubblicate nel registry. `v0.10.5` e `v0.10.4` sono disponibili.

**Soluzione:** tag `v0.10.5` per tutti i servizi.

**Cosa insegna:** `pull access denied` (caso 1) e `NotFound` (caso 2) sono errori diversi: nel primo il repository non esiste o non è accessibile, nel secondo il repository esiste ma il tag no. Un tag va verificato nel registry, non dedotto dalle release del codice sorgente.

Evidenze:
- [`test-connection.png`](docs/screenshots/troubleshooting/test-connection.png)
- [`describe-tag-notfound.png`](docs/screenshots/troubleshooting/describe-tag-notfound.png)

### 7.3 Caso 3 — Errore 500 sul frontend con `namePrefix`

**Sintomo:** con tutti i pod `Running`, la home del negozio restituiva errore 500 e il log del frontend riportava `lookup currencyservice ... i/o timeout`.

**Verifica:** rendering di un overlay temporaneo con `namePrefix: test-`, senza deploy:

```powershell
New-Item -ItemType Directory kubernetes/environments/test-nameprefix
Set-Content kubernetes/environments/test-nameprefix/kustomization.yaml -Encoding ascii -Value "resources:`n- ../../base`nnamePrefix: test-"
kubectl kustomize kubernetes/environments/test-nameprefix | Select-String "name: test-currencyservice|CURRENCY_SERVICE_ADDR" -Context 0,1
Remove-Item -Recurse kubernetes/environments/test-nameprefix
```

**Causa:** Kustomize rinomina le risorse (`name: test-currencyservice`) e aggiorna i riferimenti strutturati che conosce (per esempio `serviceAccountName: test-currencyservice`), ma non le stringhe libere nelle variabili d'ambiente: `CURRENCY_SERVICE_ADDR` resta `currencyservice:7000`, sia nel frontend sia nel checkoutservice. Il DNS del cluster non trovava più un Service con quel nome.

**Soluzione:** rimosso `namePrefix` dagli overlay. Dev e prod sono isolati tramite namespace (`development`, `production`): dentro ogni namespace i Service mantengono i nomi originali e gli indirizzi nelle variabili d'ambiente restano validi. L'alternativa (patch di tutte le variabili d'ambiente per ambiente) era più fragile.

**Cosa insegna:** con Kustomize va controllato il rendering (`kubectl kustomize`) e non solo l'esito dell'apply: i manifest erano validi e i pod sani, ma l'applicazione no.

Evidenza: [`nameprefix-rendering.png`](docs/screenshots/troubleshooting/nameprefix-rendering.png)

### 7.4 Caso 4 — Rollback "fallito": `no rollout history found`

**Sintomo:** dopo un `kubectl set image` e un `rollout status` riuscito, `kubectl rollout undo` restituiva `error: no rollout history found`.

**Ipotesi iniziale (errata):** una prima versione di questa documentazione attribuiva il problema a Kustomize.

**Causa:** `set image` era stato lanciato con la stessa immagine già in uso (`redis=redis:alpine`). Il template dei pod non cambiava, quindi Kubernetes non ha creato una nuova revisione: `rollout status` riportava correttamente "successfully rolled out" perché non c'era niente da aggiornare, e `undo` non aveva una revisione precedente a cui tornare.

**Soluzione:** nessun errore da correggere. Il rollback va provato dopo un update che cambia davvero il template, come nella sezione 6 (revisioni 1 → 2 → 3 → undo).

**Cosa insegna:** una nuova revisione nasce solo se cambia il template dei pod. `rollout history` va controllato prima di contare su un rollback.

Evidenza: [`undo-senza-revisioni.png`](docs/screenshots/troubleshooting/undo-senza-revisioni.png)

### 7.5 Caso 5 — metrics-server non pronto

**Sintomo:** dopo l'installazione metrics-server restava `0/1` e `kubectl top` rispondeva che la Metrics API non era disponibile.

**Causa:** metrics-server interroga i kubelet via HTTPS e ne verifica il certificato. Sul cluster locale di Docker Desktop il certificato del kubelet non è verificabile da metrics-server, quindi le richieste falliscono e la readiness non passa.

**Soluzione:** argomento `--kubelet-insecure-tls`, aggiunto con una patch nella `kustomization.yaml` di `kubernetes/monitoring/metrics-server/`, lasciando invariato il manifest ufficiale:

```powershell
kubectl get deployment metrics-server -n kube-system -o jsonpath="{.spec.template.spec.containers[0].args}"
kubectl top nodes
```

**Limite:** l'opzione disattiva la verifica del certificato del kubelet ed è accettabile solo in locale. In produzione si usano certificati dei kubelet firmati dalla CA del cluster (`serverTLSBootstrap` con approvazione delle richieste di certificato), senza disattivare la verifica.

Evidenze: [`metrics-server-args.png`](docs/screenshots/troubleshooting/metrics-server-args.png)


## 8. Sicurezza e configurazione

Le modifiche sono applicate con patch Kustomize in `kubernetes/base/kustomization.yaml` e negli overlay: i manifest upstream di Online Boutique restano invariati. Tutte le prove sono state eseguite in dev e le stesse modifiche applicate a prod.

Evidenze: `docs/screenshots/security/`.

### 8.1 Punto di partenza

I manifest upstream hanno già una base solida, mantenuta così com'è:
- ogni microservizio ha un ServiceAccount dedicato;
- i container girano come utente non root (`runAsNonRoot`, uid 1000), senza privilege escalation, con tutte le capabilities rimosse (`drop: ALL`) e filesystem in sola lettura (`readOnlyRootFilesystem`);
- requests e limits di CPU e memoria su tutti i container.

Problemi individuati e corretti:

| Problema | Correzione |
|---|---|
| Password Redis in chiaro in un Secret nel repository, non usata da nessun componente | Secret creato fuori dal repository e usato davvero da Redis e cartservice (8.2) |
| Token del ServiceAccount montato in tutti i pod, anche se nessun servizio usa l'API di Kubernetes | `automountServiceAccountToken: false` (8.3) |
| `redis-cart` con il ServiceAccount `default` | ServiceAccount dedicato `redis-cart` |
| Role e ServiceAccount non associati a nessun pod | Sostituiti da un ruolo di sola lettura per il supporto operativo (8.4) |
| ConfigMap che duplicava le variabili d'ambiente, non usata dai pod | Sostituita da una configurazione reale per ambiente (8.5) |
| Service `frontend-external` di tipo LoadBalancer, esposto aggirando l'Ingress | Rimosso (8.6) |

### 8.2 Secret fuori dal repository: password di Redis

Nella configurazione upstream Redis non richiede autenticazione: qualsiasi pod del cluster che raggiunge `redis-cart:6379` può leggere e scrivere i carrelli (lo segnala anche il log di Redis, sezione 5.2).

**Creazione del Secret**, una volta per namespace, con una password diversa per ogni ambiente:

```powershell
$pw = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 24 | ForEach-Object {[char]$_})
Set-Content -Path "$env:USERPROFILE\redis-password-dev.txt" -Value $pw -NoNewline -Encoding ascii
kubectl create secret generic redis-auth -n development --from-file=REDIS_PASSWORD="$env:USERPROFILE\redis-password-dev.txt"
kubectl describe secret redis-auth -n development
```

- La password è generata casualmente e salvata **fuori dalla cartella del progetto**, quindi non può finire nel repository.
- `--from-file` invece di `--from-literal`: la password non resta nella cronologia dei comandi.
- `-NoNewline`: senza, il file conterrebbe un "a capo" finale che diventerebbe parte della password.
- `describe` mostra solo la lunghezza (`24 bytes`), mai il valore.

**Uso del Secret** (patch nella base):
- Redis riceve la password come variabile d'ambiente (`secretKeyRef`) e parte con `--requirepass $(REDIS_PASSWORD)`;
- cartservice riceve la stessa variabile e la usa nella stringa di connessione: `REDIS_ADDR=redis-cart:6379,password=$(REDIS_PASSWORD)`. La sintassi `$(VAR)` è di Kubernetes: nel manifest e nel `describe` resta scritto letteralmente `$(REDIS_PASSWORD)`, il valore esiste solo nel container in esecuzione.

**Verifiche:**

```powershell
kubectl exec deploy/redis-cart -n development -- redis-cli ping
kubectl exec deploy/redis-cart -n development -- sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning dbsize'
kubectl logs deploy/cartservice -n development | Select-String -SimpleMatch (Get-Content "$env:USERPROFILE\redis-password-dev.txt")
```

- senza password Redis risponde `NOAUTH Authentication required.`;
- con la password del Secret risponde `1` (il carrello creato dal browser): il cartservice si autentica correttamente;
- la password non compare nei log del cartservice (nessun risultato).

Test end-to-end: prodotto aggiunto al carrello e checkout completato, in dev e in prod.

**Prova: deploy senza Secret.** Overlay di dev riapplicato in un namespace di prova (`test-secret`) in cui `redis-auth` non esiste:

```powershell
kubectl get pods -n test-secret
kubectl describe pod -l app=redis-cart -n test-secret | Select-String "State|Reason|Warning|not found"
```

Il deploy è accettato senza errori, ma `redis-cart` e `cartservice` restano `0/1 CreateContainerConfigError` con l'evento `Error: secret "redis-auth" not found`; gli altri servizi partono. A differenza di `ImagePullBackOff` (immagine) o `CrashLoopBackOff` (applicazione), `CreateContainerConfigError` indica che il container non è mai partito perché manca una configurazione: i log non esistono, va controllata la presenza di Secret e ConfigMap.

Creato il Secret, gli stessi pod (stesso nome, `RESTARTS 0`) sono passati a `Running` senza redeploy: il kubelet riprova finché la configurazione non è disponibile. Per questo la creazione del Secret è un passo dell'installazione (sezioni 4.3 e 4.6).

Evidenze: [`secret-mancante.png`](docs/screenshots/troubleshooting/secret-mancante.png), [`secret-mancante-risolto.png`](docs/screenshots/troubleshooting/secret-mancante-risolto.png)

### 8.3 Token del ServiceAccount disattivato

Kubernetes monta di default in ogni pod un volume `kube-api-access-*` con un token che permette di autenticarsi all'API del cluster con l'identità del ServiceAccount. Nessun servizio di Online Boutique usa l'API di Kubernetes, quindi il token è una credenziale inutile: in caso di compromissione di un container sarebbe a disposizione di chi l'ha compromesso.

Una patch nella base aggiunge `automountServiceAccountToken: false` a tutti i ServiceAccount. L'impostazione vale per i pod creati dopo la modifica, quindi è stato necessario un riavvio controllato:

```powershell
kubectl get pods -n development -o custom-columns=NAME:.metadata.name,VOLUMI:.spec.volumes[*].name
kubectl rollout restart deployment -n development
kubectl get pods -n development -o custom-columns=NAME:.metadata.name,VOLUMI:.spec.volumes[*].name
```

Prima del riavvio 10 pod su 11 avevano il volume `kube-api-access-*`; dopo, nessuno (Redis mostra solo il proprio volume `redis-data`). Dopo il riavvio home, health check, carrello e checkout funzionano: nessun servizio usava il token.

Evidenze: [`token-prima-restart.png`](docs/screenshots/security/token-prima-restart.png), [`restart.png`](docs/screenshots/security/restart.png), [`token-dopo-restart.png`](docs/screenshots/security/token-dopo-restart.png), [`test-dopo-restart.png`](docs/screenshots/security/test-dopo-restart.png)

### 8.4 RBAC: ruolo di sola lettura per il supporto L2

L'applicazione non ha bisogno di permessi sull'API di Kubernetes, quindi i suoi ServiceAccount non hanno Role associati. RBAC è usato invece per chi opera sul sistema: il ServiceAccount `boutique-ops-viewer` (in `security-rbac.yaml`) ha un Role di sola lettura su pod, log, eventi, Service, endpoint, Deployment, ReplicaSet e Ingress. Sono esclusi i Secret, l'accesso ai container (`exec`) e qualsiasi modifica.

In un cluster reale il RoleBinding punterebbe a un gruppo dell'identity provider (per esempio un gruppo Entra ID su AKS); il ServiceAccount permette di verificare i permessi con `kubectl auth can-i`:

```powershell
$sa = "system:serviceaccount:development:boutique-ops-viewer"
"get pods","get pods --subresource=log","list events","get deployments","get secrets","delete pods","create pods --subresource=exec","patch deployments" | ForEach-Object { "{0,-35} {1}" -f $_, (Invoke-Expression "kubectl auth can-i $_ -n development --as=$sa") }
kubectl auth can-i get pods -n production --as=$sa
```

Risultato: `yes` per le quattro azioni di diagnosi, `no` per Secret, cancellazione, `exec` e modifica. `no` anche per i pod di `production`: il Role vale solo nel proprio namespace.

Evidenza: [`rbac-L2.png`](docs/screenshots/security/rbac-L2.png)

### 8.5 Configurazione per ambiente (ConfigMap)

L'overlay di dev genera la ConfigMap `frontend-config` con `configMapGenerator` e la collega al frontend con `envFrom`. Contiene `FRONTEND_MESSAGE`, mostrato come banner in ogni pagina ("Ambiente DEV - dati di test"); in prod non è definito. La stessa immagine si comporta in modo diverso per ambiente senza essere ricostruita.

`configMapGenerator` aggiunge al nome un hash del contenuto (es. `frontend-config-c55fkmgtd5`) e Kustomize aggiorna il riferimento nel Deployment. Una ConfigMap modificata normalmente non riavvia i pod, che continuerebbero a usare il valore letto all'avvio; con l'hash, ogni modifica cambia il template del Deployment e produce un rollout tracciato e reversibile come un cambio di immagine.

```powershell
kubectl kustomize kubernetes/environments/dev | Select-String "frontend-config|FRONTEND_MESSAGE"
```

Evidenza: [`configmap-banner-dev.png`](docs/screenshots/security/configmap-banner-dev.png)

### 8.6 Un solo punto d'ingresso

Il manifest upstream include `frontend-external`, un Service di tipo LoadBalancer. Su Docker Desktop otteneva in dev l'indirizzo `172.18.0.3` (rete Docker interna, non raggiungibile da Windows) e restava `<pending>` in prod; su un cluster cloud otterrebbe un IP pubblico, esponendo il frontend senza passare dall'Ingress. Una patch `$patch: delete` nella base lo rimuove: l'esposizione prevista è solo tramite Ingress.

### 8.7 Risorse rimosse dai manifest

`kubectl apply` crea e aggiorna le risorse, ma **non cancella** quelle tolte dai file. Le risorse eliminate dai manifest (`frontend-external`, `boutique-secret`, `boutique-config`, `boutique-read-role`, `boutique-read-binding`, `boutique-service-account`) sono state rimosse a mano, indicandole per nome:

```powershell
kubectl delete svc/frontend-external secret/boutique-secret configmap/boutique-config rolebinding/boutique-read-binding role/boutique-read-role serviceaccount/boutique-service-account -n development
```

Con un approccio GitOps (Argo CD o Flux con prune attivo) la cancellazione sarebbe automatica.

### 8.8 Verifica in prod

Stesse modifiche applicate a prod, con una password diversa (`redis-password-prod.txt`): nessun token nei 12 pod, Redis che rifiuta le connessioni senza password e risponde `PONG` con quella del Secret, checkout funzionante, nessun banner.

Evidenza: [`prod-verifica-sicurezza.png`](docs/screenshots/security/prod-verifica-sicurezza.png)

## 9. Pipeline CI: validazione dei manifest

Il workflow GitHub Actions [`.github/workflows/validate-manifests.yml`](.github/workflows/validate-manifests.yml) valida i manifest a ogni modifica, prima che vengano applicati al cluster.

### 9.1 Cosa controlla

Per ognuno dei tre target (`kubernetes/environments/dev`, `kubernetes/environments/prod`, `kubernetes/monitoring/metrics-server`), in parallelo:

| Passo | Cosa verifica | Esempio di errore bloccato |
|---|---|---|
| Rendering Kustomize | Base, patch e overlay producono manifest | Patch su un percorso inesistente, file citato ma cancellato |
| kubeconform (`-strict`) | Ogni risorsa rispetta lo schema di Kubernetes | Campo scritto male, tipo sbagliato, `apiVersion` inesistente |
| Nessun Secret nei manifest | Il rendering non contiene risorse `kind: Secret` | Password reinserita nel repository (sezione 8.2) |
| Immagini con registry e tag | Ogni immagine ha registry e tag espliciti (eccezione: `redis:alpine`, immagine ufficiale di Docker Hub) | Immagine nella forma breve dei manifest upstream (sezione 7, caso 1) |

Gli ultimi due controlli trasformano in regole automatiche due problemi emersi durante il lavoro.

### 9.2 Quando parte

- a ogni push su `main`;
- a ogni pull request;
- a mano dalla scheda Actions (`workflow_dispatch`).

La pipeline valida i file presenti nel repository: non accede al cluster e non esegue il deploy, perché il cluster di test è locale e non raggiungibile da GitHub.

### 9.3 Scelte

- **Versioni fissate:** runner `ubuntu-24.04` (non `ubuntu-latest`, che cambia nel tempo), kubeconform `v0.6.7`, `actions/checkout@v5`. Lo stesso commit produce lo stesso risultato anche a distanza di tempo.
- **Permessi minimi:** `permissions: contents: read`, il workflow può solo leggere il repository.
- **`fail-fast: false`:** un errore in un ambiente non interrompe la validazione degli altri, così l'esito mostra tutti i problemi in una sola esecuzione.

### 9.4 Prova: pull request con un errore

Su un branch di prova è stata rimossa la riga `newName` del frontend nell'overlay di dev, riproducendo il caso 1 della sezione 7 (immagine `frontend:v0.10.5` senza registry). Nella pull request #1:
- il job di dev fallisce al controllo delle immagini, con il messaggio `Immagini senza registry o tag esplicito` e la riga `image: frontend:v0.10.5`;
- i job di prod e metrics-server passano: i controlli sono separati per ambiente;
- la validazione dello schema con kubeconform **passa**: per lo schema di Kubernetes il valore è corretto, l'errore emergerebbe solo al pull dell'immagine. Il controllo specifico è quindi necessario.

La pull request è stata chiusa senza merge. In un primo tentativo la stessa modifica era stata applicata per errore direttamente su `main` (esecuzione #3, fallita) e subito annullata (esecuzione #4, verde): anche in quel caso la pipeline ha segnalato il problema al primo commit. La prova è stata poi ripetuta correttamente su un branch separato con pull request.

Evidenze: [`pipeline-verde.png`](docs/screenshots/ci/pipeline-verde.png), [`pr-rossa.png`](docs/screenshots/ci/pr-rossa.png)

### 9.5 Cosa non controlla

- **L'esistenza dei tag nel registry:** il tag inesistente `v0.10.99` (sezione 6.3) supererebbe tutti i controlli.
- **Gli errori logici di configurazione:** con `namePrefix` (sezione 7, caso 3) i manifest erano validi, ma l'applicazione non funzionava.

Evoluzione: verifica dei tag nel registry e deploy di prova su un cluster temporaneo (kind) all'interno della pipeline, con un test HTTP sul frontend. Avrebbe intercettato entrambi i casi.

## 10. Limiti noti e punti aperti

Limiti consapevoli della soluzione, con impatto e possibile evoluzione. Molti derivano dall'ambiente locale (Docker Desktop, nodo singolo) e non si presenterebbero su un cluster gestito.

### 10.1 Ambiente ed esposizione

| Limite | Impatto | Evoluzione |
|---|---|---|
| Cluster locale a nodo singolo (Docker Desktop) | Nessuna alta affidabilità: le 2 repliche del frontend di prod girano sullo stesso nodo | Cluster gestito multi-nodo (es. AKS) con anti-affinity o topology spread |
| Ingress senza controller **[DA COMPLETARE]** | L'Ingress è accettato ma non instrada traffico; l'accesso avviene solo con port-forward | Installazione di ingress-nginx |
| Accesso tramite `kubectl port-forward` | Si aggancia a un singolo pod e si interrompe quando il pod viene sostituito (osservato dopo update e restart); adatto solo ai test | Ingress funzionante |
| metrics-server con `--kubelet-insecure-tls` | Verifica dei certificati dei kubelet disattivata (sezione 7, caso 5) | Certificati dei kubelet firmati dalla CA del cluster |

### 10.2 Sicurezza

| Limite | Impatto | Evoluzione |
|---|---|---|
| Secret `redis-auth` creato a mano con `kubectl` | Non versionato né riproducibile automaticamente: ogni nuovo ambiente richiede il passo manuale, altrimenti `CreateContainerConfigError` (sezione 8.2) | External Secrets Operator con un vault (es. Azure Key Vault) oppure Sealed Secrets |
| Password di Redis passata come argomento (`--requirepass`) e come variabile d'ambiente | Visibile a chi può eseguire comandi nel container (`exec`), permesso escluso dal ruolo L2 | Password letta da un file montato dal Secret, con configurazione Redis dedicata |
| Cifratura a riposo dei Secret in etcd non verificata | Nel datastore del cluster i Secret sono codificati in base64, non necessariamente cifrati | Encryption at rest del cluster o KMS del provider |
| Nessuna NetworkPolicy **[DA COMPLETARE]** | Ogni pod può raggiungere ogni Service del namespace; Redis è protetto solo dalla password | NetworkPolicy che consente l'accesso a Redis solo dal cartservice (da verificare il supporto del CNI di Docker Desktop) |
| Traffico gRPC tra i servizi non cifrato | Comunicazioni interne in chiaro | Service mesh con mTLS (es. Istio, Linkerd) |
| Immagini upstream referenziate per tag, non per digest, e non scansionate | Un tag può essere ripubblicato con contenuto diverso; vulnerabilità delle immagini non note | Riferimento per digest e scansione in pipeline (es. Trivy) |
| Pod Security Admission non configurato sui namespace | Nessun controllo automatico sui `securityContext` dei pod creati in futuro | Label `pod-security.kubernetes.io` sui namespace (in `warn` prima di `enforce`: i manifest upstream non definiscono `seccompProfile`, richiesto dal profilo `restricted`) |

### 10.3 Dati

| Limite | Impatto | Evoluzione |
|---|---|---|
| Redis con volume `emptyDir` | I carrelli si perdono a ogni riavvio del pod di Redis (osservato dopo ogni modifica di Redis) | StatefulSet con PersistentVolumeClaim, oppure servizio gestito (es. Azure Cache for Redis, Memorystore) |

### 10.4 Osservabilità

| Limite | Impatto | Evoluzione |
|---|---|---|
| Metrica applicativa ricavata dai log con uno script | Non in tempo reale e limitata alle righe di log disponibili | Prometheus e Grafana **[DA COMPLETARE]**; strumentazione del frontend con OpenTelemetry |
| Latenza massima di 6871 ms in una prima misurazione | Causa non determinata: la richiesta è uscita dalla finestra dei log | Metriche persistenti che conservino lo storico |
| Riavvio del frontend con `SandboxChanged` (exit code 255) | Causa non verificata; ipotesi: riavvio del runtime locale | Raccolta centralizzata di log ed eventi |

### 10.5 Automazione e gestione

| Limite | Impatto | Evoluzione |
|---|---|---|
| Namespace creati a mano, non inclusi nei manifest | Passo manuale nell'installazione | Namespace gestiti da GitOps o dalla piattaforma (es. Krateo) |
| Deploy con `kubectl apply` manuale | Nessuna rimozione automatica delle risorse tolte dai file (sezione 8.7) | Argo CD o Flux con prune |
| Pipeline solo di validazione | Non verifica l'esistenza dei tag né il funzionamento dell'applicazione (sezione 9.5) | Deploy di prova su kind nella pipeline |
| Immagine del frontend costruita solo in locale | Il cluster continua a usare l'immagine ufficiale: il nodo non vede le immagini locali (sezione 4.7) | Build e pubblicazione su un registry (es. GitHub Container Registry) dalla pipeline |
| `kubectl diff` non disponibile nell'ambiente di test | Verifica pre-apply fatta sul rendering di `kubectl kustomize` (sezione 6.5) | `diff` nel PATH (es. Git for Windows) |
| History dei rollout senza `CHANGE-CAUSE` | Revisioni poco leggibili | Annotazione `kubernetes.io/change-cause` |

### 10.6 Applicazione

- Il `loadgenerator` non è incluso nel deploy: il traffico di test è generato manualmente (browser e `Invoke-WebRequest`).
- Il frontend ha la variabile `SHOPPING_ASSISTANT_SERVICE_ADDR` verso un servizio non installato: la funzione assistente è disattivata di default e non ha effetti.


## 11. Documentazione di dettaglio

| Documento | Contenuto |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Componenti, flussi HTTP/gRPC, diagramma, scelte e trade-off **[DA COMPLETARE]** |
| `docs/runbook.md` | Procedure operative: verifica, troubleshooting, rollback **[DA COMPLETARE]** |
| `docs/krateo.md` | Valutazione di Krateo: golden path, parametri, benefici e rischi **[DA COMPLETARE]** |
| [`ai-usage/ai-usage.md`](ai-usage/ai-usage.md) | Strumenti AI usati, casi concreti, output accettati e scartati, verifiche **[DA COMPLETARE]** |
| [`docs/log-and-analysis/`](docs/log-and-analysis/) | Output completi di `kubectl logs` e `kubectl describe` citati nel README |