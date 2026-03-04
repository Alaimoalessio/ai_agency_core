-- ╔══════════════════════════════════════════════════════════════════╗
-- ║  MIGRATION v5c — Video/Audio Throttling Support                 ║
-- ║                                                                  ║
-- ║  Aggiunge:                                                       ║
-- ║  1. View video_throttle_status — stato code per personaggio     ║
-- ║  2. View pending_video_recovery — video bloccati da recuperare  ║
-- ║  3. Funzione check_video_slot() — verifica slot prima di avviare║
-- ║                                                                  ║
-- ║  ESEGUI DOPO: migration_v5b_video_columns.sql                    ║
-- ╚══════════════════════════════════════════════════════════════════╝

-- ─────────────────────────────────────────────
-- 1. Stato code video/audio per personaggio
--    Usata dal dashboard per monitoraggio
-- ─────────────────────────────────────────────
CREATE OR REPLACE VIEW video_throttle_status AS
SELECT
  c.id                                                     AS character_id,
  c.name                                                   AS character_name,
  COUNT(*) FILTER (WHERE i.video_status = 'generating')   AS generating,
  COUNT(*) FILTER (WHERE i.video_status = 'pending')      AS pending,
  COUNT(*) FILTER (WHERE i.video_status = 'completed')    AS completed,
  COUNT(*) FILTER (WHERE i.video_status = 'failed')       AS failed,
  COUNT(*) FILTER (WHERE i.video_status = 'skipped')      AS skipped,
  -- slot disponibili (max 1 per personaggio)
  GREATEST(0, 1 - COUNT(*) FILTER (WHERE i.video_status = 'generating')) AS slots_available
FROM characters c
LEFT JOIN images i ON i.character_id = c.id
  AND i.created_at > NOW() - INTERVAL '24 hours'
GROUP BY c.id, c.name
ORDER BY pending DESC, generating DESC;

COMMENT ON VIEW video_throttle_status IS
  'Stato code video per personaggio. slots_available=0 → throttled. Query da dashboard o n8n recovery.';


-- ─────────────────────────────────────────────
-- 2. Recovery view: video pending da > 30 minuti
--    (rimasti in pending perché throttled)
--    Usata da un cron n8n ogni 30 minuti
-- ─────────────────────────────────────────────
CREATE OR REPLACE VIEW pending_video_recovery AS
SELECT
  i.id              AS image_id,
  i.character_id,
  i.video_status,
  i.watermarked_url,
  i.stored_url,
  i.user_request,
  i.content_pillar,
  i.created_at,
  NOW() - i.updated_at AS pending_for,
  c.name            AS character_name,
  -- Conta video in corso per questo personaggio
  (SELECT COUNT(*) FROM images i2
   WHERE i2.character_id = i.character_id
   AND i2.video_status = 'generating') AS currently_generating
FROM images i
JOIN characters c ON i.character_id = c.id
WHERE
  i.video_status = 'pending'
  AND i.updated_at < NOW() - INTERVAL '30 minutes'  -- rimasto pending > 30 min
ORDER BY i.updated_at ASC;  -- più vecchio prima

COMMENT ON VIEW pending_video_recovery IS
  'Video rimasti pending da > 30 min (throttled o persi). Cron n8n ogni 30min: SELECT * FROM pending_video_recovery WHERE currently_generating = 0;';


-- ─────────────────────────────────────────────
-- 3. Funzione: check_video_slot()
--    Verifica atomicamente se c'è uno slot libero
--    e lo prenota subito (evita race condition tra
--    più workflow che partono contemporaneamente)
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION check_and_claim_video_slot(
  p_image_id     UUID,
  p_character_id UUID,
  p_max_concurrent INTEGER DEFAULT 1
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
  v_currently_generating INTEGER;
BEGIN
  -- Conta in modo atomico (FOR UPDATE blocca righe)
  SELECT COUNT(*) INTO v_currently_generating
  FROM images
  WHERE character_id = p_character_id
    AND video_status = 'generating'
  FOR UPDATE;   -- lock per evitare race condition

  IF v_currently_generating >= p_max_concurrent THEN
    -- Slot pieno: lascia pending
    RETURN false;
  END IF;

  -- Slot disponibile: prenota subito settando generating
  UPDATE images
  SET video_status = 'generating',
      updated_at   = NOW()
  WHERE id = p_image_id;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION check_and_claim_video_slot IS
  'Versione atomica del throttle check. Usa in alternativa al check n8n per evitare race condition con molti personaggi. Esempio: SELECT check_and_claim_video_slot(''img-uuid'', ''char-uuid'', 1);';


-- ─────────────────────────────────────────────
-- 4. Aggiunge updated_at a images (se mancante)
--    Necessario per il calcolo pending_for
-- ─────────────────────────────────────────────
ALTER TABLE images
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- Trigger per aggiornare updated_at automaticamente
CREATE OR REPLACE FUNCTION update_images_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_images_updated_at ON images;
CREATE TRIGGER trg_images_updated_at
  BEFORE UPDATE ON images
  FOR EACH ROW EXECUTE FUNCTION update_images_updated_at();


-- ─────────────────────────────────────────────
-- VERIFICA
-- ─────────────────────────────────────────────
SELECT
  'Migration v5c completata' AS status,
  (SELECT COUNT(*) FROM information_schema.views   WHERE table_name = 'video_throttle_status')   AS view_throttle_status,
  (SELECT COUNT(*) FROM information_schema.views   WHERE table_name = 'pending_video_recovery')  AS view_recovery,
  (SELECT COUNT(*) FROM information_schema.routines WHERE routine_name = 'check_and_claim_video_slot') AS fn_claim_slot,
  (SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'images' AND column_name = 'updated_at') AS col_updated_at;
