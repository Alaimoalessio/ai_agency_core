import { useState } from "react";

const COLORS = {
  red: "#ef4444", orange: "#f97316", yellow: "#eab308",
  green: "#22c55e", blue: "#3b82f6", purple: "#8b5cf6",
  gray: "#6b7280", dark: "#111827", card: "#1f2937",
  border: "#374151", text: "#f9fafb", muted: "#9ca3af"
};

// ─── DATI BASE ───────────────────────────────────────────
const COST_PER_IMAGE = {
  claude_prompt:   { label: "Claude Sonnet (prompt)",     cost: 0.0045, color: COLORS.blue },
  flux:            { label: "FLUX LoRA (Replicate)",       cost: 0.055,  color: COLORS.purple },
  claude_vision:   { label: "Claude Opus Vision (QC)",     cost: 0.0615, color: COLORS.red },
  claude_caption:  { label: "Claude Sonnet (caption)",     cost: 0.0032, color: COLORS.blue },
};

const COST_PER_IMAGE_OPT = {
  claude_prompt:   { label: "Claude Sonnet (prompt)",     cost: 0.0045, color: COLORS.blue },
  flux:            { label: "FLUX LoRA (Replicate)",       cost: 0.055,  color: COLORS.purple },
  claude_vision:   { label: "Claude Sonnet Vision (QC)",   cost: 0.0123, color: COLORS.green },
  claude_caption:  { label: "Claude Sonnet (caption)",     cost: 0.0032, color: COLORS.blue },
};

const INFRA = { n8n: 20, supabase: 25, dominio: 2 };
const INFRA_TOTAL = Object.values(INFRA).reduce((a,b) => a+b, 0);

const totalImg = (costs) => Object.values(costs).reduce((a, b) => a + b.cost, 0);
const BASE = totalImg(COST_PER_IMAGE);
const OPT  = totalImg(COST_PER_IMAGE_OPT);

function Badge({ color, children }) {
  const bg = color === "red" ? "#fef2f2" : color === "green" ? "#f0fdf4" : color === "ffa" ? "#fffbeb" : "#eff6ff";
  const tc = color === "red" ? "#dc2626" : color === "green" ? "#16a34a" : color === "ffa" ? "#d97706" : "#2563eb";
  return (
    <span style={{ background: bg, color: tc, padding: "2px 8px", borderRadius: 6, fontSize: 12, fontWeight: 600 }}>
      {children}
    </span>
  );
}

function Card({ title, children, accent }) {
  return (
    <div style={{ background: "#fff", border: `1px solid ${accent || "#e5e7eb"}`, borderRadius: 12, padding: 20, marginBottom: 16, borderTop: `3px solid ${accent || "#3b82f6"}` }}>
      {title && <div style={{ fontWeight: 700, fontSize: 15, marginBottom: 12, color: "#111827" }}>{title}</div>}
      {children}
    </div>
  );
}

