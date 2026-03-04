-- ╔══════════════════════════════════════════════════════════════════╗
-- ║  MIGRATION v6 — Cost Tracking & API Price Registry              ║
-- ║                                                                  ║
-- ║  Crea:                                                           ║
-- ║  1. Tabella api_prices  → prezzi aggiornabili senza toccare codice║
-- ║  2. Tabella cost_events → log costo reale per ogni operazione    ║
-- ║  3. View cost_summary   → aggregato mensile per dashboard        ║
-- ║  4. View cost_by_character → breakdown per personaggio           ║
-- ║                                                                  ║
-- ║  AGGIORNARE UN PREZZO:                                           ║
-- ║  UPDATE api_prices SET unit_cost_usd = 0.048                     ║
-- ║  WHERE service = 'replicate' AND operation = 'flux_dev';         ║
-- ╚══════════════════════════════════════════════════════════════════╝


-- ─────────────────────────────────────────────
-- 1. TABELLA: api_prices
-- Fonte unica di verità per tutti i prezzi API
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS api_prices (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  service         TEXT NOT NULL,        -- 'replicate', 'anthropic', 'elevenlabs', 'runway', 'kling'
  operation       TEXT NOT NULL,        -- 'flux_dev', 'claude_sonnet_input', 'claude_opus_vision', ecc.
  label           TEXT NOT NULL,        -- nome leggibile per il dashboard
  unit_cost_usd   NUMERIC(10,6) NOT NULL, -- costo per unità
  unit_label      TEXT NOT NULL,        -- 'per run', 'per 1M tokens', 'per video', 'per 1k chars'
  category        TEXT NOT NULL,        -- 'image', 'video', 'audio', 'llm'
  is_active       BOOLEAN DEFAULT true,
  notes           TEXT,
  updated_at      TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(service, operation)
);

-- Trigger aggiorna updated_at automaticamente
CREATE OR REPLACE FUNCTION update_api_prices_timestamp()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_api_prices_updated ON api_prices;
CREATE TRIGGER trg_api_prices_updated
  BEFORE UPDATE ON api_prices
  FOR EACH ROW EXECUTE FUNCTION update_api_prices_timestamp();

-- ─── PREZZI INIZIALI (aggiornare via UPDATE quando cambiano) ───────
INSERT INTO api_prices (service, operation, label, unit_cost_usd, unit_label, category, notes) VALUES
  -- REPLICATE / FLUX
  ('replicate', 'flux_dev',      'FLUX.1-dev + LoRA (40 steps)',   0.055000, 'per run',       'image', 'Prezzo Replicate FLUX.1-dev con LoRA custom, 1024x1280'),
  ('replicate', 'flux_schnell',  'FLUX.1-schnell (4 steps)',        0.003000, 'per run',       'image', 'Versione veloce, qualità inferiore su LoRA fine-tuned'),

  -- ANTHROPIC (via OpenRouter — prezzi pass-through)
  ('anthropic', 'sonnet_input',  'Claude Sonnet — input tokens',    3.000000, 'per 1M tokens', 'llm',   'claude-sonnet-4-5, usato per prompt optimization e caption'),
  ('anthropic', 'sonnet_output', 'Claude Sonnet — output tokens',   15.00000, 'per 1M tokens', 'llm',   'claude-sonnet-4-5 output'),
  ('anthropic', 'opus_input',    'Claude Opus — input tokens',      15.00000, 'per 1M tokens', 'llm',   'claude-opus-4-6, usato per quality check visivo'),
  ('anthropic', 'opus_output',   'Claude Opus — output tokens',     75.00000, 'per 1M tokens', 'llm',   'claude-opus-4-6 output'),

  -- VIDEO
  ('kling',    'i2v_4s',         'Kling v1.5 I2V — 4 secondi',      0.140000, 'per video',     'video', 'Image-to-Video 4s, qualità alta'),
  ('runway',   'gen3_4s',        'Runway Gen-3 Alpha — 4 secondi',   0.200000, 'per video',     'video', '$0.05/sec × 4s'),

  -- AUDIO
  ('elevenlabs', 'tts_char',     'ElevenLabs TTS — per carattere',  0.000300, 'per char',      'audio', 'Piano Starter/Creator. 30k char/mese inclusi nel piano base'),

  -- INFRASTRUTTURA (costi fissi mensili, espressi come daily per aggregazione)
  ('n8n',       'cloud_starter', 'n8n Cloud Starter',               0.666667, 'per giorno',    'infra', '€20/mese ÷ 30 giorni'),
  ('supabase',  'pro_plan',      'Supabase Pro',                    0.833333, 'per giorno',    'infra', '€25/mese ÷ 30 giorni')

