"""
comfy_bridge.py v2 — Bridge FastAPI tra n8n e ComfyUI locale

FIX rispetto alla v1:
1. Polling sincrono → WebSocket push (ComfyUI /ws API nativa)
2. Supabase sincrono in async → asyncio.to_thread()
3. Autenticazione con API key obbligatoria su ogni request
4. Endpoint rinominato da /generate-uncensored a /generate
5. Workflow caricato da file JSON esterno (non hardcoded)
6. LoRA e checkpoint configurabili per request (per personaggio)
7. Bind su 127.0.0.1, non 0.0.0.0

SETUP:
  pip install fastapi uvicorn httpx supabase websockets python-dotenv
  
  Crea un file .env nella stessa cartella:
    SUPABASE_URL=https://xxx.supabase.co
    SUPABASE_KEY=your-service-role-key
    BRIDGE_API_KEY=una-chiave-random-lunga-almeno-32-char
    COMFY_API_URL=http://127.0.0.1:8188
    COMFY_WORKFLOW_PATH=./comfy_workflow.json

  Avvia:
    python comfy_bridge.py
    
  Chiama da n8n:
    POST http://localhost:8000/generate
    Header: X-API-Key: [BRIDGE_API_KEY]
    Body: { "prompt": "...", "negative_prompt": "...", "image_id": "uuid",
            "lora_name": "MyLoRA.safetensors", "lora_scale": 0.85,
            "checkpoint": "PonyDiffusionV6.safetensors" }
"""

import asyncio
import json
import os
import random
import uuid
import logging
from pathlib import Path
from typing import Dict, Any, Optional

import httpx
import websockets
from fastapi import FastAPI, HTTPException, Security, Depends
from fastapi.security import APIKeyHeader
from pydantic import BaseModel, Field
from dotenv import load_dotenv

load_dotenv()

# ─────────────────────────────────────────────────────────────────
# CONFIGURAZIONE
# ─────────────────────────────────────────────────────────────────
COMFY_API_URL       = os.environ.get("COMFY_API_URL", "http://127.0.0.1:8188")
COMFY_WS_URL        = COMFY_API_URL.replace("http://", "ws://").replace("https://", "wss://")
COMFY_WORKFLOW_PATH = os.environ.get("COMFY_WORKFLOW_PATH", "./comfy_workflow.json")
SUPABASE_URL        = os.environ.get("SUPABASE_URL", "")
SUPABASE_KEY        = os.environ.get("SUPABASE_KEY", "")
SUPABASE_BUCKET     = "images"
BRIDGE_API_KEY      = os.environ.get("BRIDGE_API_KEY", "")
MAX_WAIT_SECONDS    = 180  # timeout massimo per una generazione

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("comfy_bridge")

if not BRIDGE_API_KEY or len(BRIDGE_API_KEY) < 16:
    logger.warning("⚠️  BRIDGE_API_KEY non configurata o troppo corta — il bridge NON è sicuro")

# ─────────────────────────────────────────────────────────────────
# AUTENTICAZIONE
# FIX: ogni request richiede X-API-Key header
# ─────────────────────────────────────────────────────────────────
api_key_header = APIKeyHeader(name="X-API-Key", auto_error=True)

def verify_api_key(api_key: str = Security(api_key_header)) -> str:
    if not BRIDGE_API_KEY:
        raise HTTPException(status_code=500, detail="BRIDGE_API_KEY non configurata sul server")
    if api_key != BRIDGE_API_KEY:
        raise HTTPException(status_code=401, detail="API key non valida")
    return api_key

# ─────────────────────────────────────────────────────────────────
# MODELLI
# ─────────────────────────────────────────────────────────────────
class GenerateRequest(BaseModel):
    prompt:          str
    negative_prompt: str = "blurry, deformed, ugly, bad anatomy, extra fingers, watermark, text"
    image_id:        str
    lora_name:       Optional[str] = Field(default=None, description="Nome file LoRA in ComfyUI/models/loras/")
    lora_scale:      float         = Field(default=0.85, ge=0.0, le=1.0)
    checkpoint:      Optional[str] = Field(default=None, description="Nome checkpoint in ComfyUI/models/checkpoints/")
    width:           int           = Field(default=1024, ge=512, le=2048)
    height:          int           = Field(default=1280, ge=512, le=2048)
    steps:           int           = Field(default=30, ge=1, le=80)
    cfg_scale:       float         = Field(default=7.0, ge=1.0, le=20.0)

app = FastAPI(
    title="ComfyUI Bridge",
    description="Bridge n8n ↔ ComfyUI locale",
    docs_url="/docs",
)

