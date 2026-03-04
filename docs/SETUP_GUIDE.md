# 🗄️ Setup Database Layer — Guida Completa
## AI Character Content System — Livello 1: Database

---

## Cosa ottieni con questa guida

- Database Postgres centralizzato su Supabase (gratuito)
- Storico completo di tutte le immagini generate
- Gestione personaggi multipli (4+) da database, non dal codice
- Sistema ruoli team (admin / approver / creator)
- callbackData Telegram sempre sotto i 64 byte
- Workflow n8n v3 pronto all'uso

---

## Step 1 — Crea il progetto Supabase (5 minuti)

1. Vai su **https://supabase.com** e registrati (gratuito)
2. Clicca **"New project"**
3. Scegli:
   - **Name**: `ai-character-system` (o come vuoi)
   - **Database Password**: genera una password forte e salvala
   - **Region**: Europe West (Frankfurt) — la più vicina all'Italia
4. Attendi ~2 minuti che il progetto si avvii

### Recupera le credenziali

Vai su **Project Settings → API** e copia:

| Chiave | Dove si trova | Descrizione |
|--------|---------------|-------------|
| `SUPABASE_URL` | "Project URL" | Es: `https://xxxx.supabase.co` |
| `SUPABASE_SERVICE_KEY` | "service_role" (secret) | Chiave con accesso completo — tienila segreta |

⚠️ **Usa la `service_role` key, NON l'`anon` key** — il bot ha bisogno di accesso completo al DB.

---

## Step 2 — Crea il database (2 minuti)

1. Nel dashboard Supabase, vai su **SQL Editor** (icona terminale nella sidebar)
2. Clicca **"New query"**
3. **Incolla tutto il contenuto del file `schema.sql`**
4. Clicca **"Run"** (o Ctrl+Enter)
5. Dovresti vedere: `Success. No rows returned`

### Verifica che le tabelle siano state create

Vai su **Table Editor** nella sidebar — dovresti vedere:
- `characters`
- `team_members`
- `images`
- `generation_queue`
- `editorial_calendar`
- `analytics_events`

---

## Step 3 — Inserisci il tuo chat_id Telegram (1 minuto)

Per trovare il tuo chat_id:
1. Apri Telegram
2. Cerca **@userinfobot** e avvia una chat
3. Il bot ti risponde con il tuo User ID — quello è il tuo `telegram_chat_id`

Poi vai su SQL Editor in Supabase ed esegui:

```sql
-- Sostituisci 123456789 con il tuo vero chat_id
-- Sostituisci 'Mario' con il tuo nome
UPDATE team_members
SET telegram_chat_id = 123456789, name = 'Mario'
WHERE name = 'Admin';
```

Per aggiungere altri membri del team:

```sql
-- Ruolo 'creator': può solo generare
INSERT INTO team_members (telegram_chat_id, name, role)
VALUES (987654321, 'Giulia', 'creator');

-- Ruolo 'approver': può approvare e pubblicare
INSERT INTO team_members (telegram_chat_id, name, role)
VALUES (111222333, 'Luca', 'approver');
```

---

## Step 4 — Inserisci i tuoi personaggi (per ogni profilo AI)

Nel SQL Editor, inserisci un record per ogni personaggio:

```sql
INSERT INTO characters (
  name, trigger_word, lora_model, lora_version, lora_scale,
  age, hair, eyes, body, ethnicity, style, distinctive,
  content_pillars, platform
) VALUES (
  'Sofia',                                    -- Nome del personaggio
  'ohwx',                                     -- Trigger word LoRA
  'tuousername/sofia-lora',                   -- username/model su Replicate
  'a1b2c3d4e5f6...',                          -- Hash versione (da Replicate > Versions)
  0.85,                                       -- LoRA scale

  -- Aspetto fisico (in inglese)
  '25 years old',
  'light brown wavy shoulder-length hair',
  'hazel green eyes',
  'slim natural build, 170cm',
  'European, fair skin with warm undertones',
  'modern casual chic fashion',
  'light freckles, natural minimal makeup',

  -- Content pillars: definisce lo stile per categoria di contenuto
  '[
    {"name": "lifestyle", "style": "bright natural light, candid authentic mood, outdoor or cozy indoor"},
    {"name": "glam",      "style": "dramatic cinematic lighting, luxury setting, intense sophisticated gaze"},
    {"name": "fitness",   "style": "energetic dynamic pose, gym or outdoor, athletic wear, motivational"},
    {"name": "travel",    "style": "golden hour light, exotic location, wanderlust vibe, editorial style"}
  ]',

  'instagram'                                 -- Piattaforma target
);
```

