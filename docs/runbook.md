# Runbook operativo

Procedure per verificare lo stato di Online Boutique, diagnosticare i problemi più comuni ed eseguire update e rollback. Pensato per il supporto L2: ogni passo indica il comando, il risultato atteso e cosa fare se il risultato è diverso.

Le procedure valgono per entrambi gli ambienti: negli esempi si usa `development`; per prod sostituire `-n development` con `-n production`.

> Le voci marcate *"non osservato in questo progetto"* descrivono problemi comuni non verificati sul cluster di test.

## 0. Prima di iniziare

| Cosa | Valore |
|---|---|
| Namespace | `development` (dev), `production` (prod) |
| Punto d'ingresso | Traefik (namespace `traefik`) con Ingress per host: `dev.boutique.localhost`, `prod.boutique.localhost`. Dal PC: `kubectl port-forward svc/traefik 8082:80 -n traefik`. Per test diretti: port-forward al Service `frontend` |
| Componente stateful | `redis-cart` (dati non persistenti: un riavvio svuota i carrelli) |
| Secret richiesto | `redis-auth`, chiave `REDIS_PASSWORD`, creato fuori dal repository (README, sezione 8.2) |
| Accesso di sola lettura | Ruolo `boutique-ops-viewer`: pod, log, eventi, Service, Deployment; esclusi Secret, `exec` e modifiche (README, sezione 8.4) |

Le procedure di **diagnosi** (sezioni 1 e 2) richiedono solo i permessi di `boutique-ops-viewer`. Le procedure di **intervento** (sezione 3) richiedono permessi di modifica sul namespace.

## 1. Verifica rapida dello stato

Da eseguire all'apertura di una segnalazione e dopo ogni intervento.

| # | Comando | Atteso | Se diverso |
|---|---|---|---|
| 1 | `kubectl get pods -n development` | 11 pod `1/1 Running` (12 in prod: 2 repliche del frontend) | Sezione 2, in base allo `STATUS` |
| 2 | `kubectl get deploy -n development` | `READY` uguale al numero di repliche per ogni Deployment | `kubectl rollout status deployment/<nome> -n development` |
| 3 | `kubectl get endpointslices -n development -l kubernetes.io/service-name=frontend` | Almeno un indirizzo IP | Nessun pod del frontend è `Ready`: sezione 2.5 |
| 4 | `kubectl get events -n development --field-selector type=Warning --sort-by=.lastTimestamp` | Nessun evento recente | Il messaggio dell'evento indica la causa: sezione 2 |
| 5 | `kubectl top pods -n development` | Consumi sotto i limits | Vicino ai limits di memoria: rischio `OOMKilled` (sezione 2.6) |
| 6 | Port-forward + `(Invoke-WebRequest http://localhost:8080/_healthz -UseBasicParsing).Content` | `ok` | Il frontend non risponde: sezione 2 |
| 7 | Nel browser: aggiungere un prodotto al carrello e completare il checkout | Pagina "Your order is complete!" | Errore 500: sezione 2.7 |
| 8 | `kubectl get ingress -n development` | Classe `traefik`, host `dev.boutique.localhost`, `ADDRESS` valorizzato | Sezione 2.11 |
| 9 | `curl.exe -s -o NUL -w "%{http_code}" -H "Host: dev.boutique.localhost" http://localhost:8082/` (con il port-forward verso Traefik) | `200` | Sezione 2.11 |
| 10 | Prometheus <http://localhost:9090/alerts> o Alertmanager <http://localhost:9093> (port-forward: README, sezione 5.5) | Solo `Watchdog` attivo | Un allarme `BoutiqueFrontendDown` indica in quale namespace il frontend non ha repliche: sezioni 2.1-2.5 |

I passi 1, 6 e 9 si possono eseguire in un solo comando con `scripts/smoke-test.ps1` (README, sezione 5.6), con il port-forward verso Traefik attivo.
Il passo 6 verifica solo che il processo del frontend sia vivo; il passo 7 verifica l'intera catena di servizi. **Un health check verde non garantisce che l'applicazione funzioni.**

Port-forward per i passi 6 e 7, in una finestra dedicata:

