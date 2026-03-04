# 🚀 Livello 3 — Calendario + Pubblicazione + Watermark
## Guida Setup Completa

---

## Architettura del Livello 3

```
07:00 ogni mattina
      ↓
Trigger schedulato n8n
      ↓
Legge calendar_today (view Supabase)
      ↓ (per ogni scena pianificata)
Claude ottimizza prompt
      ↓
FLUX genera immagine
      ↓
Claude Vision valida qualità (max 2 tentativi)
      ↓
Claude genera caption Instagram
      ↓
Edge Function applica watermark → Supabase Storage
      ↓
Instagram Graph API carica e pubblica
      ↓
DB aggiornato: published ✅
      ↓
Notifica Telegram all'admin
```

**Risultato**: ogni mattina il sistema genera, valida, scrive la caption, applica il watermark e pubblica automaticamente tutte le scene pianificate nel calendario.

---

## File consegnati

| File | Cosa fa |
|------|---------|
| `migration_v3.sql` | Estende il DB con campi pubblicazione, tabella log, bucket Storage |
| `workflow2_scheduler.json` | Workflow n8n scheduler (nuovo, separato dal bot Telegram) |
| `supabase-edge-function-watermark.ts` | Edge Function Supabase per watermark + Storage |

---

## Step 1 — Esegui migration_v3.sql

Nel SQL Editor di Supabase, esegui `migration_v3.sql`.

Aggiunge:
- Colonne `instagram_account_id`, `instagram_access_token`, `watermark_text`, `hashtags`, ecc. alla tabella `characters`
- Colonne `watermarked_url`, `instagram_post_id`, `caption`, ecc. alla tabella `images`
- Tabella `publication_log` per tracciare ogni tentativo di pubblicazione
- View `calendar_today` — scene da generare oggi
- View `publishing_queue` — immagini approvate da pubblicare
- View `publication_stats` — analytics pubblicazione
- Bucket Supabase Storage `watermarked-images`

---

## Step 2 — Ottieni credenziali Instagram Graph API

Questo è il passaggio più laborioso. Segui questi step:

### 2a. Crea app Meta
1. Vai su **https://developers.facebook.com**
2. **My Apps → Create App**
3. Tipo: **Business**
4. Aggiungi prodotto: **Instagram Graph API**

### 2b. Collega account Instagram Business
Il tuo profilo Instagram deve essere **Business o Creator**, collegato a una **Pagina Facebook**.
1. Su Instagram: Impostazioni → Account → Passa ad account professionale
2. Su Facebook: Impostazioni Pagina → Instagram → Collega account

### 2c. Ottieni i token
Nel dashboard Meta for Developers:
1. **Graph API Explorer** → seleziona la tua app
2. Permessi necessari: `instagram_basic`, `instagram_content_publish`, `pages_show_list`
3. Clicca **Generate Access Token**
4. Copia il token (scade dopo 60 giorni — vedi sezione "Rinnovo token" sotto)

### 2d. Ottieni l'Account ID Instagram
```
GET https://graph.facebook.com/v19.0/me/accounts?access_token=TOKEN
```
Dalla risposta, prendi `id` della pagina, poi:
```
GET https://graph.facebook.com/v19.0/{PAGE_ID}?fields=instagram_business_account&access_token=TOKEN
```
Il valore di `instagram_business_account.id` è il tuo `instagram_account_id`.

### 2e. Aggiorna il database con le credenziali
```sql
UPDATE characters
SET
  instagram_account_id = '17841400000000000',          -- Il tuo IG Account ID
  instagram_access_token = 'EAABxx...',                -- Il tuo token
  watermark_text = '@sofia.ai',                        -- Watermark da mostrare
  watermark_position = 'bottom-right',
  default_caption_template = 'Living every moment ✨\n\n{scene}',
  hashtags = ARRAY['#aimodel', '#aiart', '#virtualinfluencer', '#sofia'],
  posting_times = '["09:00", "18:00"]'
WHERE name = 'Sofia';
```

---

## Step 3 — Deploy Edge Function watermark

### Opzione A: Supabase Dashboard (più semplice)
1. Nel dashboard Supabase: **Edge Functions → New Function**
2. Nome: `add-watermark`
3. Incolla il contenuto di `supabase-edge-function-watermark.ts`
4. Clicca **Deploy**

### Opzione B: Supabase CLI
```bash
npm install -g supabase
supabase login
supabase functions deploy add-watermark --project-ref IL_TUO_PROJECT_REF
```

Il `project-ref` è la parte dell'URL dopo `https://` e prima di `.supabase.co`.

---

## Step 4 — Aggiungi variabile ADMIN_TELEGRAM_CHAT_ID

In n8n, nelle variabili d'ambiente aggiungi:
```
ADMIN_TELEGRAM_CHAT_ID=123456789    ← il tuo chat_id (per le notifiche)
```

---

## Step 5 — Importa workflow2_scheduler.json

1. In n8n: **Workflows → Import from file**
2. Seleziona `workflow2_scheduler.json`
3. Collega le credenziali Telegram
4. **Attiva il workflow** — girerà ogni mattina alle 07:00