function PieBar({ items, total }) {
  return (
    <div>
      <div style={{ display: "flex", borderRadius: 8, overflow: "hidden", height: 20, marginBottom: 8 }}>
        {items.map((item, i) => (
          <div key={i} style={{ width: `${(item.cost/total)*100}%`, background: item.color, transition: "width 0.3s" }} title={item.label} />
        ))}
      </div>
      <div style={{ display: "flex", flexWrap: "wrap", gap: "6px 16px" }}>
        {items.map((item, i) => (
          <div key={i} style={{ display: "flex", alignItems: "center", gap: 5, fontSize: 12 }}>
            <div style={{ width: 10, height: 10, borderRadius: 2, background: item.color, flexShrink: 0 }} />
            <span style={{ color: "#374151" }}>{item.label}: <strong>${item.cost.toFixed(4)}</strong> ({((item.cost/total)*100).toFixed(0)}%)</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function Section({ title, emoji, children }) {
  const [open, setOpen] = useState(true);
  return (
    <div style={{ marginBottom: 20 }}>
      <button onClick={() => setOpen(!open)} style={{ width: "100%", background: "#f8fafc", border: "1px solid #e2e8f0", borderRadius: 10, padding: "12px 16px", display: "flex", justifyContent: "space-between", alignItems: "center", cursor: "pointer", marginBottom: open ? 12 : 0 }}>
        <span style={{ fontWeight: 700, fontSize: 16, color: "#1e293b" }}>{emoji} {title}</span>
        <span style={{ color: "#94a3b8", fontSize: 14 }}>{open ? "▲ chiudi" : "▼ apri"}</span>
      </button>
      {open && children}
    </div>
  );
}

export default function Dashboard() {
  const [chars, setChars] = useState(3);
  const [postsDay, setPostsDay] = useState(2);
  const [addVideo, setAddVideo] = useState(false);
  const [videoService, setVideoService] = useState("kling");
  const [addAudio, setAddAudio] = useState(false);
  const [optimized, setOptimized] = useState(false);
  const [retryRate, setRetryRate] = useState(20);

  const costs = optimized ? COST_PER_IMAGE_OPT : COST_PER_IMAGE;
  const imgCost = totalImg(costs);
  const imgCostWithRetry = imgCost + (imgCost * (retryRate/100) * (imgCost * 0.9)); // retry adds ~FLUX+Vision
  const videoCost = videoService === "kling" ? 0.14 : 0.20;
  const audioCost = 0.045;

  const perPost = imgCost + (addVideo ? videoCost : 0) + (addAudio ? audioCost : 0);
  const perPostWithRetry = imgCostWithRetry + (addVideo ? videoCost : 0) + (addAudio ? audioCost : 0);

  const monthly = chars * postsDay * 30;
  const varCost = monthly * perPost * 0.93; // USD → EUR
  const varCostRetry = monthly * perPostWithRetry * 0.93;
  const totalCost = INFRA_TOTAL + varCost;
  const totalCostRetry = INFRA_TOTAL + varCostRetry;

  // ROI scenarios
  const roiScenarios = [
    { name: "500 follower IG", followers: 500, conv: 0.010 },
    { name: "2.000 follower IG", followers: 2000, conv: 0.010 },
    { name: "5.000 follower IG", followers: 5000, conv: 0.008 },
    { name: "10k follower IG", followers: 10000, conv: 0.006 },
    { name: "20k follower IG", followers: 20000, conv: 0.004 },
  ];

  const agencyScenarios = [
    { clients: 1, fee: 500 },
    { clients: 3, fee: 500 },
    { clients: 5, fee: 500 },
    { clients: 3, fee: 800 },
  ];

  const bugs = [
    { sev: "🔴", title: "video_status mancante nel DB", desc: "Il Workflow 5 filtra su video_status='pending' ma questa colonna non esiste in nessuna migration SQL. Il trigger non parte mai.", fix: "Aggiungere migration v5b con ALTER TABLE images ADD COLUMN video_status, video_url, video_task_id" },
    { sev: "🔴", title: "Upload audio rotto (Workflow 6)", desc: "Il nodo upload usa contentType multipart-form-data con bodyParameters vuoti + binaryPropertyName nelle options. In n8n queste due modalità sono mutualmente esclusive: il file audio non arriva mai su Storage.", fix: "Usare il nodo 'Move Binary Data' + HTTP Request con bodyContentType: binaryData puro, senza multipart" },
    { sev: "🔴", title: "Blocking poll su FastAPI async (comfy_bridge.py)", desc: "Il loop for _ in range(60): await asyncio.sleep(2) chiama la libreria Supabase sincrona dentro una route async, bloccando l'event loop. Con 3 richieste parallele → timeout garantito su tutte.", fix: "Usare WebSocket ComfyUI (/ws?clientId=xxx) per notifica push, wrappare Supabase client con asyncio.to_thread()" },
    { sev: "🔴", title: "Endpoint /generate-uncensored esposto", desc: "Il nome esplicito + nessuna autenticazione = vettore di attacco aperto. Chiunque raggiunga la porta 8000 può generare immagini senza limiti.", fix: "Rinominare endpoint, aggiungere API key header obbligatorio, bind su 127.0.0.1 non 0.0.0.0" },
    { sev: "🟡", title: "Runway vs Kling: API incompatibili", desc: "Il workflow 5 chiama api.runwayml.com con un body JSON pensato per Kling. Le due API hanno endpoint, auth e response format completamente diversi.", fix: "Scegliere uno dei due e adattare il nodo. Aggiungere IF branch per selezionare il provider." },
    { sev: "🟡", title: "Nessun error handling sul callback video", desc: "Se Runway/Kling fallisce, il callback arriva con status='failed'. Il workflow scrive video_status='completed' con video_url='' — dato corrotto nel DB.", fix: "Aggiungere IF node sul callback: controlla status === 'succeeded' prima di aggiornare il DB" },
    { sev: "🟡", title: "Telegram text è JSON stringa (Workflow 5)", desc: "Il campo text del nodo Telegram contiene '{\"text\": \"...\"}' — viene inviato letteralmente con le graffe come messaggio Telegram.", fix: "Rimuovere il wrapping JSON: usare direttamente la stringa del messaggio nel campo text" },
    { sev: "🟡", title: "Workflow ComfyUI hardcoded", desc: "get_base_workflow() ha PonyDiffusionV6.safetensors hardcoded. Non c'è modo di passare LoRA diversa per personaggio diverso.", fix: "Aggiungere parametri lora_name, lora_scale, checkpoint alla GenerateRequest. Caricare il workflow da file JSON esterno." },
    { sev: "🟢", title: "ElevenLabs voice_id non validato", desc: "Se il personaggio non ha elevenlabs_voice_id configurato, la chiamata va a /v1/text-to-speech/undefined → 404 silenzioso.", fix: "Aggiungere IF node prima di ElevenLabs: se !voice_id → skip con log, non errore fatale" },
    { sev: "🟢", title: "Video/audio senza calendario o throttling", desc: "Ogni approvazione triggera video+audio per tutti i personaggi. Con 5 chars × 2 post/giorno → 10 generazioni video simultanee.", fix: "Aggiungere campo generate_video BOOLEAN nel calendario e condizione nel Workflow 5" },
  ];

  return (
    <div style={{ fontFamily: "'Inter', system-ui, sans-serif", maxWidth: 860, margin: "0 auto", padding: "24px 16px", background: "#f8fafc", minHeight: "100vh" }}>
      <div style={{ background: "linear-gradient(135deg, #1e293b 0%, #0f172a 100%)", borderRadius: 16, padding: "24px 28px", marginBottom: 24, color: "#fff" }}>
        <div style={{ fontSize: 22, fontWeight: 800, marginBottom: 4 }}>📊 AI Character System — Analisi Costi & ROI</div>
        <div style={{ color: "#94a3b8", fontSize: 14 }}>Basata sui tuoi file reali: 6 workflow, 5 migration SQL, 1 bridge Python</div>
      </div>

      {/* SIMULATORE */}
      <Section title="Simulatore Costi Interattivo" emoji="🧮">
        <Card accent="#3b82f6">
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16, marginBottom: 16 }}>
            <div>
              <label style={{ fontSize: 13, color: "#374151", fontWeight: 600, display: "block", marginBottom: 4 }}>Personaggi attivi</label>
              <div style={{ display: "flex", gap: 8 }}>
                {[1,2,3,4,5].map(n => (
                  <button key={n} onClick={() => setChars(n)} style={{ width: 40, height: 40, borderRadius: 8, border: chars===n ? "2px solid #3b82f6" : "1px solid #d1d5db", background: chars===n ? "#eff6ff" : "#fff", fontWeight: 700, cursor: "pointer", color: chars===n ? "#2563eb" : "#374151" }}>{n}</button>
                ))}
              </div>
            </div>
            <div>
              <label style={{ fontSize: 13, color: "#374151", fontWeight: 600, display: "block", marginBottom: 4 }}>Post/giorno per personaggio</label>
              <div style={{ display: "flex", gap: 8 }}>
                {[1,2,3,4].map(n => (
                  <button key={n} onClick={() => setPostsDay(n)} style={{ width: 40, height: 40, borderRadius: 8, border: postsDay===n ? "2px solid #3b82f6" : "1px solid #d1d5db", background: postsDay===n ? "#eff6ff" : "#fff", fontWeight: 700, cursor: "pointer", color: postsDay===n ? "#2563eb" : "#374151" }}>{n}</button>
                ))}
              </div>
            </div>
          </div>

          <div style={{ display: "flex", flexWrap: "wrap", gap: 12, marginBottom: 16 }}>
            <label style={{ display: "flex", alignItems: "center", gap: 8, background: addVideo ? "#f0fdf4" : "#f9fafb", border: `1px solid ${addVideo ? "#22c55e" : "#e5e7eb"}`, borderRadius: 8, padding: "8px 14px", cursor: "pointer", fontSize: 13, fontWeight: 600 }}>
              <input type="checkbox" checked={addVideo} onChange={e => setAddVideo(e.target.checked)} style={{ accentColor: "#22c55e" }} />
              🎥 Attiva Video I2V
            </label>
            {addVideo && (
              <select value={videoService} onChange={e => setVideoService(e.target.value)} style={{ border: "1px solid #d1d5db", borderRadius: 8, padding: "8px 12px", fontSize: 13 }}>
                <option value="kling">Kling v1.5 ($0.14/video)</option>
                <option value="runway">Runway Gen-3 ($0.20/video)</option>
              </select>
            )}
            <label style={{ display: "flex", alignItems: "center", gap: 8, background: addAudio ? "#fdf4ff" : "#f9fafb", border: `1px solid ${addAudio ? "#a855f7" : "#e5e7eb"}`, borderRadius: 8, padding: "8px 14px", cursor: "pointer", fontSize: 13, fontWeight: 600 }}>
              <input type="checkbox" checked={addAudio} onChange={e => setAddAudio(e.target.checked)} style={{ accentColor: "#a855f7" }} />
              🎙️ Attiva ElevenLabs Audio
            </label>
            <label style={{ display: "flex", alignItems: "center", gap: 8, background: optimized ? "#fffbeb" : "#f9fafb", border: `1px solid ${optimized ? "#f59e0b" : "#e5e7eb"}`, borderRadius: 8, padding: "8px 14px", cursor: "pointer", fontSize: 13, fontWeight: 600 }}>
              <input type="checkbox" checked={optimized} onChange={e => setOptimized(e.target.checked)} style={{ accentColor: "#f59e0b" }} />
              ⚡ Applica ottimizzazioni
            </label>
          </div>

          <div style={{ marginBottom: 16 }}>
            <label style={{ fontSize: 13, color: "#374151", fontWeight: 600, display: "block", marginBottom: 4 }}>
              Tasso retry QC stimato: <strong>{retryRate}%</strong> dei post
            </label>
            <input type="range" min={0} max={60} value={retryRate} onChange={e => setRetryRate(+e.target.value)} style={{ width: "100%", accentColor: "#3b82f6" }} />
            <div style={{ display: "flex", justifyContent: "space-between", fontSize: 11, color: "#9ca3af" }}>
              <span>0% — nessun retry</span><span>30% — tipico</span><span>60% — worst case</span>
            </div>
          </div>

          {/* RISULTATO */}
          <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 12 }}>
            {[
              { label: "Per immagine (best)", value: `€${(perPost * 0.93).toFixed(4)}`, color: "#3b82f6" },
              { label: `API/mese (${monthly} post)`, value: `€${varCost.toFixed(2)}`, color: "#8b5cf6" },
              { label: "Totale operativo/mese", value: `€${totalCost.toFixed(2)}`, color: totalCost < 100 ? "#22c55e" : totalCost < 200 ? "#f59e0b" : "#ef4444" },
            ].map((item, i) => (
              <div key={i} style={{ background: "#f8fafc", border: `1px solid #e2e8f0`, borderRadius: 10, padding: 14, textAlign: "center" }}>
                <div style={{ fontSize: 11, color: "#6b7280", marginBottom: 4 }}>{item.label}</div>
                <div style={{ fontSize: 22, fontWeight: 800, color: item.color }}>{item.value}</div>
              </div>
            ))}
          </div>
          {retryRate > 0 && (
            <div style={{ marginTop: 10, background: "#fff7ed", border: "1px solid #fed7aa", borderRadius: 8, padding: "8px 12px", fontSize: 13, color: "#92400e" }}>
              ⚠️ Con {retryRate}% retry rate → costo effettivo sale a <strong>€{totalCostRetry.toFixed(2)}/mese</strong>
            </div>
          )}
        </Card>
      </Section>

      {/* BREAKDOWN COSTO PER IMMAGINE */}
      <Section title="Dove va ogni €0.12 per immagine" emoji="🔬">
        <Card accent={optimized ? "#22c55e" : "#ef4444"}>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 20 }}>
            <div>
              <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 8, color: "#374151" }}>
                {optimized ? "✅ Config ottimizzata" : "❌ Config attuale"}
              </div>
              <PieBar items={Object.values(optimized ? COST_PER_IMAGE_OPT : COST_PER_IMAGE)} total={optimized ? OPT : BASE} />
              <div style={{ marginTop: 12, fontSize: 22, fontWeight: 800, color: optimized ? "#16a34a" : "#dc2626" }}>
                ${(optimized ? OPT : BASE).toFixed(4)}/img
              </div>
            </div>
            <div style={{ background: "#f8fafc", borderRadius: 10, padding: 14 }}>
              <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 10, color: "#374151" }}>💡 Ottimizzazione chiave</div>
              <div style={{ fontSize: 13, color: "#374151", lineHeight: 1.7 }}>
                <div style={{ display: "flex", justifyContent: "space-between", borderBottom: "1px solid #e5e7eb", paddingBottom: 8, marginBottom: 8 }}>
                  <span>Claude <strong>Opus</strong> Vision</span>
                  <span style={{ color: "#dc2626", fontWeight: 700 }}>$0.0615</span>
                </div>
                <div style={{ display: "flex", justifyContent: "space-between", borderBottom: "1px solid #e5e7eb", paddingBottom: 8, marginBottom: 8 }}>
                  <span>Claude <strong>Sonnet</strong> Vision</span>
                  <span style={{ color: "#16a34a", fontWeight: 700 }}>$0.0123</span>
                </div>
                <div style={{ background: "#f0fdf4", borderRadius: 6, padding: "6px 10px", fontSize: 12, color: "#166534" }}>
                  <strong>-80% sul QC</strong> con qualità comparabile per immagini social standard
                </div>
                <div style={{ marginTop: 10, fontSize: 12, color: "#6b7280" }}>
                  Risparmio mensile ({chars} chars, {postsDay}p/g):
                  <strong style={{ color: "#16a34a", display: "block", fontSize: 16 }}>
                    €{((BASE - OPT) * chars * postsDay * 30 * 0.93).toFixed(2)}/mese
                  </strong>
                </div>
              </div>
            </div>
          </div>
        </Card>
      </Section>

      {/* ROI SCENARIOS */}
      <Section title="Quando diventa profittevole" emoji="💰">
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16 }}>
          <Card title="A) Fanvue / OnlyFans (subscription)" accent="#f59e0b">
            <div style={{ fontSize: 12, color: "#6b7280", marginBottom: 10 }}>Sub media €10/mese · Platform fee 20% · Conversion da IG: 0.6-1%</div>
            {roiScenarios.map((s, i) => {
              const paying = Math.floor(s.followers * s.conv);
              const revenue = paying * 10 * 0.80;
              const profit = revenue - totalCost;
              return (
                <div key={i} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "7px 0", borderBottom: i < roiScenarios.length-1 ? "1px solid #f3f4f6" : "none" }}>
                  <div>
                    <div style={{ fontSize: 13, fontWeight: 600 }}>{s.name}</div>
                    <div style={{ fontSize: 11, color: "#9ca3af" }}>{paying} sub paganti</div>
                  </div>
                  <div style={{ textAlign: "right" }}>
                    <div style={{ fontSize: 13, color: "#374151" }}>€{revenue.toFixed(0)}/mese</div>
                    <Badge color={profit >= 0 ? "green" : "red"}>{profit >= 0 ? `+€${profit.toFixed(0)}` : `-€${Math.abs(profit).toFixed(0)}`}</Badge>
                  </div>
                </div>
              );
            })}
          </Card>

          <Card title="B) Agenzia AI Content (consigliato)" accent="#22c55e">
            <div style={{ fontSize: 12, color: "#6b7280", marginBottom: 10 }}>Setup €1.500-3.000 · Canone mensile per personaggio gestito</div>
            {agencyScenarios.map((s, i) => {
              const revenue = s.clients * s.fee;
              const opCost = INFRA_TOTAL + (s.clients * postsDay * 30 * perPost * 0.93);
              const profit = revenue - opCost;
              const margin = ((profit / revenue) * 100).toFixed(0);
              return (
                <div key={i} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "7px 0", borderBottom: i < agencyScenarios.length-1 ? "1px solid #f3f4f6" : "none" }}>
                  <div>
                    <div style={{ fontSize: 13, fontWeight: 600 }}>{s.clients} clienti × €{s.fee}/mese</div>
                    <div style={{ fontSize: 11, color: "#9ca3af" }}>Revenue: €{revenue}</div>
                  </div>
                  <div style={{ textAlign: "right" }}>
                    <Badge color="green">+€{profit.toFixed(0)}/mese</Badge>
                    <div style={{ fontSize: 11, color: "#6b7280", marginTop: 3 }}>Margine {margin}%</div>
                  </div>
                </div>
              );
            })}
            <div style={{ marginTop: 10, background: "#f0fdf4", borderRadius: 8, padding: "8px 12px", fontSize: 12, color: "#166534" }}>
              ✅ <strong>Questo è il modello con margini più alti</strong> — 85-92% di margine operativo
            </div>
          </Card>
        </div>
      </Section>

      {/* BUG TRACKER */}
      <Section title="Bug e problemi trovati nel codice" emoji="🐛">
        <div style={{ fontSize: 13, color: "#6b7280", marginBottom: 12 }}>
          🔴 Critico (bloccante in produzione) · 🟡 Importante · 🟢 Miglioramento
        </div>
        {bugs.map((bug, i) => (
          <div key={i} style={{ background: "#fff", border: "1px solid #e5e7eb", borderRadius: 10, padding: 14, marginBottom: 10 }}>
            <div style={{ display: "flex", alignItems: "flex-start", gap: 8 }}>
              <span style={{ fontSize: 18, flexShrink: 0 }}>{bug.sev}</span>
              <div style={{ flex: 1 }}>
                <div style={{ fontWeight: 700, fontSize: 14, color: "#111827", marginBottom: 4 }}>{bug.title}</div>
                <div style={{ fontSize: 13, color: "#6b7280", marginBottom: 6 }}>{bug.desc}</div>
                <div style={{ background: "#f0fdf4", borderRadius: 6, padding: "6px 10px", fontSize: 12, color: "#166534" }}>
                  <strong>Fix:</strong> {bug.fix}
                </div>
              </div>
            </div>
          </div>
        ))}
      </Section>

      {/* ROADMAP COSTI */}
      <Section title="Soglie di volume e decisioni chiave" emoji="📈">
        <Card accent="#8b5cf6">
          <div style={{ fontSize: 13, color: "#374151", lineHeight: 1.9 }}>
            {[
              { range: "0–2 post/giorno totali", action: "Usa Replicate. Costo gestibile, zero infrastruttura da mantenere.", color: "#22c55e" },
              { range: "3–6 post/giorno totali", action: "Valuta ComfyUI locale su Mac. Break-even in ~2.5 settimane rispetto a Replicate.", color: "#f59e0b" },
              { range: "6+ post/giorno totali", action: "ComfyUI locale obbligatorio. Replicate diventa proibitivo (€55+/mese solo FLUX).", color: "#ef4444" },
              { range: "Video: max 3/settimana/char", action: "Usa Kling ($0.14). Limita a post con quality_score > 85.", color: "#3b82f6" },
              { range: "Audio: Stories/Reels speciali", action: "ElevenLabs Starter (€5/mese, 30k char) copre 200+ audio. Non usarlo su ogni post.", color: "#8b5cf6" },
            ].map((item, i) => (
              <div key={i} style={{ display: "flex", gap: 12, padding: "8px 0", borderBottom: i < 4 ? "1px solid #f3f4f6" : "none" }}>
                <div style={{ width: 4, borderRadius: 2, background: item.color, flexShrink: 0 }} />
                <div>
                  <strong style={{ fontSize: 13 }}>{item.range}:</strong>
                  <span style={{ fontSize: 13, color: "#6b7280" }}> {item.action}</span>
                </div>
              </div>
            ))}
          </div>
        </Card>
      </Section>

      <div style={{ textAlign: "center", fontSize: 12, color: "#9ca3af", marginTop: 8 }}>
        Prezzi API aggiornati a febbraio 2026 · EUR/USD ≈ 0.93 · Stime conservative
      </div>
    </div>
  );
}