```powershell
kubectl port-forward svc/frontend 8080:80 -n development
```

Il port-forward si interrompe quando il pod del frontend viene sostituito (update, riavvio): va rilanciato.

## 2. Triage per sintomo

Metodo: dallo **stato** del pod (`get pods`) al **motivo** (`describe`, `events`) a **cosa vede l'applicazione** (`logs`). Dove i log non esistono (container mai partito), la causa è nella configurazione o nell'immagine, non nel codice.

Comando base per ogni sintomo:

```powershell
kubectl describe pod <nome-pod> -n development
```

La sezione `Events` in fondo all'output e i campi `State`, `Last State` e `Reason` del container sono il primo punto da leggere.

### 2.1 `ImagePullBackOff` / `ErrImagePull`

Il nodo non riesce a scaricare l'immagine. Il messaggio dell'evento distingue tre cause:

| Messaggio | Causa | Azione |
|---|---|---|
| `pull access denied`, `repository does not exist` | Nome dell'immagine sbagliato o senza registry: risolto su Docker Hub | Controllare `image:` nel rendering (`kubectl kustomize ... \| Select-String "image:"`) e il blocco `images:` dell'overlay |
| `code = NotFound ... not found` | Registry raggiunto, tag inesistente | Verificare il tag pubblicato nel registry; correggere `newTag` |
| Timeout, `dial tcp`, `i/o timeout` | Problema di rete verso il registry | ``Test-NetConnection <registry> -Port 443``; verificare proxy o firewall |
| `short read`, `unexpected EOF` | Download interrotto durante il trasferimento (rete instabile) | Attendere i tentativi automatici del kubelet; se persiste, verificare il download dal PC (`docker pull`) e valutare un registry alternativo (caso reale: README, sezione 7, caso 6) |

Durante un rollout il pod vecchio resta attivo e il servizio non si interrompe: correggere con calma o fare rollback (sezione 3.2). Casi reali: README, sezione 6.3 e sezione 7, casi 1 e 2.

### 2.2 `CreateContainerConfigError`

Il container non parte perché manca una configurazione: Secret, ConfigMap o una loro chiave. Non ci sono log.

```powershell
kubectl describe pod -l app=<servizio> -n development | Select-String "State|Reason|Warning|not found"
kubectl get secret,configmap -n development
```

Messaggio tipico: `Error: secret "redis-auth" not found`. Creare l'oggetto mancante (README, sezione 4.3): i pod partono da soli, senza redeploy, perché il kubelet riprova. Caso reale: README, sezione 8.2.

### 2.3 `CrashLoopBackOff`

Il container parte e termina subito; Kubernetes lo riavvia con attese crescenti.

```powershell
kubectl logs <nome-pod> -n development --previous
kubectl describe pod <nome-pod> -n development | Select-String "Last State|Reason|Exit Code"
```

`--previous` mostra i log del container terminato, dove di solito c'è l'errore. Cause frequenti: variabile d'ambiente mancante (il frontend termina con `panic: environment variable ... not set`, verificato in locale, README sezione 4.7), dipendenza irraggiungibile all'avvio, errore applicativo. Se la causa è nel codice: escalation (sezione 4).

### 2.4 `Pending` — *non osservato in questo progetto*

Il pod non viene assegnato a nessun nodo.

```powershell
kubectl describe pod <nome-pod> -n development | Select-String "Events" -Context 0,10
kubectl top nodes
```

Messaggi tipici: `Insufficient cpu` / `Insufficient memory` (requests superiori alle risorse libere del nodo); taint o vincoli di scheduling non soddisfatti. Sul cluster locale a nodo singolo la causa più probabile è la memoria.

### 2.5 `Running` ma non `Ready` (`0/1`)

Il processo è vivo ma la readiness probe fallisce: il pod **non riceve traffico** dal Service.

```powershell
kubectl describe pod <nome-pod> -n development | Select-String "Readiness|Unhealthy|Warning"
```

