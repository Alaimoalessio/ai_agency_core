// ╔══════════════════════════════════════════════════════════════════╗
// ║  IMPLEMENTATION GUIDE — AI Character Content System v4          ║
// ║  Tutti i fix da applicare, in ordine di priorità                ║
// ╚══════════════════════════════════════════════════════════════════╝

/**
 * ═══════════════════════════════════════════════════
 * STEP 0 — PRIMA DI TUTTO: Configura la chiave di cifratura
 * ═══════════════════════════════════════════════════
 * 
 * Nel SQL Editor di Supabase, esegui:
 * 
 *   ALTER DATABASE postgres
 *     SET app.ig_token_key = 'scegli-una-chiave-random-almeno-32-char';
 * 
 * Poi riavvia il DB (o aspetta qualche secondo).
 * Questa chiave NON compare mai nel codice o nel DB — è una config di sistema.
 * 
 * ─────────────────────────────────────────────────────
 * STEP 1 — Esegui migration_v4_fixes.sql
 * ─────────────────────────────────────────────────────
 * 
 * SQL Editor → incolla migration_v4_fixes.sql → Run
 * Verifica l'output finale (deve mostrare tutto a 1).
 * 
 * ─────────────────────────────────────────────────────
 * STEP 2 — Cifra i token esistenti
 * ─────────────────────────────────────────────────────
 * 
 * Per ogni personaggio con token IG già inserito, esegui:
 * 
 *   SELECT encrypt_ig_token('EAABxxxxxxxxx', 'uuid-del-personaggio');
 * 
 * Verifica che funzioni:
 * 
 *   SELECT decrypt_ig_token('uuid-del-personaggio');  -- deve tornare il token
 * 
 * Quando confermato, droppa la colonna plaintext:
 * 
 *   ALTER TABLE characters DROP COLUMN instagram_access_token_plaintext;
 * 
 * ─────────────────────────────────────────────────────
 * STEP 3 — Deploy Edge Function v2
 * ─────────────────────────────────────────────────────
 * 
 *   supabase functions deploy add-watermark --project-ref TUO_PROJECT_REF
 * 
 * Il file è: supabase-edge-function-watermark-v2.ts
 * 
 * ─────────────────────────────────────────────────────
 * STEP 4 — Aggiorna Workflow 2 (Scheduler)
 * ─────────────────────────────────────────────────────
 * 
 * Nel nodo "Estrai URL Watermark", aggiungi questo controllo:
 * 
 *   const wmResponse = $input.item.json;
 *   const prev = $('Prepara Watermark').item.json;
 * 
 *   const watermarkedUrl = wmResponse.public_url || wmResponse.url || prev.image_url;
 *   const watermarkApplied = wmResponse.watermarked === true;
 * 
 *   // NUOVO: se watermark fallito, blocca la pubblicazione automatica
 *   if (!watermarkApplied && prev.auto_publish) {
 *     // Notifica admin e metti in coda manuale invece di pubblicare
 *     return {
 *       ...prev,
 *       watermarked_url: watermarkedUrl,
 *       watermark_applied: false,
 *       auto_publish: false,  // Forza approvazione manuale
 *       watermark_warning: wmResponse.warning || 'Watermark non applicato'
 *     };
 *   }
 * 
 *   return { ...prev, watermarked_url: watermarkedUrl, watermark_applied: true };
 * 
 * ─────────────────────────────────────────────────────
 * STEP 5 — Importa Sub-Workflow in n8n
 * ─────────────────────────────────────────────────────
 * 
 * 1. n8n → Import from File → workflow3_sub_genera_valida.json
 * 2. Abilita il workflow (deve essere attivo per essere chiamato)
 * 3. Copia il workflow ID (visibile nell'URL: /workflow/XXXXX)
 * 4. Nei Workflow 1 e 2, sostituisci i nodi Claude+FLUX+Vision
 *    con un singolo nodo "Execute Workflow":
 *    - Workflow ID: [ID copiato sopra]
 *    - Wait for sub-workflow: TRUE
 *    - Pass input data: TRUE
 * 
 * ─────────────────────────────────────────────────────
 * STEP 6 — Importa Workflow 4 (Engagement)
 * ─────────────────────────────────────────────────────
 * 
 * 1. n8n → Import from File → workflow4_engagement_metrics.json
 * 2. Configura env var TELEGRAM_ADMIN_CHAT_ID se non già presente
 * 3. Attiva il workflow
 * 4. Dopo 7+ giorni di pubblicazione, query per ottimizzare:
 *    SELECT * FROM analytics_best_slots;
 * 
 * ─────────────────────────────────────────────────────
 * STEP 7 — Workflow Recovery (opzionale ma consigliato)
 * ─────────────────────────────────────────────────────
 * 
 * Crea un nuovo workflow n8n con:
 * - Trigger: ogni 6h (0 */6 * * *)
 * - HTTP GET → Supabase: SELECT * FROM calendar_recovery
 * - IF: ci sono scene? → esegui sub-workflow (Execute Workflow node)
 * - Questo recupera le scene perse per downtime n8n
 * 
 * ─────────────────────────────────────────────────────
 * STEP 8 — Configura quality_threshold per personaggio
 * ─────────────────────────────────────────────────────
 * 
 * Aggiorna il threshold per ogni personaggio:
 * 
 *   UPDATE characters SET quality_threshold = 80
 *   WHERE name = 'Sofia';  -- profilo premium → soglia più alta
 * 
 *   UPDATE characters SET quality_threshold = 70
 *   WHERE name = 'Test';   -- profilo test → soglia base
 * 
 * ─────────────────────────────────────────────────────
 * MONITORAGGIO QUOTIDIANO — Query utili
 * ─────────────────────────────────────────────────────
 * 
 * -- Immagini pubblicate senza watermark (deve essere 0):
 * SELECT * FROM alert_published_no_watermark;
 * 
 * -- URL Replicate in scadenza non ancora salvati:
 * SELECT * FROM alert_expiring_urls;
 * 
 * -- Scene di oggi da generare:
 * SELECT * FROM calendar_today;
 * 
 * -- Scene perse (recovery):
 * SELECT * FROM calendar_recovery;
 * 
 * -- Stats pubblicazione per personaggio:
 * SELECT * FROM publication_stats;
 * 
 * -- Best orari/pillar per engagement:
 * SELECT * FROM analytics_best_slots;
 * 
 * -- Coda bloccata (lock scaduto):
 * SELECT * FROM generation_queue
 * WHERE status = 'processing' AND lock_expires < NOW();
 * -- Fix: UPDATE generation_queue SET status='queued', locked_by=NULL WHERE ...
 */

