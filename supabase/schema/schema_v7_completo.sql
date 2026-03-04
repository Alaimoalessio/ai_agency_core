-- ╔══════════════════════════════════════════════════════════════════╗
-- ║  AI CHARACTER CONTENT SYSTEM — Schema v7 FIXED                  ║
-- ║  Fix: ordine creazione tabelle corretto (no FK circolari)       ║
-- ╚══════════════════════════════════════════════════════════════════╝

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─────────────────────────────────────────────
-- 1. characters
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS characters (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name            TEXT NOT NULL,
  trigger_word    TEXT NOT NULL DEFAULT 'ohwx',
  lora_model      TEXT NOT NULL,
  lora_version    TEXT NOT NULL,
  lora_scale      NUMERIC(3,2) DEFAULT 0.85,
  age             TEXT,
  hair            TEXT,
  eyes            TEXT,
  body            TEXT,
  ethnicity       TEXT,
  style           TEXT,
  distinctive     TEXT,
  content_pillars JSONB DEFAULT '[]',
  platform                   TEXT DEFAULT 'instagram',
  instagram_account_id       TEXT,
  instagram_access_token_enc BYTEA,
  watermark_text             TEXT,
  watermark_position         TEXT DEFAULT 'bottom-right',
  default_caption_template   TEXT,
  hashtags                   TEXT,
  posting_times              JSONB DEFAULT '[]',
  elevenlabs_voice_id        TEXT,
  quality_threshold          INTEGER DEFAULT 70 CHECK (quality_threshold BETWEEN 50 AND 100),
  is_active   BOOLEAN DEFAULT true,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ─────────────────────────────────────────────
-- 2. team_members
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS team_members (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  telegram_chat_id BIGINT UNIQUE NOT NULL,
  name             TEXT NOT NULL,
  role             TEXT NOT NULL DEFAULT 'creator',
  is_active        BOOLEAN DEFAULT true,
  created_at       TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT valid_role CHECK (role IN ('admin', 'approver', 'creator'))
);

-- ─────────────────────────────────────────────
-- 3. motion_library (prima di images — images la referenzia)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS motion_library (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  character_id     UUID REFERENCES characters(id) ON DELETE CASCADE,
  storage_path     TEXT NOT NULL,
  public_url       TEXT NOT NULL,
  filename         TEXT NOT NULL,
  duration_seconds NUMERIC(5,1),
  motion_type      TEXT NOT NULL,
  aspect_ratio     TEXT DEFAULT '9:16',
  resolution       TEXT DEFAULT '1080x1920',
  description      TEXT,
  mood             TEXT,
  setting          TEXT,
  used_count       INTEGER DEFAULT 0,
  last_used_at     TIMESTAMPTZ,
  is_active        BOOLEAN DEFAULT true,
  created_at       TIMESTAMPTZ DEFAULT NOW(),
  updated_at       TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT valid_motion_type CHECK (motion_type IN (
    'walk','dance','talking','sitting','standing','transition','lifestyle','other'
  ))
);

-- ─────────────────────────────────────────────
-- 4. editorial_calendar (prima di images — images la referenzia)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS editorial_calendar (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  character_id      UUID REFERENCES characters(id) ON DELETE CASCADE,
  image_id          UUID,  -- FK aggiunta dopo con ALTER TABLE
  scheduled_for     TIMESTAMPTZ NOT NULL,
  scene_description TEXT NOT NULL,
  content_pillar    TEXT,
  caption_hint      TEXT,
  auto_publish      BOOLEAN DEFAULT false,
  generate_video    BOOLEAN DEFAULT false,
  generate_audio    BOOLEAN DEFAULT false,
  generate_reel     BOOLEAN DEFAULT false,
  reel_audio_type   TEXT DEFAULT 'trending',
  reel_motion_type  TEXT,
  reel_publish_tiktok  BOOLEAN DEFAULT true,
  reel_publish_reels   BOOLEAN DEFAULT true,
  reel_publish_shorts  BOOLEAN DEFAULT false,
  status TEXT DEFAULT 'planned',
  CONSTRAINT valid_cal_status CHECK (status IN (
    'planned','generating','ready','approved','published','skipped'
  )),
  CONSTRAINT valid_reel_audio_type CHECK (
    reel_audio_type IN ('trending','voiceover','music') OR reel_audio_type IS NULL
  ),
  created_by UUID REFERENCES team_members(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_calendar_scheduled ON editorial_calendar(scheduled_for, status);
CREATE INDEX IF NOT EXISTS idx_calendar_recovery  ON editorial_calendar(scheduled_for, status, character_id) WHERE status = 'planned';

-- ─────────────────────────────────────────────
-- 5. images (referenzia characters, team_members, motion_library, editorial_calendar)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS images (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  short_id          TEXT UNIQUE NOT NULL,
  character_id      UUID REFERENCES characters(id) ON DELETE SET NULL,
  generated_by      UUID REFERENCES team_members(id) ON DELETE SET NULL,
  approved_by       UUID REFERENCES team_members(id) ON DELETE SET NULL,
  calendar_entry_id UUID REFERENCES editorial_calendar(id) ON DELETE SET NULL,
  source_motion_id  UUID REFERENCES motion_library(id) ON DELETE SET NULL,
  user_request      TEXT NOT NULL,
  content_pillar    TEXT,
  prompt            TEXT,
  negative_prompt   TEXT,
  image_url         TEXT,
  stored_url        TEXT,
  watermarked_url   TEXT,
  lora_scale        NUMERIC(3,2),
  original_stored_at     TIMESTAMPTZ,
  watermark_applied      BOOLEAN DEFAULT false,
  watermark_attempted_at TIMESTAMPTZ,
  status TEXT NOT NULL DEFAULT 'generating',
  CONSTRAINT valid_status CHECK (status IN (
    'generating','pending','approved','discarded','published','failed'
  )),
  quality_score   INTEGER,
  quality_issues  TEXT[],
  quality_verdict TEXT,
  published_at       TIMESTAMPTZ,
  instagram_post_id  TEXT,
  scheduled_for      TIMESTAMPTZ,
  is_nsfw BOOLEAN DEFAULT false,
  -- Video I2V (WF5)
  video_url     TEXT,
  video_task_id TEXT,
  video_status  TEXT DEFAULT NULL,
  CONSTRAINT valid_video_status CHECK (video_status IN (
    'pending','generating','completed','failed','skipped'
  ) OR video_status IS NULL),
  -- Audio (SUB6)
  audio_url TEXT,
  -- Reel V2V (WF7)
  reel_url          TEXT,
  reel_task_id      TEXT,
  reel_status       TEXT DEFAULT NULL,
  CONSTRAINT valid_reel_status CHECK (reel_status IN (
    'pending','generating','completed','failed','skipped','published'
  ) OR reel_status IS NULL),
  reel_provider     TEXT,
  reel_prompt       TEXT,
  reel_published_at TIMESTAMPTZ,
  reel_caption      TEXT,
  reel_hashtags     TEXT,
  tiktok_post_id    TEXT,
  youtube_short_id  TEXT,
  generation_time_ms INTEGER,
  attempts           INTEGER DEFAULT 1,
  error_message      TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_images_status          ON images(status);
CREATE INDEX IF NOT EXISTS idx_images_character_id    ON images(character_id);
CREATE INDEX IF NOT EXISTS idx_images_short_id        ON images(short_id);
CREATE INDEX IF NOT EXISTS idx_images_created_at      ON images(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_images_video_task_id   ON images(video_task_id) WHERE video_task_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_images_video_status    ON images(video_status, status) WHERE video_status = 'pending';
CREATE INDEX IF NOT EXISTS idx_images_reel_task_id    ON images(reel_task_id) WHERE reel_task_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_images_reel_status     ON images(reel_status, status) WHERE reel_status = 'pending';
CREATE INDEX IF NOT EXISTS idx_images_watermark_status ON images(watermark_applied, status) WHERE watermark_applied = false AND status = 'published';

-- Ora aggiungi la FK da editorial_calendar verso images (era impossibile prima)
ALTER TABLE editorial_calendar
  ADD CONSTRAINT fk_calendar_image FOREIGN KEY (image_id) REFERENCES images(id) ON DELETE SET NULL;

-- ─────────────────────────────────────────────
-- 6. generation_queue
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS generation_queue (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  image_id     UUID REFERENCES images(id) ON DELETE CASCADE,
  member_id    UUID REFERENCES team_members(id) ON DELETE SET NULL,
  character_id UUID REFERENCES characters(id) ON DELETE SET NULL,
  user_request TEXT NOT NULL,
  position     INTEGER,
  status       TEXT DEFAULT 'queued',
  locked_at    TIMESTAMPTZ,
  locked_by    TEXT,
  lock_expires TIMESTAMPTZ,
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT valid_queue_status CHECK (status IN ('queued','processing','done','failed'))
);

CREATE INDEX IF NOT EXISTS idx_queue_status    ON generation_queue(status, created_at);
CREATE INDEX IF NOT EXISTS idx_queue_available ON generation_queue(created_at, status) WHERE status = 'queued';

-- ─────────────────────────────────────────────
-- 7. engagement_metrics
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS engagement_metrics (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  image_id          UUID REFERENCES images(id) ON DELETE CASCADE,
  character_id      UUID REFERENCES characters(id) ON DELETE SET NULL,
  instagram_post_id TEXT NOT NULL,
  snapshot_at       TIMESTAMPTZ DEFAULT NOW(),
  snapshot_type     TEXT NOT NULL DEFAULT '24h',
  likes             INTEGER DEFAULT 0,
  comments          INTEGER DEFAULT 0,
  saves             INTEGER DEFAULT 0,
  shares            INTEGER DEFAULT 0,
  reach             INTEGER DEFAULT 0,
  impressions       INTEGER DEFAULT 0,
  profile_visits    INTEGER DEFAULT 0,
  engagement_rate   NUMERIC(5,2) GENERATED ALWAYS AS (
    CASE WHEN NULLIF(reach, 0) IS NULL THEN 0
    ELSE ROUND(((likes + comments + saves + shares)::NUMERIC / reach) * 100, 2)
    END
  ) STORED,
  content_pillar TEXT,
  caption_length INTEGER,
  posted_hour    INTEGER,
  posted_dow     INTEGER,
  CONSTRAINT valid_snapshot_type CHECK (snapshot_type IN ('24h','7d','30d'))
);

CREATE INDEX IF NOT EXISTS idx_engagement_character ON engagement_metrics(character_id, snapshot_type, snapshot_at DESC);
CREATE INDEX IF NOT EXISTS idx_engagement_post       ON engagement_metrics(instagram_post_id);

-- ─────────────────────────────────────────────
-- 8. api_prices
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS api_prices (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  service       TEXT NOT NULL,
  operation     TEXT NOT NULL,
  label         TEXT NOT NULL,
  unit_cost_usd NUMERIC(10,6) NOT NULL,
  unit_label    TEXT NOT NULL,
  category      TEXT NOT NULL,
  is_active     BOOLEAN DEFAULT true,
  notes         TEXT,
  updated_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(service, operation)
);

INSERT INTO api_prices (service, operation, label, unit_cost_usd, unit_label, category, notes) VALUES
  ('replicate',  'flux_dev',      'FLUX.1-dev + LoRA',              0.055000, 'per run',       'image', 'FLUX.1-dev con LoRA custom, 1024x1280'),
  ('replicate',  'flux_schnell',  'FLUX.1-schnell',                 0.003000, 'per run',       'image', 'Versione veloce'),
  ('anthropic',  'sonnet_input',  'Claude Sonnet — input',          3.000000, 'per 1M tokens', 'llm',   'Prompt optimization e caption'),
  ('anthropic',  'sonnet_output', 'Claude Sonnet — output',        15.000000, 'per 1M tokens', 'llm',   'Output'),
  ('anthropic',  'opus_input',    'Claude Opus — input',           15.000000, 'per 1M tokens', 'llm',   'Quality check visivo'),
  ('anthropic',  'opus_output',   'Claude Opus — output',          75.000000, 'per 1M tokens', 'llm',   'Output'),
  ('kling',      'i2v_4s',        'Kling v1.5 I2V — 4s',            0.140000, 'per video',     'video', 'Image-to-Video'),
  ('kling',      'v2v_4s',        'Kling v1.6 V2V — 4s',            0.140000, 'per video',     'video', 'Video-to-Video Reel'),
  ('runway',     'gen3_4s',       'Runway Gen-3 I2V — 4s',          0.200000, 'per video',     'video', '$0.05/sec × 4s'),
  ('runway',     'v2v_4s',        'Runway Gen-3 V2V — 4s',          0.200000, 'per video',     'video', 'Video-to-Video Reel'),
  ('elevenlabs', 'tts_char',      'ElevenLabs TTS',                 0.000300, 'per char',      'audio', 'Piano Starter/Creator'),
  ('tiktok',     'publish',       'TikTok API Publish',             0.000000, 'per post',      'infra', 'Gratis'),
  ('n8n',        'cloud_starter', 'n8n Cloud Starter',              0.666667, 'per giorno',    'infra', '€20/mese ÷ 30'),
  ('supabase',   'pro_plan',      'Supabase Pro',                   0.833333, 'per giorno',    'infra', '€25/mese ÷ 30')
ON CONFLICT (service, operation) DO NOTHING;

-- ─────────────────────────────────────────────
-- 9. cost_events
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cost_events (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  image_id       UUID REFERENCES images(id) ON DELETE SET NULL,
  character_id   UUID REFERENCES characters(id) ON DELETE SET NULL,
  service        TEXT NOT NULL,
  operation      TEXT NOT NULL,
  units_consumed NUMERIC(12,4) NOT NULL DEFAULT 1,
  cost_usd       NUMERIC(10,6) NOT NULL,
  cost_eur       NUMERIC(10,6),
  eur_usd_rate   NUMERIC(6,4) DEFAULT 0.93,
  workflow_name  TEXT,
  created_at     TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cost_events_character ON cost_events(character_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cost_events_month     ON cost_events(created_at, service);
CREATE INDEX IF NOT EXISTS idx_cost_events_image     ON cost_events(image_id);

-- ─────────────────────────────────────────────
-- STORAGE BUCKETS
-- ─────────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
SELECT 'images', 'images', true, 52428800, ARRAY['image/jpeg','image/png','image/webp']
WHERE NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'images');

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
SELECT 'watermarked-images', 'watermarked-images', true, 52428800, ARRAY['image/jpeg','image/png']
WHERE NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'watermarked-images');

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
SELECT 'audio-assets', 'audio-assets', true, 104857600, ARRAY['audio/mpeg','audio/mp3','audio/wav','audio/ogg']
WHERE NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'audio-assets');

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
SELECT 'motion-library', 'motion-library', false, 524288000, ARRAY['video/mp4','video/quicktime','video/webm']
WHERE NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'motion-library');

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
SELECT 'reels-output', 'reels-output', true, 524288000, ARRAY['video/mp4','video/quicktime','video/webm']
WHERE NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'reels-output');

-- ─────────────────────────────────────────────
-- FUNZIONI
-- ─────────────────────────────────────────────

-- updated_at
CREATE OR REPLACE FUNCTION update_updated_at() RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_characters_updated_at BEFORE UPDATE ON characters     FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_images_updated_at     BEFORE UPDATE ON images         FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_motion_updated_at     BEFORE UPDATE ON motion_library FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE OR REPLACE FUNCTION update_api_prices_timestamp() RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END; $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_api_prices_updated BEFORE UPDATE ON api_prices FOR EACH ROW EXECUTE FUNCTION update_api_prices_timestamp();

-- short_id
CREATE OR REPLACE FUNCTION generate_short_id() RETURNS TEXT AS $$
DECLARE chars TEXT := 'abcdefghijklmnopqrstuvwxyz0123456789'; result TEXT := ''; i INTEGER;
BEGIN
  FOR i IN 1..8 LOOP result := result || substr(chars, floor(random() * length(chars) + 1)::integer, 1); END LOOP;
  RETURN result;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION set_short_id() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.short_id IS NULL OR NEW.short_id = '' THEN
    LOOP NEW.short_id := generate_short_id(); EXIT WHEN NOT EXISTS (SELECT 1 FROM images WHERE short_id = NEW.short_id); END LOOP;
  END IF;
  RETURN NEW;
END; $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_images_short_id BEFORE INSERT ON images FOR EACH ROW EXECUTE FUNCTION set_short_id();

-- queue position
CREATE OR REPLACE FUNCTION set_queue_position() RETURNS TRIGGER AS $$
BEGIN NEW.position := (SELECT COALESCE(MAX(position), 0) + 1 FROM generation_queue WHERE status = 'queued'); RETURN NEW; END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_queue_position BEFORE INSERT ON generation_queue FOR EACH ROW EXECUTE FUNCTION set_queue_position();

-- NSFW
CREATE OR REPLACE FUNCTION set_nsfw_flag() RETURNS TRIGGER AS $$
BEGIN IF NEW.content_pillar = 'boudoir' THEN NEW.is_nsfw := true; END IF; RETURN NEW; END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_images_set_nsfw BEFORE INSERT OR UPDATE ON images FOR EACH ROW EXECUTE FUNCTION set_nsfw_flag();

-- Token IG cifrato
CREATE OR REPLACE FUNCTION encrypt_ig_token(plain_token TEXT, char_id UUID) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE encryption_key TEXT;
BEGIN
  encryption_key := current_setting('app.ig_token_key', true);
  IF encryption_key IS NULL OR length(encryption_key) < 16 THEN
    RAISE EXCEPTION 'app.ig_token_key non configurata. Esegui: ALTER DATABASE postgres SET app.ig_token_key = ''chiave-32-char'';';
  END IF;
  UPDATE characters SET instagram_access_token_enc = pgp_sym_encrypt(plain_token, encryption_key) WHERE id = char_id;
END; $$;

CREATE OR REPLACE FUNCTION decrypt_ig_token(char_id UUID) RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE encryption_key TEXT; encrypted_val BYTEA;
BEGIN
  encryption_key := current_setting('app.ig_token_key', true);
  SELECT instagram_access_token_enc INTO encrypted_val FROM characters WHERE id = char_id;
  IF encrypted_val IS NULL THEN RETURN NULL; END IF;
  RETURN pgp_sym_decrypt(encrypted_val, encryption_key);
END; $$;

-- Video throttle
CREATE OR REPLACE FUNCTION check_and_claim_video_slot(p_image_id UUID, p_character_id UUID, p_max_concurrent INTEGER DEFAULT 1)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE v INTEGER;
BEGIN
  SELECT COUNT(*) INTO v FROM images WHERE character_id = p_character_id AND video_status = 'generating' FOR UPDATE;
  IF v >= p_max_concurrent THEN RETURN false; END IF;
  UPDATE images SET video_status = 'generating', updated_at = NOW() WHERE id = p_image_id;
  RETURN true;
END; $$;

CREATE OR REPLACE FUNCTION set_video_pending_on_approval() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_gen BOOLEAN;
BEGIN
  IF NEW.status = 'approved' AND OLD.status != 'approved' AND NEW.calendar_entry_id IS NOT NULL THEN
    SELECT generate_video INTO v_gen FROM editorial_calendar WHERE id = NEW.calendar_entry_id;
    IF v_gen = true THEN NEW.video_status := 'pending'; END IF;
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_set_video_pending ON images;
CREATE TRIGGER trg_set_video_pending BEFORE UPDATE ON images FOR EACH ROW EXECUTE FUNCTION set_video_pending_on_approval();

-- Reel throttle
CREATE OR REPLACE FUNCTION check_and_claim_reel_slot(p_image_id UUID, p_character_id UUID, p_max_concurrent INTEGER DEFAULT 1)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE v INTEGER;
BEGIN
  SELECT COUNT(*) INTO v FROM images WHERE character_id = p_character_id AND reel_status = 'generating' FOR UPDATE;
  IF v >= p_max_concurrent THEN RETURN false; END IF;
  UPDATE images SET reel_status = 'generating', updated_at = NOW() WHERE id = p_image_id;
  RETURN true;
END; $$;

CREATE OR REPLACE FUNCTION set_reel_pending_on_approval() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_gen BOOLEAN;
BEGIN
  IF NEW.status = 'approved' AND OLD.status != 'approved' AND NEW.calendar_entry_id IS NOT NULL THEN
    SELECT generate_reel INTO v_gen FROM editorial_calendar WHERE id = NEW.calendar_entry_id;
    IF v_gen = true THEN NEW.reel_status := 'pending'; END IF;
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_set_reel_pending ON images;
CREATE TRIGGER trg_set_reel_pending BEFORE UPDATE ON images FOR EACH ROW EXECUTE FUNCTION set_reel_pending_on_approval();

-- pick_motion_clip
CREATE OR REPLACE FUNCTION pick_motion_clip(p_character_id UUID, p_motion_type TEXT DEFAULT NULL)
RETURNS TABLE (motion_id UUID, public_url TEXT, storage_path TEXT, motion_type TEXT, description TEXT, mood TEXT, duration_seconds NUMERIC)
LANGUAGE plpgsql AS $$
DECLARE v_picked_id UUID;
BEGIN
  SELECT ml.id INTO v_picked_id FROM motion_library ml
  WHERE ml.character_id = p_character_id AND ml.is_active = true
    AND (p_motion_type IS NULL OR ml.motion_type = p_motion_type)
  ORDER BY ml.used_count ASC, ml.last_used_at ASC NULLS FIRST LIMIT 1;
  UPDATE motion_library SET used_count = used_count + 1, last_used_at = NOW() WHERE id = v_picked_id;
  RETURN QUERY SELECT ml.id, ml.public_url, ml.storage_path, ml.motion_type, ml.description, ml.mood, ml.duration_seconds
    FROM motion_library ml WHERE ml.id = v_picked_id;
END; $$;

-- log_cost_event
CREATE OR REPLACE FUNCTION log_cost_event(p_image_id UUID, p_character_id UUID, p_service TEXT, p_operation TEXT, p_units NUMERIC, p_workflow TEXT DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_unit_cost NUMERIC(10,6); v_cost_usd NUMERIC(10,6); v_new_id UUID;
BEGIN
  SELECT unit_cost_usd INTO v_unit_cost FROM api_prices WHERE service = p_service AND operation = p_operation AND is_active = true;
  IF v_unit_cost IS NULL THEN RAISE WARNING 'Prezzo non trovato per %/%', p_service, p_operation; RETURN NULL; END IF;
  v_cost_usd := p_units * v_unit_cost;
  INSERT INTO cost_events (image_id, character_id, service, operation, units_consumed, cost_usd, cost_eur, workflow_name)
  VALUES (p_image_id, p_character_id, p_service, p_operation, p_units, v_cost_usd, v_cost_usd * 0.93, p_workflow)
  RETURNING id INTO v_new_id;
  RETURN v_new_id;
END; $$;

-- claim_next_queue_item
CREATE OR REPLACE FUNCTION claim_next_queue_item(worker_id TEXT)
RETURNS TABLE (queue_id UUID, image_id UUID, character_id UUID, user_request TEXT, member_id UUID)
LANGUAGE plpgsql AS $$
DECLARE claimed_id UUID;
BEGIN
  SELECT id INTO claimed_id FROM generation_queue
  WHERE status = 'queued' AND (lock_expires IS NULL OR lock_expires < NOW())
  ORDER BY created_at ASC LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF claimed_id IS NULL THEN RETURN; END IF;
  UPDATE generation_queue SET status = 'processing', locked_at = NOW(), locked_by = worker_id, lock_expires = NOW() + INTERVAL '10 minutes' WHERE id = claimed_id;
  RETURN QUERY SELECT q.id, q.image_id, q.character_id, q.user_request, q.member_id FROM generation_queue q WHERE q.id = claimed_id;
END; $$;

-- check_posting_gap
CREATE OR REPLACE FUNCTION check_posting_gap() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE conflict_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO conflict_count FROM editorial_calendar
  WHERE character_id = NEW.character_id AND id != COALESCE(NEW.id, uuid_generate_v4())
    AND status NOT IN ('skipped','published')
    AND ABS(EXTRACT(EPOCH FROM (scheduled_for - NEW.scheduled_for)) / 3600) < 3;
  IF conflict_count > 0 THEN RAISE EXCEPTION 'Gap troppo breve: post già schedulato entro 3h per questo personaggio.'; END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_posting_gap ON editorial_calendar;
CREATE TRIGGER trg_posting_gap BEFORE INSERT OR UPDATE ON editorial_calendar FOR EACH ROW EXECUTE FUNCTION check_posting_gap();

-- ─────────────────────────────────────────────
-- VIEWS
-- ─────────────────────────────────────────────

CREATE OR REPLACE VIEW calendar_today AS
SELECT ec.id AS calendar_id, ec.scene_description, ec.content_pillar, ec.caption_hint, ec.scheduled_for, ec.auto_publish,
  ec.generate_video, ec.generate_audio, ec.generate_reel, ec.reel_audio_type, ec.reel_motion_type,
  'SCHEDULED'::TEXT AS trigger_reason,
  c.id AS character_id, c.name AS character_name, c.trigger_word, c.lora_version, c.lora_scale,
  c.watermark_text, c.instagram_account_id, c.default_caption_template, c.hashtags, c.quality_threshold
FROM editorial_calendar ec JOIN characters c ON ec.character_id = c.id
WHERE ec.status = 'planned' AND ec.scheduled_for <= NOW() + INTERVAL '1 hour' AND ec.scheduled_for >= NOW() - INTERVAL '2 hours'
ORDER BY ec.scheduled_for ASC;

CREATE OR REPLACE VIEW calendar_recovery AS
SELECT ec.id AS calendar_id, ec.scene_description, ec.content_pillar, ec.scheduled_for,
  'RECOVERY'::TEXT AS trigger_reason, NOW() - ec.scheduled_for AS overdue_by,
  c.id AS character_id, c.name AS character_name, c.trigger_word, c.lora_version, c.lora_scale,
  c.watermark_text, c.instagram_account_id, c.default_caption_template, c.hashtags, c.quality_threshold
FROM editorial_calendar ec JOIN characters c ON ec.character_id = c.id
WHERE ec.status = 'planned' AND ec.scheduled_for < NOW() - INTERVAL '2 hours' AND ec.scheduled_for > NOW() - INTERVAL '24 hours'
ORDER BY ec.scheduled_for ASC;

CREATE OR REPLACE VIEW pending_approvals AS
SELECT i.id, i.short_id, i.user_request, i.image_url, i.quality_score, i.created_at,
  c.name AS character_name, m.name AS requested_by
FROM images i LEFT JOIN characters c ON i.character_id = c.id LEFT JOIN team_members m ON i.generated_by = m.id
WHERE i.status = 'pending' ORDER BY i.created_at ASC;

CREATE OR REPLACE VIEW alert_published_no_watermark AS
SELECT i.id, i.short_id, i.image_url, i.watermarked_url, i.instagram_post_id, i.published_at, c.name AS character_name, c.watermark_text
FROM images i JOIN characters c ON i.character_id = c.id
WHERE i.status = 'published' AND i.watermark_applied = false AND c.watermark_text IS NOT NULL
ORDER BY i.published_at DESC;

CREATE OR REPLACE VIEW alert_expiring_urls AS
SELECT id, short_id, image_url, stored_url, status, created_at, NOW() - created_at AS age
FROM images WHERE stored_url IS NULL AND image_url IS NOT NULL AND status NOT IN ('failed','discarded') AND created_at < NOW() - INTERVAL '45 minutes'
ORDER BY created_at ASC;

CREATE OR REPLACE VIEW analytics_best_slots AS
SELECT c.name AS character_name, em.content_pillar, em.posted_hour, em.posted_dow, COUNT(*) AS sample_size,
  ROUND(AVG(em.engagement_rate), 2) AS avg_engagement_rate,
  ROUND(AVG(em.likes)::NUMERIC, 0) AS avg_likes, ROUND(AVG(em.saves)::NUMERIC, 0) AS avg_saves,
  ROUND(AVG(em.reach)::NUMERIC, 0) AS avg_reach,
  CASE em.posted_dow WHEN 0 THEN 'Dom' WHEN 1 THEN 'Lun' WHEN 2 THEN 'Mar' WHEN 3 THEN 'Mer' WHEN 4 THEN 'Gio' WHEN 5 THEN 'Ven' WHEN 6 THEN 'Sab' END AS day_name
FROM engagement_metrics em JOIN characters c ON em.character_id = c.id
WHERE em.snapshot_type = '24h'
GROUP BY c.name, em.content_pillar, em.posted_hour, em.posted_dow HAVING COUNT(*) > 3
ORDER BY avg_engagement_rate DESC;

CREATE OR REPLACE VIEW video_throttle_status AS
SELECT c.id AS character_id, c.name AS character_name,
  COUNT(*) FILTER (WHERE i.video_status = 'generating') AS generating,
  COUNT(*) FILTER (WHERE i.video_status = 'pending')    AS pending,
  COUNT(*) FILTER (WHERE i.video_status = 'completed')  AS completed,
  COUNT(*) FILTER (WHERE i.video_status = 'failed')     AS failed,
  GREATEST(0, 1 - COUNT(*) FILTER (WHERE i.video_status = 'generating')) AS slots_available
FROM characters c LEFT JOIN images i ON i.character_id = c.id AND i.created_at > NOW() - INTERVAL '24 hours'
GROUP BY c.id, c.name ORDER BY pending DESC;

CREATE OR REPLACE VIEW reel_throttle_status AS
SELECT c.id AS character_id, c.name AS character_name,
  COUNT(*) FILTER (WHERE i.reel_status = 'generating') AS generating,
  COUNT(*) FILTER (WHERE i.reel_status = 'pending')    AS pending,
  COUNT(*) FILTER (WHERE i.reel_status = 'completed')  AS completed,
  COUNT(*) FILTER (WHERE i.reel_status = 'failed')     AS failed,
  GREATEST(0, 1 - COUNT(*) FILTER (WHERE i.reel_status = 'generating')) AS slots_available
FROM characters c LEFT JOIN images i ON i.character_id = c.id AND i.created_at > NOW() - INTERVAL '24 hours'
GROUP BY c.id, c.name ORDER BY pending DESC;

CREATE OR REPLACE VIEW reel_generation_queue AS
SELECT i.id AS image_id, i.short_id, i.watermarked_url, i.stored_url, i.image_url,
  i.user_request, i.content_pillar, i.reel_status, i.calendar_entry_id,
  c.id AS character_id, c.name AS character_name, c.instagram_account_id,
  ec.generate_reel, ec.reel_audio_type, ec.reel_motion_type,
  ec.reel_publish_tiktok, ec.reel_publish_reels, ec.reel_publish_shorts, ec.scene_description
FROM images i JOIN characters c ON i.character_id = c.id LEFT JOIN editorial_calendar ec ON i.calendar_entry_id = ec.id
WHERE i.status = 'approved' AND i.reel_status = 'pending' ORDER BY i.created_at ASC;

CREATE OR REPLACE VIEW video_generation_queue AS
SELECT i.id AS image_id, i.short_id, i.watermarked_url, i.stored_url, i.image_url,
  i.user_request, i.content_pillar, i.video_status, i.calendar_entry_id,
  c.id AS character_id, c.name AS character_name, c.instagram_account_id,
  ec.generate_video, ec.generate_audio, ec.scene_description
FROM images i JOIN characters c ON i.character_id = c.id LEFT JOIN editorial_calendar ec ON i.calendar_entry_id = ec.id
WHERE i.status = 'approved' AND i.video_status = 'pending' ORDER BY i.created_at ASC;

CREATE OR REPLACE VIEW pending_video_recovery AS
SELECT i.id AS image_id, i.character_id, i.video_status, i.watermarked_url, i.user_request, i.created_at,
  NOW() - i.updated_at AS pending_for, c.name AS character_name,
  (SELECT COUNT(*) FROM images i2 WHERE i2.character_id = i.character_id AND i2.video_status = 'generating') AS currently_generating
FROM images i JOIN characters c ON i.character_id = c.id
WHERE i.video_status = 'pending' AND i.updated_at < NOW() - INTERVAL '30 minutes' ORDER BY i.updated_at ASC;

CREATE OR REPLACE VIEW pending_reel_recovery AS
SELECT i.id AS image_id, i.character_id, i.reel_status, i.watermarked_url, i.user_request, i.created_at,
  NOW() - i.updated_at AS pending_for, c.name AS character_name,
  (SELECT COUNT(*) FROM images i2 WHERE i2.character_id = i.character_id AND i2.reel_status = 'generating') AS currently_generating
FROM images i JOIN characters c ON i.character_id = c.id
WHERE i.reel_status = 'pending' AND i.updated_at < NOW() - INTERVAL '30 minutes' ORDER BY i.updated_at ASC;

CREATE OR REPLACE VIEW cost_summary_monthly AS
SELECT date_trunc('month', created_at) AS month, to_char(date_trunc('month', created_at), 'Mon YYYY') AS month_label,
  ap.category, ce.service, COUNT(*) AS event_count,
  ROUND(SUM(ce.cost_usd)::NUMERIC, 4) AS total_usd, ROUND(SUM(ce.cost_eur)::NUMERIC, 4) AS total_eur
FROM cost_events ce JOIN api_prices ap ON ce.service = ap.service AND ce.operation = ap.operation
GROUP BY date_trunc('month', created_at), ap.category, ce.service ORDER BY month DESC, total_usd DESC;

CREATE OR REPLACE VIEW cost_by_character AS
SELECT c.name AS character_name, date_trunc('month', ce.created_at) AS month,
  COUNT(DISTINCT ce.image_id) AS images_generated,
  ROUND(SUM(ce.cost_usd)::NUMERIC, 4) AS total_usd, ROUND(SUM(ce.cost_eur)::NUMERIC, 4) AS total_eur
FROM cost_events ce JOIN characters c ON ce.character_id = c.id
GROUP BY c.name, date_trunc('month', ce.created_at) ORDER BY month DESC, total_usd DESC;

CREATE OR REPLACE VIEW cost_current_month AS
SELECT
  COALESCE(SUM(cost_eur) FILTER (WHERE ap.category = 'image'), 0)::NUMERIC(8,2) AS images_eur,
  COALESCE(SUM(cost_eur) FILTER (WHERE ap.category = 'video'), 0)::NUMERIC(8,2) AS video_eur,
  COALESCE(SUM(cost_eur) FILTER (WHERE ap.category = 'audio'), 0)::NUMERIC(8,2) AS audio_eur,
  COALESCE(SUM(cost_eur) FILTER (WHERE ap.category = 'llm'),   0)::NUMERIC(8,2) AS llm_eur,
  COALESCE(SUM(cost_eur), 0)::NUMERIC(8,2) AS total_variable_eur,
  47.00::NUMERIC(8,2) AS fixed_infra_eur,
  (COALESCE(SUM(cost_eur), 0) + 47)::NUMERIC(8,2) AS total_eur,
  COUNT(DISTINCT image_id) AS images_this_month
FROM cost_events ce JOIN api_prices ap ON ce.service = ap.service AND ce.operation = ap.operation
WHERE date_trunc('month', ce.created_at) = date_trunc('month', NOW());

CREATE OR REPLACE VIEW dashboard_reel_stats AS
SELECT c.name AS character_name,
  COUNT(*) FILTER (WHERE i.reel_status = 'completed') AS reels_completed,
  COUNT(*) FILTER (WHERE i.reel_status = 'published') AS reels_published,
  COUNT(*) FILTER (WHERE i.reel_status = 'failed')    AS reels_failed,
  COUNT(*) FILTER (WHERE i.reel_status = 'pending')   AS reels_pending,
  COUNT(*) FILTER (WHERE i.reel_provider = 'kling')   AS via_kling,
  COUNT(*) FILTER (WHERE i.reel_provider = 'runway')  AS via_runway
FROM characters c LEFT JOIN images i ON i.character_id = c.id
GROUP BY c.id, c.name ORDER BY reels_published DESC;

CREATE OR REPLACE VIEW characters_safe AS
SELECT id, name, trigger_word, lora_model, lora_version, lora_scale,
  age, hair, eyes, body, ethnicity, style, distinctive,
  content_pillars, platform, is_active, instagram_account_id,
  watermark_text, watermark_position, default_caption_template,
  hashtags, posting_times, quality_threshold, elevenlabs_voice_id,
  created_at, updated_at
FROM characters;

-- ─────────────────────────────────────────────
-- RLS
-- ─────────────────────────────────────────────
ALTER TABLE characters ENABLE ROW LEVEL SECURITY;
CREATE POLICY "characters_read" ON characters FOR SELECT USING (true);

-- ─────────────────────────────────────────────
-- TRACCIAMENTO MIGRATION
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS schema_migrations (
  version    TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ DEFAULT NOW()
);
INSERT INTO schema_migrations (version) VALUES
  ('v1_base'), ('v4_security'), ('v5_audio'), ('v5b_video'), ('v5c_throttling'), ('v6_cost_tracking'), ('v7_reel_pipeline')
ON CONFLICT DO NOTHING;

-- ─────────────────────────────────────────────
-- DATO INIZIALE
-- ─────────────────────────────────────────────
INSERT INTO team_members (telegram_chat_id, name, role)
VALUES (000000000, 'Admin', 'admin')
ON CONFLICT (telegram_chat_id) DO NOTHING;

-- ─────────────────────────────────────────────
-- VERIFICA
-- ─────────────────────────────────────────────
SELECT
  'Schema v7 installato ✅' AS status,
  (SELECT COUNT(*) FROM information_schema.tables  WHERE table_schema = 'public' AND table_type = 'BASE TABLE') AS tabelle,
  (SELECT COUNT(*) FROM information_schema.views   WHERE table_schema = 'public') AS views,
  (SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema = 'public') AS funzioni,
  (SELECT COUNT(*) FROM storage.buckets) AS bucket_storage,
  (SELECT COUNT(*) FROM api_prices) AS prezzi_caricati,
  (SELECT COUNT(*) FROM schema_migrations) AS migrations_tracciate;