Subito dopo l'avvio è normale per qualche secondo (`initialDelaySeconds`: 10-20 s a seconda del servizio). Se persiste: probe configurata in modo sbagliato o servizio che non riesce a inizializzarsi. Verificare anche che gli endpoint del Service contengano il pod (sezione 1, passo 3).

### 2.6 `OOMKilled` — *non osservato in questo progetto*

Il container ha superato il limite di memoria ed è stato terminato.

```powershell
kubectl describe pod <nome-pod> -n development | Select-String "Last State|Reason|Exit Code|Limits" -Context 0,2
kubectl top pods -n development
```

`Reason: OOMKilled`, exit code `137`. Azione: aumentare `limits.memory` nell'overlay (come già fatto per il frontend di prod, 256Mi) e verificare con `kubectl top` se il consumo cresce nel tempo.

### 2.7 Pod sani ma l'applicazione risponde con errore 500

Tutti i pod sono `Running` e `Ready`, ma la home o il checkout falliscono. Il problema è tra i servizi.

```powershell
kubectl logs deploy/frontend -n development --tail=50
```

| Nel log | Causa probabile | Verifica |
|---|---|---|
| `lookup <servizio> ... i/o timeout` o `no such host` | Il nome nella variabile d'ambiente non corrisponde a nessun Service | `kubectl get svc -n development`; confrontare con le variabili `*_SERVICE_ADDR` (caso reale: README, sezione 7, caso 3) |
| `connection refused` verso un servizio | Il servizio esiste ma non ha pod pronti | `kubectl get endpointslices -n development -l kubernetes.io/service-name=<servizio>` |
| Errori del carrello | Problema tra cartservice e Redis | Sezione 2.8 |

Le righe di errore sul metadata server `169.254.169.254` all'avvio del frontend sono **innocue** fuori da Google Cloud (README, sezione 4.7).

### 2.8 Carrello non funzionante

```powershell
kubectl logs deploy/cartservice -n development --tail=50
kubectl exec deploy/redis-cart -n development -- sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping'
```

- `PONG`: Redis funziona e la password del Secret è valida.
- `NOAUTH` o errori di autenticazione nei log del cartservice: Redis e cartservice usano password diverse, tipico dopo una rotazione in cui è stato riavviato solo uno dei due (sezione 3.4).
- Carrello vuoto dopo un riavvio di Redis: comportamento atteso, Redis usa `emptyDir`.

`exec` richiede permessi superiori a quelli di `boutique-ops-viewer`.

### 2.9 Rollout bloccato

`kubectl rollout status` non termina, oppure il Deployment ha più ReplicaSet attivi.

```powershell
kubectl rollout status deployment/<nome> -n development --timeout=60s
kubectl get rs -n development -l app=<nome> -o wide
kubectl rollout history deployment/<nome> -n development
```

Il ReplicaSet nuovo con `READY 0` indica il problema (di solito sezione 2.1 o 2.5); quello vecchio con `READY` pieno serve ancora il traffico. Azione: correggere o fare rollback (sezione 3.2). Kubernetes non esegue rollback automatici. Caso reale: README, sezione 6.3.

### 2.10 `kubectl top` → `Metrics API not available`

```powershell
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl get pods -n kube-system -l k8s-app=metrics-server
```

- La risorsa `apiservice` non esiste: metrics-server non è installato (README, sezione 5.4).
- Esiste con `AVAILABLE False`: metrics-server è installato ma non pronto; controllare i suoi log (caso reale: README, sezione 7, caso 5).

### 2.11 Ingress: `ADDRESS` vuoto o errore `404`

```powershell
kubectl get ingressclass
kubectl get ingress -A
kubectl get pods -n traefik
kubectl logs -n traefik deploy/traefik --tail=20
```

| Sintomo | Causa probabile | Verifica |
|---|---|---|
| `ADDRESS` vuoto | Nessun controller per la classe indicata (situazione iniziale di questo progetto, classe `nginx` senza controller) | `kubectl get ingressclass`: deve esistere la classe usata in `ingressClassName` |
| `404` da Traefik | Nessuna regola per l'host richiesto, oppure host sbagliato nella richiesta | Confrontare l'header `Host` con la colonna `HOSTS` di `kubectl get ingress -A`; nell'access log la richiesta non ha `RouterName` |
| `502` / `503` da Traefik | La regola esiste ma il Service non ha pod pronti | Sezione 1, passo 3 (EndpointSlice) |

