# Uso dell'AI nel progetto

Come sono stati usati gli strumenti di AI generativa in questa challenge: in quali attività, con quale approccio, cosa è stato accettato, corretto o scartato, come è stato verificato e con quali limiti.

**In sintesi:** README e documentazione sono stati redatti con il supporto di assistenti AI. Tutti i comandi sono stati eseguiti da me sul cluster e tutti gli output riportati sono reali, documentati con screenshot. Le decisioni (cosa implementare, cosa dichiarare come limite, quando fermarsi a verificare) sono mie, come la responsabilità del risultato.

## 1. Strumenti e modalità

| Strumento | Fase | Uso |
|---|---|---|
| **Gemini** | Impianto iniziale | Prima struttura del progetto: overlay Kustomize, manifest aggiuntivi (ConfigMap, Secret, RBAC, Ingress), primi deploy e prime diagnosi |
| **Claude** | Verifica, miglioramento e documentazione | Secondo parere sulla diagnosi delle immagini, troubleshooting, revisione della sicurezza, pipeline, Dockerfile, documentazione |

Il passaggio da uno strumento all'altro non è stato una sostituzione, ma la ricerca di un **secondo parere** quando una diagnosi rischiava di bloccare il progetto (sezione 5).

**Modalità di lavoro.** Gli assistenti sono stati usati in chat, senza accesso diretto al cluster o al repository. Ogni comando è stato proposto con il risultato atteso e il motivo, eseguito da me uno alla volta, e l'output reale è stato riportato nella conversazione per decidere il passo successivo. In questo modo nessun comando è stato eseguito senza essere compreso, e ogni affermazione della documentazione corrisponde a un output osservato.

## 2. Regole che mi sono dato

- **Capire prima di eseguire:** nessun comando senza sapere cosa fa e cosa aspettarsi.
- **Le prove decidono, non l'AI:** un'ipotesi diventa causa solo dopo una verifica (messaggio completo dell'evento, test mirato, riproduzione in piccolo).
- **Secondo parere** quando una risposta porta a una conclusione che limita il progetto.
- **Comandi distruttivi solo mirati:** cancellazioni indicando le risorse per nome, prove in namespace usa e getta (`test-secret`) o con pod di prova, rendering con `kubectl kustomize` prima di ogni `apply`.
- **Nessun segreto nei prompt:** le password di Redis sono state generate e lette da file locali, senza mai mostrarle a schermo né incollarle nella conversazione (`kubectl describe` ne mostra solo la lunghezza).
- **Dichiarare ciò che non è verificato:** le voci non provate sono marcate come tali (es. procedure del runbook "non osservate in questo progetto").

## 3. Casi d'uso per area

### 3.1 Analisi

- **Comprensione dell'applicazione:** ruolo dei servizi, flussi HTTP/gRPC e dipendenze del checkout. Porte, linguaggi e chiamate del documento di architettura sono stati ricontrollati sui manifest (variabili `*_SERVICE_ADDR`, porte dei Service).
- **Lettura del Dockerfile upstream:** spiegazione riga per riga del multi-stage; da qui sono emersi i due punti migliorabili (immagine finale non fissata per digest, utente root), poi verificati con `docker inspect`.
- **Interpretazione dei log:** gli errori del frontend verso `169.254.169.254` all'avvio fuori dal cluster sono stati riconosciuti come tentativi innocui di leggere il metadata server di Google Cloud (lo stesso indirizzo dell'Azure Instance Metadata Service), non come un guasto.
- **Stato attuale di Krateo:** la valutazione si basa su repository e documentazione attuali (ottobre 2026), non su conoscenze pregresse, perché il progetto è cambiato molto: la documentazione storica descrive una versione basata su Crossplane, e alcuni componenti sono stati riorganizzati di recente.

### 3.2 Implementazione

- **Patch Kustomize** per la sicurezza (token dei ServiceAccount, Secret di Redis, rimozione del LoadBalancer): proposte dall'AI, verificate prima sul rendering, poi con `apply` su dev, poi con test funzionali, infine portate su prod.
- **`configMapGenerator`** per la configurazione per ambiente: verificato confrontando l'hash nel nome della ConfigMap e nel riferimento del Deployment, e nel browser (banner).
- **Pipeline GitHub Actions:** verificata con un'esecuzione verde e con una pull request costruita per fallire.
- **Dockerfile `nonroot`:** il digest dell'immagine di base è stato ottenuto dal registry (`docker inspect ... RepoDigests`), non scritto dall'AI; il risultato è stato verificato con l'utente `65532` e un avvio funzionante.

### 3.3 Operations e troubleshooting

- **Immagini non scaricabili:** il caso più importante, descritto nella sezione 5.
- **Errore 500 con `namePrefix`:** causa individuata e poi riprodotta con un overlay temporaneo che ne mostra il rendering (README, sezione 7, caso 3).
- **Avviso di `rollout undo`** su `last-applied-configuration`: interpretato e trasformato nella procedura in due fasi, rollback imperativo e poi riallineamento del repository (README, sezione 6).
- **Secret mancante:** comportamento previsto (`CreateContainerConfigError`), poi provato davvero in un namespace di prova prima di scriverlo.

### 3.4 Documentazione e demo

README, architettura, runbook e valutazione di Krateo sono stati redatti con il supporto di Claude, a partire dagli output reali delle prove. Ogni sezione è stata riletta e corretta; alcuni errori sono emersi solo in rilettura (sezione 4).

## 4. Output accettati, corretti e scartati