Ripeti per ogni personaggio che gestite.

---

## Step 5 — Configura le variabili d'ambiente in n8n

In n8n, vai su **Settings → Environment Variables** (o `.env` se self-hosted)
e aggiungi:

```
SUPABASE_URL=https://xxxx.supabase.co
SUPABASE_SERVICE_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
OPENROUTER_API_KEY=sk-or-...
REPLICATE_API_KEY=r8_...
```

> **Nota per n8n cloud**: vai su *Settings → n8n Variables* nel pannello del workflow.
> **Nota per n8n self-hosted**: aggiungi al file `.env` nella root di n8n.

---

## Step 6 — Importa il workflow v3

1. In n8n, vai su **Workflows** nella sidebar
2. Clicca **"Add workflow"** → **"Import from file"**
3. Seleziona il file `workflow1_v3_db_layer.json`
4. Collega le credenziali Telegram (il nodo Telegram Trigger chiederà le credenziali)
5. Attiva il workflow con il toggle in alto a destra

---

## Step 7 — Test di funzionamento

1. Scrivi al tuo bot Telegram: `ragazza in spiaggia al tramonto`
2. Il bot dovrebbe rispondere con "⏳ Sto generando..."
3. Dopo 30-60 secondi arriva la preview con i bottoni
4. Clicca ✅ Approva
5. Verifica in Supabase → Table Editor → `images` che il record esista con `status = 'approved'`

Se qualcosa non va, controlla i log in n8n (icona esecuzioni nella sidebar).

---

## Struttura del database — Riferimento rapido

### Tabella `characters`
Ogni riga = un personaggio/profilo AI. Modificabile direttamente da Supabase Table Editor senza toccare il codice.

### Tabella `team_members`
Ogni riga = un membro del team. Ruoli:
- `admin` → tutto
- `approver` → approva/scarta/pubblica
- `creator` → solo genera

### Tabella `images`
Il cuore del sistema. Ogni immagine generata ha:
- `status`: `generating → pending → approved/discarded → published`
- `short_id`: 8 caratteri usati nel callbackData Telegram
- `prompt`, `negative_prompt`: il prompt esatto usato
- `generation_time_ms`: tempo di generazione in ms

### Tabella `editorial_calendar`
Per il Livello 3 (automazione). Scene pianificate collegate ai personaggi.

### View `pending_approvals`
Query pronta per vedere tutte le immagini in attesa:
```sql
SELECT * FROM pending_approvals;
```

### View `approval_rate_by_character`
Analytics sul tasso di approvazione per personaggio:
```sql
SELECT * FROM approval_rate_by_character;
```

---

## Prossimi passi (Livelli successivi)

| Livello | Feature | Prossimo file |
|---------|---------|---------------|
| **2a** | Validazione qualità automatica (Claude Vision) | `workflow_quality_validator.json` |
| **2b** | Ruoli avanzati + selezione personaggio con inline keyboard | `workflow_character_selector.json` |
| **3** | Calendario editoriale + pubblicazione automatica | `workflow_scheduler.json` |
| **4** | Analytics e ottimizzazione prompt | `workflow_analytics.json` |

---

## Troubleshooting

**Il bot non risponde:**
→ Verifica che il workflow sia attivo (toggle verde in n8n)
→ Controlla che il `telegram_chat_id` in DB sia corretto

**Errore "Nessun personaggio attivo trovato":**
→ Assicurati di aver inserito almeno un personaggio con `is_active = true`

**Errore 401 Supabase:**
→ Stai usando l'`anon` key invece della `service_role` key

**Il record immagine non viene creato:**
→ Verifica che i valori `character_id` e `member_id` siano UUID validi presenti nel DB

**Tempo di risposta lento (>3s prima di "⏳ generando..."):**
→ La query `Cerca Membro in DB` fa una chiamata HTTP — normale. Si può ottimizzare con caching in futuro.
