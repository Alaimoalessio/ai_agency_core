-- ╔══════════════════════════════════════════════════════════════════╗
-- ║  AI CHARACTER CONTENT SYSTEM — Database Schema v1.0             ║
-- ║  Compatibile con: Supabase (Postgres), Postgres self-hosted     ║
-- ║                                                                  ║
-- ║  ISTRUZIONI SETUP:                                               ║
-- ║  1. Crea un progetto su supabase.com (free tier)                 ║
-- ║  2. Vai su SQL Editor nel dashboard                              ║
-- ║  3. Incolla e lancia questo script intero                        ║
-- ║  4. Copia l'URL e la Service Role Key da Project Settings > API  ║
-- ╚══════════════════════════════════════════════════════════════════╝

-- ─────────────────────────────────────────────
-- ESTENSIONI
-- ─────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";  -- per uuid_generate_v4()
CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- per gen_random_uuid()


-- ─────────────────────────────────────────────
-- TABELLA: characters
-- Un record per ogni personaggio/profilo AI gestito dal team.
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS characters (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name            TEXT NOT NULL,                    -- Nome del personaggio (es. "Sofia")
  trigger_word    TEXT NOT NULL DEFAULT 'ohwx',     -- Trigger word LoRA
  lora_model      TEXT NOT NULL,                    -- "username/model-name" su Replicate
  lora_version    TEXT NOT NULL,                    -- Hash versione LoRA
  lora_scale      NUMERIC(3,2) DEFAULT 0.85,        -- 0.0 - 1.0

  -- Aspetto fisico (usato per costruire il character sheet)
  age             TEXT,
  hair            TEXT,
  eyes            TEXT,
  body            TEXT,
  ethnicity       TEXT,
  style           TEXT,
  distinctive     TEXT,

  -- Content pillars: categorie di contenuto in JSON
  -- Es: [{"name":"lifestyle","style":"bright natural light, candid"},{"name":"glam","style":"dramatic lighting, luxury setting"}]
  content_pillars JSONB DEFAULT '[]',

  -- Metadati
  platform        TEXT DEFAULT 'instagram',         -- instagram, fanvue, onlyfans, tiktok
  is_active       BOOLEAN DEFAULT true,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE characters IS 'Ogni riga è un personaggio/profilo AI gestito dal team';


-- ─────────────────────────────────────────────
-- TABELLA: team_members
-- Membri del team con ruoli e permessi.
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS team_members (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  telegram_chat_id BIGINT UNIQUE NOT NULL,          -- Chat ID Telegram (da @userinfobot)
  name            TEXT NOT NULL,                    -- Nome del membro (es. "Marco")
  role            TEXT NOT NULL DEFAULT 'creator',  -- 'admin' | 'approver' | 'creator'
  --   admin    → tutto (incluso gestire personaggi e team)
  --   approver → può approvare/scartare/pubblicare
  --   creator  → può solo generare e rigenerare

  is_active       BOOLEAN DEFAULT true,
  created_at      TIMESTAMPTZ DEFAULT NOW(),

  CONSTRAINT valid_role CHECK (role IN ('admin', 'approver', 'creator'))
);

COMMENT ON TABLE team_members IS 'Membri del team con ruoli Telegram';

-- ─────────────────────────────────────────────
-- TABELLA: images
-- Il cuore del sistema: ogni immagine generata.
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS images (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  short_id        TEXT UNIQUE NOT NULL,             -- ID breve (8 char) per callbackData Telegram

  -- Relazioni
  character_id    UUID REFERENCES characters(id) ON DELETE SET NULL,
  generated_by    UUID REFERENCES team_members(id) ON DELETE SET NULL,
  approved_by     UUID REFERENCES team_members(id) ON DELETE SET NULL,

  -- Input
  user_request    TEXT NOT NULL,                    -- Richiesta originale dell'utente
  content_pillar  TEXT,                             -- Categoria scelta (lifestyle, glam, ecc.)

  -- Prompt generato da Claude
  prompt          TEXT,
  negative_prompt TEXT,

  -- Output Replicate
  image_url       TEXT,                             -- URL temporaneo Replicate
  stored_url      TEXT,                             -- URL permanente (dopo upload su storage)
  lora_scale      NUMERIC(3,2),

  -- Stato del ciclo di vita
  status          TEXT NOT NULL DEFAULT 'generating',
  -- 'generating'  → in corso su Replicate
  -- 'pending'     → generata, in attesa di approvazione
  -- 'approved'    → approvata dal team
  -- 'discarded'   → scartata
  -- 'published'   → pubblicata sulla piattaforma
  -- 'failed'      → errore in generazione

  -- Qualità (verrà usata dal validatore automatico - Livello 1)
  quality_score   INTEGER,                          -- 0-100, null se non ancora validata
  quality_issues  TEXT[],                           -- Es: ['blurry face', 'extra fingers']

  -- Pubblicazione
  published_at    TIMESTAMPTZ,
  platform_post_id TEXT,                            -- ID del post sulla piattaforma

  -- Metadati
  generation_time_ms INTEGER,                       -- Tempo di generazione in millisecondi
  attempts        INTEGER DEFAULT 1,                -- Numero di tentativi di generazione
  error_message   TEXT,                             -- Messaggio di errore se failed

  -- NSFW & Video tracking
  is_nsfw         BOOLEAN DEFAULT false,            -- Flag contenuti espliciti
  video_url       TEXT,                             -- URL del video generato (I2V)
  video_status    TEXT DEFAULT 'pending',           -- Stato generazione video: 'pending', 'generating', 'completed', 'failed'

  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW(),

  CONSTRAINT valid_status CHECK (status IN (
    'generating', 'pending', 'approved', 'discarded', 'published', 'failed'
  )),
  CONSTRAINT valid_video_status CHECK (video_status IN (
    'pending', 'generating', 'completed', 'failed'
  ))
);

CREATE INDEX IF NOT EXISTS idx_images_status ON images(status);
CREATE INDEX IF NOT EXISTS idx_images_character_id ON images(character_id);
CREATE INDEX IF NOT EXISTS idx_images_short_id ON images(short_id);
CREATE INDEX IF NOT EXISTS idx_images_created_at ON images(created_at DESC);

COMMENT ON TABLE images IS 'Ogni immagine generata con tutto il suo ciclo di vita';


-- ─────────────────────────────────────────────
-- TABELLA: generation_queue
-- Coda lavori per gestire richieste concorrenti del team.
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS generation_queue (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  image_id        UUID REFERENCES images(id) ON DELETE CASCADE,
  member_id       UUID REFERENCES team_members(id) ON DELETE SET NULL,
  character_id    UUID REFERENCES characters(id) ON DELETE SET NULL,
  user_request    TEXT NOT NULL,
  position        INTEGER,                          -- Posizione in coda (calcolata automaticamente)
  status          TEXT DEFAULT 'queued',            -- 'queued' | 'processing' | 'done' | 'failed'
  created_at      TIMESTAMPTZ DEFAULT NOW(),

  CONSTRAINT valid_queue_status CHECK (status IN ('queued', 'processing', 'done', 'failed'))
);

CREATE INDEX IF NOT EXISTS idx_queue_status ON generation_queue(status, created_at);

COMMENT ON TABLE generation_queue IS 'Coda FIFO per generazioni concorrenti del team';


-- ─────────────────────────────────────────────
-- TABELLA: editorial_calendar
-- Calendario editoriale pianificato (per Livello 3 - automazione).
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS editorial_calendar (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  character_id    UUID REFERENCES characters(id) ON DELETE CASCADE,
  image_id        UUID REFERENCES images(id) ON DELETE SET NULL,  -- collegata dopo generazione

  scheduled_for   TIMESTAMPTZ NOT NULL,             -- Quando pubblicare
  scene_description TEXT NOT NULL,                  -- Descrizione della scena da generare
  content_pillar  TEXT,                             -- Categoria di contenuto
  caption_hint    TEXT,                             -- Suggerimento per la caption

  status          TEXT DEFAULT 'planned',
  -- 'planned'    → pianificato, da generare
  -- 'generating' → workflow di generazione avviato
  -- 'ready'      → immagine pronta, da approvare
  -- 'approved'   → approvata, pronta per pubblicazione
  -- 'published'  → pubblicata
  -- 'skipped'    → saltato

  created_by      UUID REFERENCES team_members(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ DEFAULT NOW(),

  CONSTRAINT valid_cal_status CHECK (status IN (
    'planned', 'generating', 'ready', 'approved', 'published', 'skipped'
  ))
);

CREATE INDEX IF NOT EXISTS idx_calendar_scheduled ON editorial_calendar(scheduled_for, status);

COMMENT ON TABLE editorial_calendar IS 'Calendario editoriale con scene pianificate per ogni personaggio';


-- ─────────────────────────────────────────────
-- TABELLA: analytics_events
-- Log di eventi per analytics e ottimizzazione prompt.
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS analytics_events (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  image_id        UUID REFERENCES images(id) ON DELETE CASCADE,
  character_id    UUID REFERENCES characters(id) ON DELETE SET NULL,
  member_id       UUID REFERENCES team_members(id) ON DELETE SET NULL,

  event_type      TEXT NOT NULL,
  -- 'generated', 'approved', 'discarded', 'regenerated', 'published', 'quality_fail'

  metadata        JSONB DEFAULT '{}',               -- Dati aggiuntivi evento
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_analytics_character ON analytics_events(character_id, event_type);
CREATE INDEX IF NOT EXISTS idx_analytics_created ON analytics_events(created_at DESC);

COMMENT ON TABLE analytics_events IS 'Log eventi per analytics e ottimizzazione continua dei prompt';


-- ─────────────────────────────────────────────
-- FUNZIONE: aggiorna updated_at automaticamente
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_characters_updated_at
  BEFORE UPDATE ON characters
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_images_updated_at
  BEFORE UPDATE ON images
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();


-- ─────────────────────────────────────────────
-- FUNZIONE: genera short_id unico per le immagini
-- (8 caratteri alfanumerici, usato nel callbackData Telegram)
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION generate_short_id()
RETURNS TEXT AS $$
DECLARE
  chars TEXT := 'abcdefghijklmnopqrstuvwxyz0123456789';
  result TEXT := '';
  i INTEGER;
BEGIN
  FOR i IN 1..8 LOOP
    result := result || substr(chars, floor(random() * length(chars) + 1)::integer, 1);
  END LOOP;
  RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Trigger per auto-generare short_id all'inserimento
CREATE OR REPLACE FUNCTION set_short_id()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.short_id IS NULL OR NEW.short_id = '' THEN
    LOOP
      NEW.short_id := generate_short_id();
      EXIT WHEN NOT EXISTS (SELECT 1 FROM images WHERE short_id = NEW.short_id);
    END LOOP;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_images_short_id
  BEFORE INSERT ON images
  FOR EACH ROW EXECUTE FUNCTION set_short_id();


-- ─────────────────────────────────────────────
-- FUNZIONE: posizione in coda (calcola automaticamente)
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_queue_position()
RETURNS TRIGGER AS $$
BEGIN
  NEW.position := (
    SELECT COALESCE(MAX(position), 0) + 1
    FROM generation_queue
    WHERE status = 'queued'
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_queue_position
  BEFORE INSERT ON generation_queue
  FOR EACH ROW EXECUTE FUNCTION set_queue_position();


-- ─────────────────────────────────────────────
-- FUNZIONE: imposta is_nsfw automaticamente per boudoir
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_nsfw_flag()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.content_pillar = 'boudoir' THEN
    NEW.is_nsfw := true;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_images_set_nsfw
  BEFORE INSERT OR UPDATE ON images
  FOR EACH ROW EXECUTE FUNCTION set_nsfw_flag();


-- ─────────────────────────────────────────────
-- VIEW: pending_approvals
-- Immagini in attesa di approvazione (utile per dashboard)
-- ─────────────────────────────────────────────
CREATE OR REPLACE VIEW pending_approvals AS
SELECT
  i.id,
  i.short_id,
  i.user_request,
  i.image_url,
  i.quality_score,
  i.created_at,
  c.name AS character_name,
  m.name AS requested_by
FROM images i
LEFT JOIN characters c ON i.character_id = c.id
LEFT JOIN team_members m ON i.generated_by = m.id
WHERE i.status = 'pending'
ORDER BY i.created_at ASC;

-- ─────────────────────────────────────────────
-- VIEW: approval_rate_by_character
-- Tasso di approvazione per personaggio (per analytics)
-- ─────────────────────────────────────────────
CREATE OR REPLACE VIEW approval_rate_by_character AS
SELECT
  c.name AS character_name,
  COUNT(*) FILTER (WHERE i.status IN ('approved', 'published')) AS approved,
  COUNT(*) FILTER (WHERE i.status = 'discarded') AS discarded,
  COUNT(*) AS total,
  ROUND(
    100.0 * COUNT(*) FILTER (WHERE i.status IN ('approved', 'published')) / NULLIF(COUNT(*), 0),
    1
  ) AS approval_rate_pct
FROM images i
JOIN characters c ON i.character_id = c.id
WHERE i.status NOT IN ('generating', 'failed')
GROUP BY c.name
ORDER BY approval_rate_pct DESC;


-- ─────────────────────────────────────────────
-- DATI DI ESEMPIO: inserisci un membro admin
-- ─────────────────────────────────────────────
-- ISTRUZIONE: sostituisci il numero con il tuo chat_id Telegram
-- (scrivendo a @userinfobot su Telegram)

INSERT INTO team_members (telegram_chat_id, name, role)
VALUES
  (000000000, 'Admin', 'admin')  -- ← SOSTITUISCI con il tuo chat_id
ON CONFLICT (telegram_chat_id) DO NOTHING;

-- ISTRUZIONE: inserisci i tuoi personaggi
-- INSERT INTO characters (name, trigger_word, lora_model, lora_version, lora_scale, age, hair, eyes, body, ethnicity, style, distinctive, platform)
-- VALUES ('Sofia', 'ohwx', 'tuousername/sofia-lora', 'abc123hash', 0.85, '25 years old', 'light brown wavy hair', 'hazel eyes', 'slim build', 'European', 'casual chic', 'light freckles', 'instagram');
