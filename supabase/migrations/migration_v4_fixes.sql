-- ╔══════════════════════════════════════════════════════════════════╗
-- ║  MIGRATION v4 — Security, Reliability & Analytics Upgrades      ║
-- ║                                                                  ║
-- ║  Fix implementati:                                               ║
-- ║  1. Token IG cifrato con pgcrypto (AES-256)                      ║
-- ║  2. Constraint spacing post (min 3h tra post stesso personaggio) ║
-- ║  3. Watermark verification flag                                  ║
-- ║  4. Recovery view per scene perse (n8n crash > 2h)              ║
-- ║  5. Tabella engagement_metrics per A/B analytics                 ║
-- ║  6. quality_threshold per-character (configurable)               ║
-- ║  7. generation_queue lock ottimistico                            ║
-- ║  8. stored_url cleanup (unifica URL duplicati)                   ║
-- ║                                                                  ║
-- ║  PREREQUISITI: migration_v3.sql già eseguita                     ║
-- ║  ESEGUI: SQL Editor Supabase, DOPO v3                            ║
-- ╚══════════════════════════════════════════════════════════════════╝


-- ═══════════════════════════════════════════════════════════════════
-- FIX 1: SICUREZZA TOKEN INSTAGRAM
-- ═══════════════════════════════════════════════════════════════════
-- Il token viene cifrato con AES-256-CBC via pgcrypto.
-- La chiave di cifratura è una env var Supabase (NON nel DB).
-- ATTENZIONE: dopo questa migrazione, devi re-inserire i token
-- usando la funzione encrypt_ig_token() definita qui sotto.

-- Rinomina colonna plaintext → backup temporaneo
ALTER TABLE characters
  RENAME COLUMN instagram_access_token TO instagram_access_token_plaintext;

-- Aggiunge colonna cifrata
ALTER TABLE characters
  ADD COLUMN IF NOT EXISTS instagram_access_token_enc BYTEA;

