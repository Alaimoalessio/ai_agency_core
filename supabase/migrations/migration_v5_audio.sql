-- ╔══════════════════════════════════════════════════════════════════╗
-- ║  MIGRATION v5 — ElevenLabs Audio Assets & DB Updates             ║
-- ║                                                                  ║
-- ║  Funzionalità:                                                   ║
-- ║  1. Aggiunge elevenlabs_voice_id alla tabella characters         ║
-- ║  2. Aggiunge audio_url alla tabella images                       ║
-- ║  3. Crea il bucket storage.buckets "audio-assets" public         ║
-- ║                                                                  ║
-- ║  PREREQUISITI: migration_v4_fixes.sql già eseguita               ║
-- ║  ESEGUI: SQL Editor Supabase                                     ║
-- ╚══════════════════════════════════════════════════════════════════╝

-- ═══════════════════════════════════════════════════════════════════
-- 1. AGGIORNAMENTO TABELLA CHARACTERS
-- ═══════════════════════════════════════════════════════════════════
ALTER TABLE characters
  ADD COLUMN IF NOT EXISTS elevenlabs_voice_id TEXT;

COMMENT ON COLUMN characters.elevenlabs_voice_id IS 'ID della voce clonata su ElevenLabs (es. pNInz6obbf5AWi0L)';


-- ═══════════════════════════════════════════════════════════════════
-- 2. AGGIORNAMENTO TABELLA IMAGES
-- ═══════════════════════════════════════════════════════════════════
ALTER TABLE images
  ADD COLUMN IF NOT EXISTS audio_url TEXT;

COMMENT ON COLUMN images.audio_url IS 'URL pubblico (Supabase Storage) del file audio generato (voice note)';


-- ═══════════════════════════════════════════════════════════════════
-- 3. CREAZIONE STORAGE BUCKET "audio-assets"
-- ═══════════════════════════════════════════════════════════════════
-- Verifica e inserisce il nuovo bucket nello storage nativo di Supabase.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
SELECT 'audio-assets', 'audio-assets', true, 104857600, ARRAY['audio/mpeg', 'audio/mp3', 'audio/wav', 'audio/ogg']
WHERE NOT EXISTS (
    SELECT 1 FROM storage.buckets WHERE id = 'audio-assets'
);

-- Imposta le RLS (Row Level Security) Policies sul nuovo bucket
-- a) Consenti accesso in lettura pubblico
CREATE POLICY "Public Access to Audio Assets"
ON storage.objects FOR SELECT
USING ( bucket_id = 'audio-assets' );

-- b) Consenti inserimento oggetti (richiede JWT di servizio per l'inserimento dal backend/n8n)
CREATE POLICY "Service Role Access to Insert Audio"
ON storage.objects FOR INSERT
WITH CHECK ( bucket_id = 'audio-assets' AND auth.role() = 'service_role' );

-- c) Consenti cancellazione e update al service role
CREATE POLICY "Service Role Access to Update/Delete Audio"
ON storage.objects FOR UPDATE
USING ( bucket_id = 'audio-assets' AND auth.role() = 'service_role' )
WITH CHECK ( bucket_id = 'audio-assets' AND auth.role() = 'service_role' );

CREATE POLICY "Service Role Delete Audio"
ON storage.objects FOR DELETE
USING ( bucket_id = 'audio-assets' AND auth.role() = 'service_role' );

-- ═══════════════════════════════════════════════════════════════════
-- VERIFICA FINALE
-- ═══════════════════════════════════════════════════════════════════
SELECT
  'Migration v5 completata' AS status,
  (SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'characters' AND column_name = 'elevenlabs_voice_id') AS characters_voice_col,
  (SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'images' AND column_name = 'audio_url') AS images_audio_col,
  (SELECT COUNT(*) FROM storage.buckets WHERE id = 'audio-assets') AS audio_bucket_created;