# ─────────────────────────────────────────────────────────────────
# CARICA WORKFLOW DA FILE ESTERNO
# FIX: non più hardcoded nel codice
# Esporta il tuo workflow da ComfyUI: Settings → Enable Dev Mode → Save (API Format)
# ─────────────────────────────────────────────────────────────────
def load_workflow(request: GenerateRequest) -> Dict[str, Any]:
    workflow_path = Path(COMFY_WORKFLOW_PATH)

    if workflow_path.exists():
        with open(workflow_path) as f:
            workflow = json.load(f)
    else:
        # Fallback: workflow minimo SDXL se il file non esiste
        logger.warning(f"Workflow file non trovato: {COMFY_WORKFLOW_PATH} — uso workflow fallback")
        workflow = _minimal_workflow()

    # Inietta i parametri dinamici cercando i nodi per class_type
    for node_id, node in workflow.items():
        ct = node.get("class_type", "")
        inputs = node.get("inputs", {})

        if ct == "KSampler":
            inputs["seed"]   = random.randint(1, 2**32 - 1)
            inputs["steps"]  = request.steps
            inputs["cfg"]    = request.cfg_scale

        elif ct == "CLIPTextEncode":
            # Distingui positive/negative dal testo attuale
            current = inputs.get("text", "")
            if "ENTER_PROMPT" in current or current == "":
                inputs["text"] = request.prompt
            elif "ENTER_NEGATIVE" in current:
                inputs["text"] = request.negative_prompt

        elif ct == "EmptyLatentImage":
            inputs["width"]  = request.width
            inputs["height"] = request.height

        elif ct == "CheckpointLoaderSimple" and request.checkpoint:
            inputs["ckpt_name"] = request.checkpoint

        elif ct == "LoraLoader" and request.lora_name:
            inputs["lora_name"]    = request.lora_name
            inputs["strength_model"] = request.lora_scale
            inputs["strength_clip"]  = request.lora_scale

    return workflow

def _minimal_workflow() -> Dict[str, Any]:
    """Workflow minimo di fallback — non usare in produzione."""
    return {
        "3": {"class_type": "KSampler", "inputs": {"seed": 0, "steps": 30, "cfg": 7.0, "sampler_name": "euler_ancestral", "scheduler": "karras", "denoise": 1, "model": ["4", 0], "positive": ["6", 0], "negative": ["7", 0], "latent_image": ["5", 0]}},
        "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "v1-5-pruned-emaonly.safetensors"}},
        "5": {"class_type": "EmptyLatentImage", "inputs": {"batch_size": 1, "width": 1024, "height": 1280}},
        "6": {"class_type": "CLIPTextEncode", "inputs": {"text": "ENTER_PROMPT", "clip": ["4", 1]}},
        "7": {"class_type": "CLIPTextEncode", "inputs": {"text": "ENTER_NEGATIVE", "clip": ["4", 1]}},
        "8": {"class_type": "VAEDecode", "inputs": {"samples": ["3", 0], "vae": ["4", 2]}},
        "9": {"class_type": "SaveImage", "inputs": {"filename_prefix": "bridge_output", "images": ["8", 0]}},
    }

# ─────────────────────────────────────────────────────────────────
# WEBSOCKET POLLING
# FIX: sostituisce il blocking for loop con notifica push nativa
# ComfyUI notifica il completamento via WebSocket — zero polling
# ─────────────────────────────────────────────────────────────────
async def generate_via_websocket(workflow: Dict[str, Any]) -> Dict[str, Any]:
    """
    Invia il workflow a ComfyUI e aspetta il completamento via WebSocket.
    Ritorna l'history del prompt completato.
    """
    client_id = uuid.uuid4().hex
    ws_url = f"{COMFY_WS_URL}/ws?clientId={client_id}"

    # Prima accoda il prompt
    async with httpx.AsyncClient() as http:
        try:
            resp = await http.post(
                f"{COMFY_API_URL}/prompt",
                json={"prompt": workflow, "client_id": client_id},
                timeout=10.0
            )
            resp.raise_for_status()
            prompt_id = resp.json()["prompt_id"]
        except httpx.RequestError as e:
            raise HTTPException(status_code=503, detail=f"ComfyUI non raggiungibile: {e}")
        except KeyError:
            raise HTTPException(status_code=500, detail=f"ComfyUI non ha restituito prompt_id: {resp.text}")

    logger.info(f"Prompt accodato: {prompt_id}")

    # Aspetta il completamento via WebSocket
    try:
        async with websockets.connect(ws_url, ping_interval=20, ping_timeout=30) as ws:
            deadline = asyncio.get_event_loop().time() + MAX_WAIT_SECONDS
            while True:
                if asyncio.get_event_loop().time() > deadline:
                    raise HTTPException(status_code=504, detail=f"Timeout dopo {MAX_WAIT_SECONDS}s")

                try:
                    msg_raw = await asyncio.wait_for(ws.recv(), timeout=5.0)
                except asyncio.TimeoutError:
                    continue  # Nessun messaggio entro 5s — riprova

                # I messaggi possono essere bytes (immagini preview) o JSON
                if isinstance(msg_raw, bytes):
                    continue

                try:
                    msg = json.loads(msg_raw)
                except json.JSONDecodeError:
                    continue

                msg_type = msg.get("type", "")

                if msg_type == "executing":
                    data = msg.get("data", {})
                    # None = coda completata
                    if data.get("prompt_id") == prompt_id and data.get("node") is None:
                        logger.info(f"Generazione completata: {prompt_id}")
                        break

                elif msg_type == "execution_error":
                    data = msg.get("data", {})
                    if data.get("prompt_id") == prompt_id:
                        raise HTTPException(
                            status_code=500,
                            detail=f"ComfyUI errore: {data.get('exception_message', 'errore sconosciuto')}"
                        )

    except websockets.exceptions.WebSocketException as e:
        raise HTTPException(status_code=503, detail=f"WebSocket ComfyUI: {e}")

    # Recupera l'history
    async with httpx.AsyncClient() as http:
        history_resp = await http.get(f"{COMFY_API_URL}/history/{prompt_id}", timeout=10.0)
        return history_resp.json().get(prompt_id, {})