| Output dell'AI | Esito | Come è emerso |
|---|---|---|
| Diagnosi: immagini bloccate da rete o policy aziendali | **Scartato** | Messaggio completo dell'evento e `Test-NetConnection` (sezione 5) |
| Tag `v0.10.6` indicato come utilizzabile | **Corretto** | Pull fallito con `NotFound`: la release esiste su GitHub ma non le immagini nel registry |
| Rollback "fallito" attribuito a Kustomize | **Corretto** | `set image` con la stessa immagine non crea una revisione (README, sezione 7, caso 4) |
| `namePrefix` per separare gli ambienti | **Scartato** | Errore 500 sul frontend; sostituito dall'isolamento per namespace |
| Secret con password in chiaro nel repository, non usata da nessun componente | **Scartato e rifatto** | Revisione della sicurezza: Secret fuori dal repository e usato davvero da Redis e cartservice |
| Quoting JSON in un comando PowerShell | **Corretto** | Il comando falliva in PowerShell 5.1 |
| Titoli Markdown | **Corretto** | Resa errata su GitHub |
| `Test-NetConstruction` nel runbook | **Corretto** | Rilettura: il cmdlet corretto è `Test-NetConnection` |
| Previsione: compilazione in cache alla seconda build | **Corretto** | L'output della build mostrava la compilazione rifatta, perché `COPY . .` include il Dockerfile modificato |
| Prova delle variabili d'ambiente documentata con l'immagine `nonroot` ma eseguita con quella originale | **Corretto** | Confronto tra screenshot e testo; prova ripetuta con l'immagine corretta |
| Patch di sicurezza, pipeline, `configMapGenerator`, Dockerfile `nonroot` | **Accettati dopo verifica** | Rendering, apply, test funzionali, pipeline verde e rossa |

## 5. Caso principale: le immagini "bloccate dalla rete"

**Contesto.** Dopo il primo deploy, tutti i pod erano in `ImagePullBackOff`, tranne Redis.

**Input e risposta.** Il problema era stato sottoposto all'assistente usato nella prima fase, con lo stato dei pod. La risposta indicava un blocco della rete aziendale o delle policy del PC: un'ipotesi plausibile, perché il PC è aziendale, durante la configurazione era comparsa una richiesta di accesso alla rete che non avevo potuto concedere, e Redis funzionava. La spiegazione del perché Redis funzionasse (immagine già in cache sul nodo) era corretta.

**Cosa è successo dopo.** Le alternative proposte portavano tutte allo stesso vicolo cieco, e avevo iniziato ad adattare il progetto al limite: test solo sul componente funzionante e una spiegazione nel README del perché gli altri non potevano partire. Anche io avevo accettato l'ipotesi senza chiedermi quale prova la sostenesse.

**Secondo parere.** Mi sembrava improbabile che un'applicazione dimostrativa non potesse girare su un cluster locale, anche con altre versioni. Ho chiesto un secondo parere, partendo dal messaggio completo dell'evento invece che dallo stato del pod.

**Verifica.**
- Il messaggio era `pull access denied` su `docker.io/library/frontend:latest`: i manifest upstream usano nomi brevi (`image: frontend`) che, senza registry, Kubernetes completa verso Docker Hub, dove quel repository non esiste.
- `Test-NetConnection us-central1-docker.pkg.dev -Port 443` restituiva `True`: il registry corretto era raggiungibile.
- Con il blocco `images:` negli overlay (registry e tag espliciti) tutti gli 11 pod sono passati in `Running`.
- In seguito la causa è stata riprodotta con un pod di prova (README, sezione 7, caso 1) e trasformata in un controllo automatico della pipeline (README, sezione 9).

**Valore.** Senza la verifica il progetto sarebbe stato consegnato con un solo servizio funzionante e un limite che non esisteva. La lezione non riguarda uno strumento in particolare: una risposta coerente e sicura non è una prova, e il punto di partenza di una diagnosi è il messaggio completo dell'errore. Nello stesso progetto anche il secondo assistente ha prodotto errori (sezione 4): la sicurezza è venuta dal metodo di verifica, non dalla scelta dello strumento.

Questo è il caso usato in demo per il punto 11 della traccia.

## 6. Limiti riscontrati

- **Ipotesi plausibili presentate con sicurezza:** il rischio maggiore, perché portano a costruire sopra una causa sbagliata (sezione 5).
- **Versioni e stato attuale:** le conoscenze dei modelli possono non essere aggiornate su tag, versioni e progetti in rapida evoluzione (`v0.10.6`, Krateo). Vanno verificati su registry e documentazione attuali.
- **Spiegazioni causali sbagliate ma convincenti**, come il rollback attribuito a Kustomize.
- **Dettagli di piattaforma:** differenze tra PowerShell e bash (quoting, comandi disponibili come `diff`), nomi di cmdlet.
- **Continuità tra sessioni:** passando da una conversazione all'altra il contesto si perde; è stato necessario un riepilogo scritto dello stato del progetto, a sua volta da verificare.

## 7. Valore prodotto

- **Velocità:** comandi, patch e documentazione proposti rapidamente, con più tempo per le verifiche.
- **Apprendimento:** ogni comando spiegato (cosa fa, cosa aspettarsi, perché), su una tecnologia per me in gran parte nuova.
- **Qualità della documentazione:** struttura coerente, casi di troubleshooting con evidenze, limiti dichiarati.
- **Diagnosi più rapide**, a condizione di fornire all'AI i messaggi completi e di verificarne le conclusioni.

Il valore è venuto dall'uso combinato: l'AI propone, i test sul cluster decidono.