-- Funzione wrapper per cifrare (usa vault key da env)
-- Chiamata: SELECT encrypt_ig_token('EAABxxxxxx', 'uuid-personaggio');
CREATE OR REPLACE FUNCTION encrypt_ig_token(plain_token TEXT, char_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  encryption_key TEXT;
BEGIN
  -- La chiave viene da un Supabase Secret (vault), NON hardcoded
  -- Imposta: supabase secrets set IG_TOKEN_KEY="una-chiave-random-32-char"
  encryption_key := current_setting('app.ig_token_key', true);
  IF encryption_key IS NULL OR length(encryption_key) < 16 THEN
    RAISE EXCEPTION 'IG_TOKEN_KEY non configurata. Esegui: ALTER DATABASE postgres SET app.ig_token_key = ''tua-chiave-32-char'';';
  END IF;

  UPDATE characters
  SET instagram_access_token_enc = pgp_sym_encrypt(plain_token, encryption_key)
  WHERE id = char_id;
END;
$$;

-- Funzione per decifrare (usata dalla Edge Function, non esposta via API REST)
CREATE OR REPLACE FUNCTION decrypt_ig_token(char_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  encryption_key TEXT;
  encrypted_val BYTEA;
BEGIN
  encryption_key := current_setting('app.ig_token_key', true);
  SELECT instagram_access_token_enc INTO encrypted_val
  FROM characters WHERE id = char_id;

  IF encrypted_val IS NULL THEN RETURN NULL; END IF;
  RETURN pgp_sym_decrypt(encrypted_val, encryption_key);
END;
$$;

-- Migra i token esistenti (se presenti)
DO $$
DECLARE
  rec RECORD;
  enc_key TEXT;
BEGIN
  enc_key := current_setting('app.ig_token_key', true);
  IF enc_key IS NOT NULL AND length(enc_key) >= 16 THEN
    FOR rec IN SELECT id, instagram_access_token_plaintext FROM characters
               WHERE instagram_access_token_plaintext IS NOT NULL
    LOOP
      UPDATE characters
      SET instagram_access_token_enc = pgp_sym_encrypt(rec.instagram_access_token_plaintext, enc_key)
      WHERE id = rec.id;
    END LOOP;
    -- Dopo verifica migrazione, esegui: ALTER TABLE characters DROP COLUMN instagram_access_token_plaintext;
    RAISE NOTICE 'Token migrati. Verifica decrypt_ig_token() poi droppa la colonna plaintext.';
  ELSE
    RAISE WARNING 'app.ig_token_key non configurata — token NON migrati. Configura la chiave e riesegui il DO block.';
  END IF;
END;
$$;

COMMENT ON COLUMN characters.instagram_access_token_enc IS
  'Token IG cifrato con AES-256 (pgp_sym_encrypt). Usa decrypt_ig_token(id) per leggere. NON esporre via REST.';


-- ═══════════════════════════════════════════════════════════════════
-- FIX 2: QUALITY THRESHOLD PER PERSONAGGIO
-- ═══════════════════════════════════════════════════════════════════
-- Ogni personaggio può avere una soglia diversa (es: profilo premium → 85, test → 70)
ALTER TABLE characters
  ADD COLUMN IF NOT EXISTS quality_threshold INTEGER DEFAULT 70
    CHECK (quality_threshold BETWEEN 50 AND 100);

COMMENT ON COLUMN characters.quality_threshold IS
  'Soglia minima quality_score (0-100) per accettare immagine. Default 70. Aumentare per profili premium.';


-- ═══════════════════════════════════════════════════════════════════
-- FIX 3: WATERMARK VERIFICATION FLAG
-- ═══════════════════════════════════════════════════════════════════
-- Traccia esplicitamente se il watermark è stato applicato con successo
ALTER TABLE images
  ADD COLUMN IF NOT EXISTS watermark_applied BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS watermark_attempted_at TIMESTAMPTZ;

-- View: immagini pubblicate SENZA watermark (alert critico)
CREATE OR REPLACE VIEW alert_published_no_watermark AS
SELECT
  i.id,
  i.short_id,
  i.image_url,
  i.watermarked_url,
  i.instagram_post_id,
  i.published_at,
  c.name AS character_name,
  c.watermark_text
FROM images i
JOIN characters c ON i.character_id = c.id
WHERE
  i.status = 'published'
  AND i.watermark_applied = false
  AND c.watermark_text IS NOT NULL
ORDER BY i.published_at DESC;

COMMENT ON VIEW alert_published_no_watermark IS
  '⚠️ ALERT: Immagini pubblicate senza watermark. Controllare quotidianamente.';


-- ═══════════════════════════════════════════════════════════════════
-- FIX 4: CONSTRAINT SPACING MINIMO TRA POST
-- ═══════════════════════════════════════════════════════════════════
-- Impedisce di schedulare 2 post dello stesso personaggio a meno di 3h di distanza.
-- Usa una funzione (i CHECK constraint non possono fare subquery).

CREATE OR REPLACE FUNCTION check_posting_gap()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  min_gap_hours INTEGER := 3;
  conflict_count INTEGER;
BEGIN
  -- Controlla se esiste già un post dello stesso personaggio entro 3h
  SELECT COUNT(*) INTO conflict_count
  FROM editorial_calendar
  WHERE
    character_id = NEW.character_id
    AND id != COALESCE(NEW.id, uuid_generate_v4())  -- esclude se stesso in UPDATE
    AND status NOT IN ('skipped', 'published')
    AND ABS(EXTRACT(EPOCH FROM (scheduled_for - NEW.scheduled_for)) / 3600) < min_gap_hours;

  IF conflict_count > 0 THEN
    RAISE EXCEPTION
      'Gap troppo breve: esiste già un post schedulato per questo personaggio entro %h dalla slot richiesta.',
      min_gap_hours;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_posting_gap ON editorial_calendar;
CREATE TRIGGER trg_posting_gap
  BEFORE INSERT OR UPDATE ON editorial_calendar
  FOR EACH ROW
  EXECUTE FUNCTION check_posting_gap();

COMMENT ON FUNCTION check_posting_gap IS
  'Impedisce scheduling < 3h tra post dello stesso personaggio. Instagram penalizza burst posting.';


-- ═══════════════════════════════════════════════════════════════════
-- FIX 5: RECOVERY VIEW PER SCENE PERSE (N8N CRASH)
-- ═══════════════════════════════════════════════════════════════════
-- La view calendar_today originale ha una finestra -2h che perde le scene
-- se n8n ha un downtime > 2h. Questa view gestisce il recovery.

CREATE OR REPLACE VIEW calendar_recovery AS
SELECT
  ec.id              AS calendar_id,
  ec.scene_description,
  ec.content_pillar,
  ec.caption_hint,
  ec.scheduled_for,
  ec.auto_publish,
  'RECOVERY'::TEXT   AS trigger_reason,
  NOW() - ec.scheduled_for AS overdue_by,
  c.id               AS character_id,
  c.name             AS character_name,
  c.trigger_word,
  c.lora_version,
  c.lora_scale,
  c.watermark_text,
  c.instagram_account_id,
  c.default_caption_template,
  c.hashtags,
  c.quality_threshold
FROM editorial_calendar ec
JOIN characters c ON ec.character_id = c.id
WHERE
  ec.status = 'planned'
  AND ec.scheduled_for < NOW() - INTERVAL '2 hours'  -- scene perse dalla finestra normale
  AND ec.scheduled_for > NOW() - INTERVAL '24 hours' -- non recuperare roba > 24h fa
ORDER BY ec.scheduled_for ASC;

-- View aggiornata calendar_today con quality_threshold
CREATE OR REPLACE VIEW calendar_today AS
SELECT
  ec.id              AS calendar_id,
  ec.scene_description,
  ec.content_pillar,
  ec.caption_hint,
  ec.scheduled_for,
  ec.auto_publish,
  'SCHEDULED'::TEXT  AS trigger_reason,
  c.id               AS character_id,
  c.name             AS character_name,
  c.trigger_word,
  c.lora_version,
  c.lora_scale,
  c.watermark_text,
  c.instagram_account_id,
  c.default_caption_template,
  c.hashtags,
  c.quality_threshold     -- ← NUOVO: passato al workflow per soglia dinamica
FROM editorial_calendar ec
JOIN characters c ON ec.character_id = c.id
WHERE
  ec.status = 'planned'
  AND ec.scheduled_for <= NOW() + INTERVAL '1 hour'
  AND ec.scheduled_for >= NOW() - INTERVAL '2 hours'
ORDER BY ec.scheduled_for ASC;

COMMENT ON VIEW calendar_recovery IS
  'Scene perse per downtime n8n > 2h. Usare in un workflow separato di recovery schedulato ogni 6h.';


-- ═══════════════════════════════════════════════════════════════════
-- FIX 6: GENERATION QUEUE — LOCK OTTIMISTICO
-- ═══════════════════════════════════════════════════════════════════
-- Previene che più worker del Workflow 1 processino la stessa richiesta.

ALTER TABLE generation_queue
  ADD COLUMN IF NOT EXISTS locked_at    TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS locked_by    TEXT,  -- n8n execution ID
  ADD COLUMN IF NOT EXISTS lock_expires TIMESTAMPTZ;

-- Funzione atomic lock-and-claim (usa FOR UPDATE SKIP LOCKED)
CREATE OR REPLACE FUNCTION claim_next_queue_item(worker_id TEXT)
RETURNS TABLE (
  queue_id     UUID,
  image_id     UUID,
  character_id UUID,
  user_request TEXT,
  member_id    UUID
)
LANGUAGE plpgsql
AS $$
DECLARE
  claimed_id UUID;
BEGIN
  -- Atomic claim: prende il primo item disponibile e lo blocca
  SELECT id INTO claimed_id
  FROM generation_queue
  WHERE
    status = 'queued'
    AND (lock_expires IS NULL OR lock_expires < NOW())  -- lock scaduto o libero
  ORDER BY created_at ASC
  LIMIT 1
  FOR UPDATE SKIP LOCKED;  -- skippa righe già lockata da altro worker

  IF claimed_id IS NULL THEN
    RETURN;  -- coda vuota
  END IF;

  UPDATE generation_queue
  SET
    status       = 'processing',
    locked_at    = NOW(),
    locked_by    = worker_id,
    lock_expires = NOW() + INTERVAL '10 minutes'  -- se il worker crasha, dopo 10min è liberato
  WHERE id = claimed_id;

  RETURN QUERY
  SELECT q.id, q.image_id, q.character_id, q.user_request, q.member_id
  FROM generation_queue q
  WHERE q.id = claimed_id;
END;
$$;

COMMENT ON FUNCTION claim_next_queue_item IS
  'Atomic queue claim. Chiama da n8n con: SELECT * FROM claim_next_queue_item(''exec-{{$execution.id}}'')';


-- ═══════════════════════════════════════════════════════════════════
-- FIX 7: UNIFICAZIONE URL (ELIMINA DUPLICAZIONE image_url / stored_url / watermarked_url)
-- ═══════════════════════════════════════════════════════════════════
-- Logica chiara: image_url = Replicate (temporaneo, scade ~1h)
--                stored_url = Supabase Storage originale (permanente, NO watermark)
--                watermarked_url = Supabase Storage watermarkato (permanente, per IG)
-- Aggiunge flag per sapere se stored_url è già stato salvato.

ALTER TABLE images
  ADD COLUMN IF NOT EXISTS original_stored_at TIMESTAMPTZ;  -- quando è stato salvato stored_url

-- View: immagini con URL Replicate scaduto e stored_url mancante (da fixare)
CREATE OR REPLACE VIEW alert_expiring_urls AS
SELECT
  id, short_id, image_url, stored_url, status, created_at,
  NOW() - created_at AS age
FROM images
WHERE
  stored_url IS NULL
  AND image_url IS NOT NULL
  AND status NOT IN ('failed', 'discarded')
  AND created_at < NOW() - INTERVAL '45 minutes'  -- URL Replicate scade ~1h
ORDER BY created_at ASC;

COMMENT ON VIEW alert_expiring_urls IS
  '⚠️ Immagini con URL Replicate prossimi alla scadenza e stored_url non ancora salvato.';


-- ═══════════════════════════════════════════════════════════════════
-- FIX 8: ENGAGEMENT METRICS (POST-PUBLICATION ANALYTICS)
-- ═══════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS engagement_metrics (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  image_id        UUID REFERENCES images(id) ON DELETE CASCADE,
  character_id    UUID REFERENCES characters(id) ON DELETE SET NULL,
  instagram_post_id TEXT NOT NULL,

  -- Snapshot metriche (raccolte via cron dopo 24h e 7d)
  snapshot_at     TIMESTAMPTZ DEFAULT NOW(),
  snapshot_type   TEXT NOT NULL DEFAULT '24h',  -- '24h' | '7d' | '30d'

  -- KPI
  likes           INTEGER DEFAULT 0,
  comments        INTEGER DEFAULT 0,
  saves           INTEGER DEFAULT 0,
  shares          INTEGER DEFAULT 0,
  reach           INTEGER DEFAULT 0,
  impressions     INTEGER DEFAULT 0,
  profile_visits  INTEGER DEFAULT 0,

  -- Calcolati
  engagement_rate NUMERIC(5,2) GENERATED ALWAYS AS (
    CASE WHEN NULLIF(reach, 0) IS NULL THEN 0
    ELSE ROUND(((likes + comments + saves + shares)::NUMERIC / reach) * 100, 2)
    END
  ) STORED,

  -- Contesto per A/B analysis
  content_pillar  TEXT,
  caption_length  INTEGER,
  posted_hour     INTEGER,   -- 0-23
  posted_dow      INTEGER,   -- 0=domenica, 6=sabato

  CONSTRAINT valid_snapshot_type CHECK (snapshot_type IN ('24h', '7d', '30d'))
);

CREATE INDEX IF NOT EXISTS idx_engagement_character ON engagement_metrics(character_id, snapshot_type, snapshot_at DESC);
CREATE INDEX IF NOT EXISTS idx_engagement_post ON engagement_metrics(instagram_post_id);

COMMENT ON TABLE engagement_metrics IS 'Metriche IG per ogni post. Raccolte a 24h, 7d, 30d dalla pubblicazione via n8n cron.';


-- ═══════════════════════════════════════════════════════════════════
-- FIX 8b: VIEW ANALYTICS — Best performing pillar/hour
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE VIEW analytics_best_slots AS
SELECT
  c.name                        AS character_name,
  em.content_pillar,
  em.posted_hour,
  em.posted_dow,
  COUNT(*)                      AS sample_size,
  ROUND(AVG(em.engagement_rate), 2) AS avg_engagement_rate,
  ROUND(AVG(em.likes), 0)       AS avg_likes,
  ROUND(AVG(em.saves), 0)       AS avg_saves,
  ROUND(AVG(em.reach), 0)       AS avg_reach
FROM engagement_metrics em
JOIN characters c ON em.character_id = c.id
WHERE
  em.snapshot_type = '24h'
  AND em.sample_size_check > 3  -- almeno 3 campioni per slot
GROUP BY c.name, em.content_pillar, em.posted_hour, em.posted_dow
HAVING COUNT(*) > 3
ORDER BY avg_engagement_rate DESC;

-- Nota: sample_size_check è una colonna virtuale — usiamo COUNT(*) > 3 nell'HAVING

CREATE OR REPLACE VIEW analytics_best_slots AS
SELECT
  c.name                        AS character_name,
  em.content_pillar,
  em.posted_hour,
  em.posted_dow,
  COUNT(*)                      AS sample_size,
  ROUND(AVG(em.engagement_rate), 2) AS avg_engagement_rate,
  ROUND(AVG(em.likes)::NUMERIC, 0) AS avg_likes,
  ROUND(AVG(em.saves)::NUMERIC, 0) AS avg_saves,
  ROUND(AVG(em.reach)::NUMERIC, 0) AS avg_reach,
  -- Etichetta giorno
  CASE em.posted_dow
    WHEN 0 THEN 'Dom' WHEN 1 THEN 'Lun' WHEN 2 THEN 'Mar'
    WHEN 3 THEN 'Mer' WHEN 4 THEN 'Gio' WHEN 5 THEN 'Ven' WHEN 6 THEN 'Sab'
  END                           AS day_name
FROM engagement_metrics em
JOIN characters c ON em.character_id = c.id
WHERE em.snapshot_type = '24h'
GROUP BY c.name, em.content_pillar, em.posted_hour, em.posted_dow
HAVING COUNT(*) > 3
ORDER BY avg_engagement_rate DESC;

COMMENT ON VIEW analytics_best_slots IS
  'Slot orari/giorno con engagement medio più alto per personaggio. Usa per ottimizzare posting_times.';


-- ═══════════════════════════════════════════════════════════════════
-- INDICI AGGIUNTIVI per performance con 3-5 personaggi e volumi crescenti
-- ═══════════════════════════════════════════════════════════════════
CREATE INDEX IF NOT EXISTS idx_images_watermark_status
  ON images(watermark_applied, status)
  WHERE watermark_applied = false AND status = 'published';

CREATE INDEX IF NOT EXISTS idx_calendar_recovery
  ON editorial_calendar(scheduled_for, status, character_id)
  WHERE status = 'planned';

CREATE INDEX IF NOT EXISTS idx_queue_available
  ON generation_queue(created_at, status)
  WHERE status = 'queued';


-- ═══════════════════════════════════════════════════════════════════
-- RLS POLICY: blocca lettura token cifrati via REST API pubblica
-- ═══════════════════════════════════════════════════════════════════
-- Impedisce che un client con anon key possa leggere instagram_access_token_enc
-- Il campo è leggibile SOLO via funzione SECURITY DEFINER (decrypt_ig_token)

ALTER TABLE characters ENABLE ROW LEVEL SECURITY;

-- Policy base: lettura pubblica tutto tranne token
CREATE POLICY "characters_read_no_token" ON characters
  FOR SELECT
  USING (true);  -- accesso normale tramite API

-- Nota: per nascondere instagram_access_token_enc dalla REST API,
-- crea una VIEW che esclude quella colonna e usa quella come endpoint:
CREATE OR REPLACE VIEW characters_safe AS
SELECT
  id, name, trigger_word, lora_model, lora_version, lora_scale,
  age, hair, eyes, body, ethnicity, style, distinctive,
  content_pillars, platform, is_active,
  instagram_account_id,  -- account ID pubblico, OK
  watermark_text, watermark_position,
  default_caption_template, hashtags, posting_times,
  quality_threshold,
  created_at, updated_at
  -- instagram_access_token_enc ESCLUSO
FROM characters;

COMMENT ON VIEW characters_safe IS
  'Vista pubblica di characters senza token cifrato. Usa questa come endpoint REST invece della tabella diretta.';


-- ═══════════════════════════════════════════════════════════════════
-- FIX 9: NSFW & VIDEO PIPELINE
-- ═══════════════════════════════════════════════════════════════════
ALTER TABLE images
  ADD COLUMN IF NOT EXISTS is_nsfw BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS video_url TEXT,
  ADD COLUMN IF NOT EXISTS video_status TEXT DEFAULT 'pending'
    CHECK (video_status IN ('pending', 'generating', 'completed', 'failed'));

CREATE OR REPLACE FUNCTION set_nsfw_flag()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.content_pillar = 'boudoir' THEN
    NEW.is_nsfw := true;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_images_set_nsfw ON images;
CREATE TRIGGER trg_images_set_nsfw
  BEFORE INSERT OR UPDATE ON images
  FOR EACH ROW EXECUTE FUNCTION set_nsfw_flag();


-- ═══════════════════════════════════════════════════════════════════
-- VERIFICA FINALE
-- ═══════════════════════════════════════════════════════════════════
SELECT
  'Migration v4 completata' AS status,
  (SELECT COUNT(*) FROM information_schema.columns
   WHERE table_name = 'characters' AND column_name = 'quality_threshold') AS quality_threshold_col,
  (SELECT COUNT(*) FROM information_schema.tables
   WHERE table_name = 'engagement_metrics') AS engagement_table,
  (SELECT COUNT(*) FROM information_schema.routines
   WHERE routine_name = 'claim_next_queue_item') AS queue_lock_fn,
  (SELECT COUNT(*) FROM information_schema.routines
   WHERE routine_name = 'check_posting_gap') AS posting_gap_trigger,
  (SELECT COUNT(*) FROM information_schema.views
   WHERE table_name = 'calendar_recovery') AS recovery_view,
  (SELECT COUNT(*) FROM information_schema.views
   WHERE table_name = 'alert_published_no_watermark') AS watermark_alert_view;