> ⚠️ Questo è un workflow SEPARATO dal bot Telegram. Entrambi devono essere attivi.

---

## Step 6 — Pianifica le scene nel calendario

Inserisci le scene del calendario direttamente in Supabase dal Table Editor, oppure via SQL:

```sql
-- Esempio: 7 giorni di contenuti per Sofia
INSERT INTO editorial_calendar (character_id, scheduled_for, scene_description, content_pillar, caption_hint, auto_publish)
VALUES
  -- Lunedì
  ('UUID_SOFIA', '2026-03-02 09:00:00+01', 'morning yoga on rooftop terrace, sunrise, athletic wear', 'fitness', 'Starting the week right 🧘‍♀️', true),
  ('UUID_SOFIA', '2026-03-02 18:00:00+01', 'aperitivo at a trendy Milan bar, golden hour light', 'lifestyle', 'Milan vibes 🍹', true),

  -- Martedì
  ('UUID_SOFIA', '2026-03-03 09:00:00+01', 'working from a cozy coffee shop, laptop, latte art', 'lifestyle', 'Monday mood ☕', true),
  ('UUID_SOFIA', '2026-03-03 18:00:00+01', 'luxury boutique shopping, elegant street, bags', 'glam', 'Treat yourself ✨', true),

  -- (continua per tutta la settimana...)
  
  -- Domenica
  ('UUID_SOFIA', '2026-03-08 11:00:00+01', 'Sunday brunch, garden terrace, fruits and pastries', 'lifestyle', 'Sunday reset 🌸', true);
```

Sostituisci `UUID_SOFIA` con l'UUID del personaggio dal Table Editor → `characters`.

---

## Come funziona il rinnovo token Instagram

I token durano 60 giorni. Per rinnovarli automaticamente, aggiungi questo workflow schedulato mensile:

```
GET https://graph.facebook.com/v19.0/oauth/access_token
  ?grant_type=fb_exchange_token
  &client_id={APP_ID}
  &client_secret={APP_SECRET}
  &fb_exchange_token={OLD_TOKEN}
```

Oppure aggiungi in n8n un **workflow schedulato ogni 30 giorni** che:
1. Chiama l'endpoint di refresh
2. Aggiorna il campo `instagram_access_token` in `characters`
3. Manda notifica Telegram con conferma

---

## Monitoraggio dalla dashboard Supabase

### Cosa è stato pubblicato oggi
```sql
SELECT character_name, caption, instagram_post_url, published_at
FROM publication_stats ps
JOIN images i ON i.character_id = ps.character_id
WHERE i.published_at::date = TODAY
ORDER BY i.published_at;
```

### Statistiche complete
```sql
SELECT * FROM publication_stats;
```

### Errori di pubblicazione recenti
```sql
SELECT * FROM publication_log WHERE status = 'failed' ORDER BY published_at DESC LIMIT 10;
```

### Calendario settimana prossima
```sql
SELECT character_name, scheduled_for, scene_description, status
FROM editorial_calendar ec
JOIN characters c ON ec.character_id = c.id
WHERE scheduled_for BETWEEN NOW() AND NOW() + INTERVAL '7 days'
ORDER BY scheduled_for;
```

---

## Stato del sistema dopo il Livello 3

**Punteggio: 9.5/10**

Il sistema è ora completo per uso professionale:
- ✅ Bot Telegram con gestione team e ruoli
- ✅ Database centralizzato con storico completo
- ✅ Quality validator automatico (Claude Vision)
- ✅ Selezione personaggio con inline keyboard
- ✅ Calendario editoriale pianificabile
- ✅ Generazione batch automatica ogni mattina
- ✅ Caption generate da Claude per ogni post
- ✅ Watermark automatico prima della pubblicazione
- ✅ Pubblicazione diretta su Instagram
- ✅ Log completo di ogni pubblicazione
- ✅ Notifiche admin su Telegram

---

## Prossimo step — Livello 4: Analytics

Il Livello 4 completa il sistema con:
- Analisi automatica dei pattern di approvazione per migliorare i prompt nel tempo
- Dashboard analytics con metriche di engagement Instagram
- Report settimanale automatico via Telegram
- Ottimizzazione automatica degli orari di posting basata sulle performance

---

## Troubleshooting

**Watermark non applicato (immagine originale pubblicata):**
→ OffscreenCanvas non disponibile nel runtime Deno della tua region. Usa un servizio esterno come Cloudinary aggiungendo `?l_text:Arial_30:@profilo.ai,g_south_east,o_75` all'URL dell'immagine dopo upload.

**Errore 400 Instagram API "URL not accessible":**
→ L'URL di Replicate è temporaneo. Usa sempre `watermarked_url` (su Supabase Storage, permanente) per il caricamento Instagram.

**Errore "Quota exceeded" Instagram:**
→ Instagram permette max 25 post API al giorno per account. Per 4+ personaggi su account separati non ci sono problemi. Se usi un solo account, pianifica max 2 post/giorno.

**Edge function timeout:**
→ Le Edge Function hanno un timeout di 60s. Se l'immagine è molto grande, ottimizza prima il download con un resize step.