ON CONFLICT (service, operation) DO NOTHING;

COMMENT ON TABLE api_prices IS
  'Prezzi API aggiornabili. Modificare con UPDATE api_prices SET unit_cost_usd=X WHERE service=Y AND operation=Z';


-- ─────────────────────────────────────────────
-- 2. TABELLA: cost_events
-- Log del costo reale di ogni operazione eseguita.
-- Popolata dai workflow n8n dopo ogni chiamata API.
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cost_events (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  image_id        UUID REFERENCES images(id) ON DELETE SET NULL,
  character_id    UUID REFERENCES characters(id) ON DELETE SET NULL,
  service         TEXT NOT NULL,
  operation       TEXT NOT NULL,
  units_consumed  NUMERIC(12,4) NOT NULL DEFAULT 1,  -- es: 1 run, 1500 tokens, 200 chars
  cost_usd        NUMERIC(10,6) NOT NULL,             -- costo effettivo (units × unit_price al momento)
  cost_eur        NUMERIC(10,6),                      -- calcolato al momento con tasso corrente
  eur_usd_rate    NUMERIC(6,4) DEFAULT 0.93,
  workflow_name   TEXT,                               -- 'scheduler', 'telegram_bot', 'video_pipeline'
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cost_events_character ON cost_events(character_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cost_events_month     ON cost_events(date_trunc('month', created_at), service);
CREATE INDEX IF NOT EXISTS idx_cost_events_image     ON cost_events(image_id);

COMMENT ON TABLE cost_events IS
  'Log costi reali. Ogni workflow n8n dovrebbe inserire una riga dopo ogni chiamata API costosa.';


-- ─────────────────────────────────────────────
-- 3. FUNZIONE: log_cost_event()
-- Helper chiamato dai workflow per loggare i costi
-- senza dover conoscere il prezzo unitario corrente.
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION log_cost_event(
  p_image_id      UUID,
  p_character_id  UUID,
  p_service       TEXT,
  p_operation     TEXT,
  p_units         NUMERIC,
  p_workflow      TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_unit_cost NUMERIC(10,6);
  v_cost_usd  NUMERIC(10,6);
  v_new_id    UUID;
BEGIN
  -- Recupera il prezzo unitario corrente dalla tabella
  SELECT unit_cost_usd INTO v_unit_cost
  FROM api_prices
  WHERE service = p_service AND operation = p_operation AND is_active = true;

  IF v_unit_cost IS NULL THEN
    RAISE WARNING 'Prezzo non trovato per %/% — evento non loggato', p_service, p_operation;
    RETURN NULL;
  END IF;

  v_cost_usd := p_units * v_unit_cost;

  INSERT INTO cost_events (image_id, character_id, service, operation, units_consumed, cost_usd, cost_eur, workflow_name)
  VALUES (p_image_id, p_character_id, p_service, p_operation, p_units, v_cost_usd, v_cost_usd * 0.93, p_workflow)
  RETURNING id INTO v_new_id;

  RETURN v_new_id;
END;
$$;

COMMENT ON FUNCTION log_cost_event IS
  'Usa: SELECT log_cost_event(image_id, char_id, ''replicate'', ''flux_dev'', 1, ''scheduler'')';


-- ─────────────────────────────────────────────
-- 4. VIEW: cost_summary_monthly
-- Aggregato mensile per il dashboard
-- ─────────────────────────────────────────────
CREATE OR REPLACE VIEW cost_summary_monthly AS
SELECT
  date_trunc('month', created_at)                     AS month,
  to_char(date_trunc('month', created_at), 'Mon YYYY') AS month_label,
  category,
  service,
  COUNT(*)                                             AS event_count,
  SUM(units_consumed)                                  AS total_units,
  ROUND(SUM(cost_usd)::NUMERIC, 4)                     AS total_usd,
  ROUND(SUM(cost_eur)::NUMERIC, 4)                     AS total_eur
FROM cost_events ce
JOIN api_prices ap ON ce.service = ap.service AND ce.operation = ap.operation
GROUP BY date_trunc('month', created_at), category, service
ORDER BY month DESC, total_usd DESC;

COMMENT ON VIEW cost_summary_monthly IS 'Aggregato costi per mese, categoria e servizio. Fonte principale del dashboard.';


-- ─────────────────────────────────────────────
-- 5. VIEW: cost_by_character
-- Quanto costa ogni personaggio al mese
-- ─────────────────────────────────────────────
CREATE OR REPLACE VIEW cost_by_character AS
SELECT
  c.name                                                AS character_name,
  date_trunc('month', ce.created_at)                    AS month,
  COUNT(DISTINCT ce.image_id)                           AS images_generated,
  ROUND(SUM(ce.cost_usd)::NUMERIC, 4)                   AS total_usd,
  ROUND(SUM(ce.cost_eur)::NUMERIC, 4)                   AS total_eur,
  ROUND((SUM(ce.cost_usd) / NULLIF(COUNT(DISTINCT ce.image_id), 0))::NUMERIC, 4) AS cost_per_image_usd
FROM cost_events ce
JOIN characters c ON ce.character_id = c.id
GROUP BY c.name, date_trunc('month', ce.created_at)
ORDER BY month DESC, total_usd DESC;


-- ─────────────────────────────────────────────
-- 6. VIEW: cost_current_month (per dashboard live)
-- ─────────────────────────────────────────────
CREATE OR REPLACE VIEW cost_current_month AS
SELECT
  COALESCE(SUM(cost_eur) FILTER (WHERE ap.category = 'image'), 0)::NUMERIC(8,2)  AS images_eur,
  COALESCE(SUM(cost_eur) FILTER (WHERE ap.category = 'video'), 0)::NUMERIC(8,2)  AS video_eur,
  COALESCE(SUM(cost_eur) FILTER (WHERE ap.category = 'audio'), 0)::NUMERIC(8,2)  AS audio_eur,
  COALESCE(SUM(cost_eur) FILTER (WHERE ap.category = 'llm'),   0)::NUMERIC(8,2)  AS llm_eur,
  COALESCE(SUM(cost_eur), 0)::NUMERIC(8,2)                                        AS total_variable_eur,
  -- Aggiungi i costi fissi stimati (infrastruttura)
  47.00::NUMERIC(8,2)                                                              AS fixed_infra_eur,
  (COALESCE(SUM(cost_eur), 0) + 47)::NUMERIC(8,2)                                AS total_eur,
  COUNT(DISTINCT image_id)                                                         AS images_this_month,
  COUNT(DISTINCT ce.id) FILTER (WHERE ap.category = 'video')                      AS videos_this_month,
  COUNT(DISTINCT ce.id) FILTER (WHERE ap.category = 'audio')                      AS audio_this_month
FROM cost_events ce
JOIN api_prices ap ON ce.service = ap.service AND ce.operation = ap.operation
WHERE date_trunc('month', ce.created_at) = date_trunc('month', NOW());

COMMENT ON VIEW cost_current_month IS
  'Snapshot costi mese corrente. Chiamata dal dashboard ogni refresh.';


-- ─────────────────────────────────────────────
-- VERIFICA
-- ─────────────────────────────────────────────
SELECT
  'Migration v6 completata' AS status,
  (SELECT COUNT(*) FROM api_prices)            AS prezzi_caricati,
  (SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'cost_events') AS cost_events_table,
  (SELECT COUNT(*) FROM information_schema.views WHERE table_name IN ('cost_summary_monthly','cost_by_character','cost_current_month')) AS views_create;