# ─────────────────────────────────────────────────────────────────
# UPLOAD SUPABASE (async corretto)
# FIX: asyncio.to_thread() per evitare blocking event loop
# ─────────────────────────────────────────────────────────────────
async def upload_to_supabase(image_bytes: bytes, filename: str) -> str:
    """Upload su Supabase Storage in modo non-bloccante."""
    if not SUPABASE_URL or not SUPABASE_KEY:
        raise HTTPException(status_code=500, detail="SUPABASE_URL o SUPABASE_KEY non configurati")

    def _sync_upload():
        from supabase import create_client
        client = create_client(SUPABASE_URL, SUPABASE_KEY)
        client.storage.from_(SUPABASE_BUCKET).upload(
            path=filename,
            file=image_bytes,
            file_options={"content-type": "image/png", "upsert": "true"}
        )
        return client.storage.from_(SUPABASE_BUCKET).get_public_url(filename)

    # FIX: to_thread() esegue il codice sync in un thread separato
    # senza bloccare l'event loop di FastAPI
    return await asyncio.to_thread(_sync_upload)

# ─────────────────────────────────────────────────────────────────
# ENDPOINT PRINCIPALE
# FIX: rinominato, autenticato, async corretto
# ─────────────────────────────────────────────────────────────────
@app.post("/generate")  # FIX: era /generate-uncensored
async def generate(
    request: GenerateRequest,
    _key: str = Depends(verify_api_key)  # FIX: autenticazione obbligatoria
):
    """
    Genera un'immagine con ComfyUI locale e la carica su Supabase.
    Richiede header: X-API-Key: [BRIDGE_API_KEY]
    """
    logger.info(f"Richiesta generazione: image_id={request.image_id}, lora={request.lora_name}")

    # 1. Prepara workflow con parametri del personaggio
    workflow = load_workflow(request)

    # 2. Genera via WebSocket (non-blocking)
    history = await generate_via_websocket(workflow)

    # 3. Estrai output dal nodo SaveImage (node "9" di default)
    save_node_id = next(
        (nid for nid, n in workflow.items() if n.get("class_type") == "SaveImage"),
        "9"
    )
    try:
        image_data = history["outputs"][save_node_id]["images"][0]
    except KeyError:
        raise HTTPException(status_code=500, detail=f"Output non trovato in history. Keys: {list(history.get('outputs', {}).keys())}")

    # 4. Scarica immagine da ComfyUI
    async with httpx.AsyncClient() as http:
        params = f"filename={image_data['filename']}&subfolder={image_data.get('subfolder','')}&type={image_data['type']}"
        img_resp = await http.get(f"{COMFY_API_URL}/view?{params}", timeout=30.0)
        img_bytes = img_resp.content

    # 5. Upload su Supabase (async corretto)
    storage_filename = f"{request.image_id}_{uuid.uuid4().hex[:8]}.png"
    public_url = await upload_to_supabase(img_bytes, storage_filename)

    logger.info(f"Upload completato: {public_url}")

    return {
        "success":    True,
        "stored_url": public_url,
        "filename":   storage_filename,
        "image_id":   request.image_id,
    }

# ─────────────────────────────────────────────────────────────────
# HEALTH CHECK (utile per monitoraggio n8n)
# ─────────────────────────────────────────────────────────────────
@app.get("/health")
async def health():
    """Verifica che ComfyUI sia raggiungibile."""
    try:
        async with httpx.AsyncClient() as http:
            resp = await http.get(f"{COMFY_API_URL}/system_stats", timeout=3.0)
            comfy_ok = resp.status_code == 200
    except Exception:
        comfy_ok = False

    return {
        "bridge":   "ok",
        "comfyui":  "ok" if comfy_ok else "unreachable",
        "auth":     "configured" if BRIDGE_API_KEY else "MISSING — non sicuro",
        "supabase": "configured" if SUPABASE_URL else "missing",
    }

# ─────────────────────────────────────────────────────────────────
# AVVIO
# FIX: bind su 127.0.0.1 (solo localhost), non 0.0.0.0
# ─────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "comfy_bridge:app",
        host="127.0.0.1",  # FIX: era 0.0.0.0 — esposto su tutte le interfacce
        port=8000,
        reload=False,       # FIX: reload=False in produzione
        log_level="info",
    )