L'access log di Traefik (JSON) riporta per ogni richiesta host, percorso, stato, router e pod di destinazione (README, sezione 4.5).

## 3. Procedure operative

Tutte le modifiche passano dal repository: il file è la fonte di verità, il cluster si allinea con `kubectl apply -k`.

### 3.1 Update di un'immagine

1. Modificare `newTag` nel blocco `images:` dell'overlay.
2. Verificare il rendering:
   ```powershell
   kubectl kustomize kubernetes/environments/dev | Select-String "<servizio>:v"
   ```
3. Caricare la modifica su GitHub e attendere la pipeline verde (README, sezione 9).
4. Applicare e seguire il rollout:
   ```powershell
   kubectl apply -k kubernetes/environments/dev
   kubectl rollout status deployment/<servizio> -n development
   kubectl rollout history deployment/<servizio> -n development
   ```
5. Ripetere la verifica rapida (sezione 1).

### 3.2 Rollback

**In emergenza (imperativo)**: ripristina subito la revisione precedente.

```powershell
kubectl rollout undo deployment/<servizio> -n development
kubectl rollout status deployment/<servizio> -n development
```

Per tornare a una revisione specifica: `kubectl rollout history` per individuarla, poi `kubectl rollout undo deployment/<servizio> --to-revision=<n> -n development`.

**Subito dopo (dichiarativo)**: riportare il file del repository alla versione funzionante e riapplicare. Senza questo passo, il deploy successivo reintroduce la versione rotta.

```powershell
kubectl apply -k kubernetes/environments/dev
kubectl rollout history deployment/<servizio> -n development
```

Dettagli e prova completa: README, sezioni 6.4-6.6.

### 3.3 Riavvio controllato

```powershell
kubectl rollout restart deployment/<servizio> -n development
kubectl rollout status deployment/<servizio> -n development
```

Il riavvio sostituisce i pod uno alla volta, senza interruzione se le repliche sono pronte. Serve per applicare modifiche lette solo all'avvio (variabili d'ambiente da Secret, impostazioni dei ServiceAccount). Il riavvio di `redis-cart` svuota i carrelli.

### 3.4 Rotazione della password di Redis — *procedura non provata*

1. Generare una nuova password nel file locale, fuori dal progetto (README, sezione 8.2).
2. Aggiornare il Secret esistente:
   ```powershell
   kubectl create secret generic redis-auth -n development --from-file=REDIS_PASSWORD="$env:USERPROFILE\redis-password-dev.txt" --dry-run=client -o yaml | kubectl apply -f -
   ```
3. Riavviare **insieme** Redis e cartservice, che leggono la password solo all'avvio:
   ```powershell
   kubectl rollout restart deployment/redis-cart deployment/cartservice -n development
   ```
4. Verificare con i comandi della sezione 2.8 e un test del carrello.

Impatto: i carrelli vengono persi (Redis senza persistenza) e per qualche secondo il carrello può dare errore durante il cambio.

## 4. Escalation

| Situazione | A chi | Cosa allegare |
|---|---|---|
| Errore applicativo con stack trace nei log, comportamento errato del codice | Team di sviluppo | Log (`kubectl logs`, anche `--previous`), versione dell'immagine, passi per riprodurre |
| Immagine upstream difettosa o tag mancante nel registry | Team di sviluppo / owner delle immagini | Messaggio dell'evento, tag richiesto, tag disponibili |
| Nodo `NotReady`, problemi del runtime, rete del cluster | Team della piattaforma / infrastruttura | `kubectl get nodes`, `kubectl describe node`, eventi del namespace `kube-system` |
| Rete aziendale, proxy, registry non raggiungibili | Team di rete | `Test-NetConnection` verso il registry, messaggio di errore del pull |

Prima di passare la segnalazione: eseguire la verifica rapida (sezione 1), annotare cosa è stato già provato e lo stato attuale (pod, eventi, revisione in uso).