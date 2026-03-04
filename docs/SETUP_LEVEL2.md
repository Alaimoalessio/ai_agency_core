# 🔍 Livello 2 — Quality Validator + Character Selector
## Guida Setup e Funzionamento

---

## Cosa aggiunge questo livello

### 2a — Validatore qualità automatico
Ogni immagine generata da FLUX viene analizzata da **Claude Vision** (claude-opus-4-6) prima di arrivare in preview. Il validatore controlla:

- Volto visibile e non deformato
- Numero corretto di dita
- Anatomia generale corretta
- Nitidezza del soggetto principale
- Composizione non tagliata male
- Assenza di artefatti/watermark
- Coerenza con la scena richiesta

**Score < 70 = rigenerazione automatica** (massimo 2 tentativi).
Se dopo 2 tentativi l'immagine non supera il controllo, il bot avvisa con il problema specifico e suggerisce di riformulare la scena.

La preview mostra ora il **quality score** nell'anteprima: `✅ Quality score: 87/100`

### 2b — Selezione personaggio con inline keyboard
Con 4+ personaggi attivi, quando l'utente invia una descrizione il bot risponde con una **inline keyboard** per scegliere quale personaggio usare:

```
🎭 Scegli il personaggio per questa scena:
"ragazza in spiaggia al tramonto"

[🎭 Sofia]  [🎭 Emma]
[🎭 Chiara] [🎭 Luna]
```

Se è attivo un solo personaggio, la selezione viene saltata automaticamente.

---

## Step 1 — Esegui la migration SQL

Nel SQL Editor di Supabase, esegui il file `migration_v2.sql`.

Aggiunge:
- Campo `attempts` alla tabella `images`
- View `quality_stats_by_character` — statistiche qualità per personaggio
- View `recent_quality_failures` — ultimi fallimenti per debug
- View `generation_performance` — monitoraggio tempi Replicate

---

## Step 2 — Aggiungi la variabile TELEGRAM_BOT_TOKEN

Il nodo **"Invia Selezione Personaggio"** usa l'API Telegram diretta per poter passare una inline keyboard dinamica costruita a runtime. Aggiungi nelle variabili d'ambiente n8n:

```
TELEGRAM_BOT_TOKEN=1234567890:AAFxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Lo trovi nel tuo bot su @BotFather → il token è quello che usi già nelle credenziali n8n — copialo da lì.

---

## Step 3 — Importa il workflow v4

1. In n8n: **Workflows → Import from file**
2. Seleziona `workflow1_v4_quality_selector.json`
3. Collega le credenziali Telegram sui nodi Telegram
4. Attiva il workflow

> ⚠️ Disattiva prima il workflow v3 se è ancora attivo — usano lo stesso webhook Telegram.

---

## Come funziona il quality validator nel dettaglio

### Flusso con immagine OK (score ≥ 70)
```
Genera → Valida (Claude Vision) → Score 85/100 ✅ → Aggiorna DB → Scarica → Preview
```

### Flusso con immagine difettosa, primo tentativo
```
Genera → Valida → Score 45/100 ❌ (deformed hands) → attempt=1 < 2 → Rigenera
      → Valida → Score 78/100 ✅ → Aggiorna DB → Scarica → Preview
```

### Flusso con immagine difettosa, entrambi i tentativi falliti
```
Genera → Valida → Score 40/100 ❌ → attempt=1 < 2 → Rigenera
      → Valida → Score 55/100 ❌ → attempt=2 NON < 2 → DB: failed → Messaggio errore
```

---

## Monitoraggio qualità da Supabase

### Statistiche per personaggio
```sql
SELECT * FROM quality_stats_by_character;
```
Mostra per ogni personaggio: media score, tasso di retry, fallimenti totali.
Se un personaggio ha retry_rate_pct > 30% → considera di abbassare il lora_scale o aggiustare i content pillars.

### Ultimi fallimenti
```sql
SELECT * FROM recent_quality_failures;
```
Utile per capire quali scene causano più problemi (es. "mani visibili" genera spesso fallimenti → suggerisci scene senza mani in primo piano).

### Performance Replicate
```sql
SELECT * FROM generation_performance;
```
Se avg_seconds supera 90s, Replicate potrebbe avere problemi di carico.

---

## Tuning del quality validator

Il threshold di 70/100 è conservativo ma efficace. Puoi modificarlo nel nodo **"Elabora Risultato Qualità"**:

```javascript
// Riga da modificare:
const pass = qc.pass === true && (qc.score || 0) >= 70;

// Più permissivo (meno retry, qualità leggermente inferiore):
const pass = qc.pass === true && (qc.score || 0) >= 60;

// Più severo (più retry, qualità superiore):
const pass = qc.pass === true && (qc.score || 0) >= 80;
```

---

## Prossimo step: Livello 3

- **Calendario editoriale automatico**: trigger schedulato che genera le scene pianificate ogni mattina
- **Pubblicazione automatica**: approva → pubblica direttamente su Instagram/Fanvue senza toccare niente
- **Watermark automatico**: aggiunto prima della pubblicazione