/**
 * ═══════════════════════════════════════════════════
 * ROADMAP — Prossimi livelli da implementare
 * ═══════════════════════════════════════════════════
 * 
 * LIVELLO 5 — Token Rotation Automatica
 *   - I token IG scadono ogni 60 giorni
 *   - Workflow schedulato mensile che chiama IG API /refresh_access_token
 *   - Aggiorna il token cifrato in DB automaticamente
 *   - Notifica admin 7gg prima della scadenza
 * 
 * LIVELLO 6 — Multi-platform
 *   - characters.platform è già TEXT, supporta 'fanvue', 'onlyfans'
 *   - Workflow di publishing condizionale su platform
 *   - Tabella platform_configs per credenziali per-platform
 * 
 * LIVELLO 7 — Ottimizzazione automatica calendario
 *   - Ogni settimana, query analytics_best_slots
 *   - Claude analizza i dati e propone aggiornamenti a posting_times
 *   - Admin approva via Telegram → UPDATE characters SET posting_times = ...
 * 
 * LIVELLO 8 — Content variation testing
 *   - Genera 2 immagini per lo stesso slot
 *   - Pubblica entrambe su giorni diversi
 *   - Confronta engagement via engagement_metrics
 *   - Identifica automaticamente il "content_pillar" che performa meglio
 */
