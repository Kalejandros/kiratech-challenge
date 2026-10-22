# Documentazione Architetturale - Google Cloud Online Boutique

## 1. Panoramica del Sistema
L'applicazione **Online Boutique** è una piattaforma e-commerce cloud-native basata su un'architettura a **11 microservizi**. È progettata per dimostrare l'uso pratico di Kubernetes, gRPC, Service Mesh e pattern di resilienza in un contesto enterprise.

---

## 2. Componenti Architetturali e Flusso di Comunicazione

### A. Frontend (HTTP / REST)
* **Frontend:** Espone l'interfaccia utente web (HTML/Go). Riceve il traffico dagli utenti esterni e comunica con tutti i servizi di backend tramite chiamate gRPC.

### B. Microservizi Core di Business (gRPC)
I microservizi comunicano tra loro via **gRPC** garantendo bassa latenza e alte prestazioni:
* **CartService:** Gestisce gli articoli aggiunti al carrello dagli utenti. Utilizza **Redis** come database/cache in-memory stateful.
* **ProductCatalogService:** Fornisce la lista dei prodotti e le informazioni di dettaglio lette da un file di catalogo JSON.
* **CurrencyService:** Calcola la conversione delle valute per i prezzi visualizzati.
* **PaymentService:** Simula la gestione e l'addebito delle carte di credito.
* **ShippingService:** Calcola i costi di spedizione e simula l'invio degli ordini.
* **CheckoutService:** Coordina il processo d'acquisto (invoca CartService, PaymentService, ShippingService e EmailService).
* **EmailService:** Simula l'invio della mail di conferma d'ordine all'utente.
* **RecommendationService:** Genera raccomandazioni personalizzate sui prodotti correlate alle scelte dell'utente.
* **AdService:** Restituisce annunci pubblicitari contestuali da mostrare nel frontend.

### C. Strumenti di Supporto
* **LoadGenerator:** Un microservizio basato su Locust che simula utenti reali che navigano sul sito, aggiungono prodotti al carrello e completano acquisti. Utile per testare la scalabilità e le prestazioni dell'infrastruttura.

---

## 3. Strategia di Deployment in Kubernetes (Kustomize)
L'applicazione è strutturata con il pattern **Base / Overlays**:
* **kubernetes/base/**: Contiene la definizione standard di tutti i deployment e servizi di Kubernetes.
* **kubernetes/environments/dev/**: Configura l'ambiente di Sviluppo (namespace "development", prefisso "dev-").
* **kubernetes/environments/prod/**: Configura l'ambiente di Produzione (namespace "production", prefisso "prod-").