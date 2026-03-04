-- ╔══════════════════════════════════════════════════════════════════╗
-- ║  MIGRATION v5b — Video Columns (FIX CRITICO)                    ║
-- ║                                                                  ║
-- ║  PROBLEMA: Workflow 5 filtra su video_status = 'pending'         ║
-- ║  ma questa colonna non esiste nel DB → trigger non parte MAI.   ║
-- ║                                                                  ║
-- ║  ESEGUI DOPO: migration_v5_audio.sql                             ║
-- ╚══════════════════════════════════════════════════════════════════╝

-- ─────────────────────────────────────────────
-- 1. Colonne video sulla tabella images
-- ─────────────────────────────────────────────
ALTER TABLE images
  ADD COLUMN IF NOT EXISTS video_status   TEXT DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS video_url      TEXT,
  ADD COLUMN IF NOT EXISTS video_task_id  TEXT;

-- Constraint valori ammessi
ALTER TABLE images
  DROP CONSTRAINT IF EXISTS valid_video_status;

ALTER TABLE images
  ADD CONSTRAINT valid_video_status
  CHECK (video_status IN ('pending', 'generating', 'completed', 'failed', 'skipped') OR video_status IS NULL);

COMMENT ON COLUMN images.video_status  IS 'NULL = video non richiesto | pending = in attesa | generating = in corso | completed | failed | skipped';
COMMENT ON COLUMN images.video_url     IS 'URL pubblico del video generato (Supabase Storage o URL diretto provider)';
COMMENT ON COLUMN images.video_task_id IS 'Task ID restituito da Runway/Kling — usato per matchare il webhook di callback';

-- Indice per il webhook callback (cerca per task_id)
CREATE INDEX IF NOT EXISTS idx_images_video_task_id
  ON images(video_task_id)
  WHERE video_task_id IS NOT NULL;

-- Indice per il trigger (cerca immagini approved + pending video)
CREATE INDEX IF NOT EXISTS idx_images_video_status
  ON images(video_status, status)
  WHERE video_status = 'pending';


-- ─────────────────────────────────────────────
-- 2. Colonna generate_video sul calendario
--    Controlla se generare video per questa voce
-- ─────────────────────────────────────────────
ALTER TABLE editorial_calendar
  ADD COLUMN IF NOT EXISTS generate_video  BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS generate_audio  BOOLEAN DEFAULT false;

COMMENT ON COLUMN editorial_calendar.generate_video IS 'Se true, il Workflow 5 genera video I2V dopo approvazione';
COMMENT ON COLUMN editorial_calendar.generate_audio IS 'Se true, il Workflow 6 genera voiceover ElevenLabs dopo approvazione';


-- ─────────────────────────────────────────────
-- 3. View: video_generation_queue
--    Immagini approvate che aspettano video
-- ─────────────────────────────────────────────
CREATE OR REPLACE VIEW video_generation_queue AS
SELECT
  i.id              AS image_id,
  i.short_id,
  i.watermarked_url,
  i.stored_url,
  i.image_url,
  i.user_request,
  i.content_pillar,
  i.video_status,
  i.calendar_entry_id,
  c.id              AS character_id,
  c.name            AS character_name,
  c.instagram_account_id,
  ec.generate_video,
  ec.generate_audio,
  ec.scene_description
FROM images i
JOIN characters c ON i.character_id = c.id
LEFT JOIN editorial_calendar ec ON i.calendar_entry_id = ec.id
WHERE
  i.status       = 'approved'
  AND i.video_status = 'pending'
ORDER BY i.created_at ASC;

COMMENT ON VIEW video_generation_queue IS
  'Immagini approved con video_status=pending. Usata dal Workflow 5 come alternativa al trigger Supabase.';


-- ─────────────────────────────────────────────
-- 4. Imposta video_status = 'pending' solo
--    per le immagini che hanno generate_video=true
--    nel calendario — le altre rimangono NULL
-- ─────────────────────────────────────────────
-- Questo UPDATE non tocca le righe esistenti a NULL
-- (quelle non richiedono video — comportamento corretto)

-- Per attivare il video su una voce specifica del calendario:
-- UPDATE editorial_calendar SET generate_video = true WHERE id = 'UUID';
-- Poi quando l'immagine viene approvata, il workflow deve settare video_status='pending'


-- ─────────────────────────────────────────────
-- 5. Funzione trigger: imposta video_status
--    automaticamente all'approvazione se
--    il calendario ha generate_video = true
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_video_pending_on_approval()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_generate_video BOOLEAN;
BEGIN
  -- Controlla solo quando status passa a 'approved'
  IF NEW.status = 'approved' AND OLD.status != 'approved' THEN

    -- Se l'immagine viene dal calendario, controlla il flag
    IF NEW.calendar_entry_id IS NOT NULL THEN
      SELECT generate_video INTO v_generate_video
      FROM editorial_calendar
      WHERE id = NEW.calendar_entry_id;

      IF v_generate_video = true THEN
        NEW.video_status := 'pending';
      END IF;

    -- Se arriva dal bot Telegram (no calendario), usa il default del personaggio
    -- Per ora non attiva automaticamente — richiede impostazione manuale
    END IF;

  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_video_pending ON images;
CREATE TRIGGER trg_set_video_pending
  BEFORE UPDATE ON images
  FOR EACH ROW
  EXECUTE FUNCTION set_video_pending_on_approval();

COMMENT ON FUNCTION set_video_pending_on_approval IS
  'Imposta video_status=pending automaticamente quando un image viene approvata e il calendario ha generate_video=true';


-- ─────────────────────────────────────────────
-- VERIFICA
-- ─────────────────────────────────────────────
SELECT
  'Migration v5b completata' AS status,
  (SELECT COUNT(*) FROM information_schema.columns
   WHERE table_name = 'images' AND column_name = 'video_status')   AS col_video_status,
  (SELECT COUNT(*) FROM information_schema.columns
   WHERE table_name = 'images' AND column_name = 'video_url')      AS col_video_url,
  (SELECT COUNT(*) FROM information_schema.columns
   WHERE table_name = 'images' AND column_name = 'video_task_id')  AS col_video_task_id,
  (SELECT COUNT(*) FROM information_schema.columns
   WHERE table_name = 'editorial_calendar' AND column_name = 'generate_video') AS col_generate_video,
  (SELECT COUNT(*) FROM information_schema.views
   WHERE table_name = 'video_generation_queue')                    AS view_queue;
