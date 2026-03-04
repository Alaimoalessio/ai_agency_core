import { useState, useEffect, useCallback } from "react";

// ─────────────────────────────────────────────────────────────────
// CONFIG — inserisci i tuoi valori Supabase
// In produzione metti questi in variabili d'ambiente
// ─────────────────────────────────────────────────────────────────
const SUPABASE_URL    = "https://TUO_PROGETTO.supabase.co";   // ← cambia questo
const SUPABASE_ANON   = "TUA_ANON_KEY";                       // ← cambia questo

// ─────────────────────────────────────────────────────────────────
// DATI FALLBACK (usati finché Supabase non è configurato)
// Questi sono i prezzi iniziali della migration_v6
// ─────────────────────────────────────────────────────────────────
const FALLBACK_PRICES = [
  { service: "replicate",   operation: "flux_dev",      label: "FLUX.1-dev + LoRA",           unit_cost_usd: 0.055,   unit_label: "per run",       category: "image" },
  { service: "anthropic",   operation: "sonnet_input",  label: "Claude Sonnet input",          unit_cost_usd: 0.003,   unit_label: "per 1k tokens", category: "llm" },
  { service: "anthropic",   operation: "opus_input",    label: "Claude Opus input (QC)",       unit_cost_usd: 0.015,   unit_label: "per 1k tokens", category: "llm" },
  { service: "kling",       operation: "i2v_4s",        label: "Kling v1.5 I2V 4s",           unit_cost_usd: 0.140,   unit_label: "per video",     category: "video" },
  { service: "runway",      operation: "gen3_4s",       label: "Runway Gen-3 4s",              unit_cost_usd: 0.200,   unit_label: "per video",     category: "video" },
  { service: "elevenlabs",  operation: "tts_char",      label: "ElevenLabs TTS",               unit_cost_usd: 0.0003,  unit_label: "per char",      category: "audio" },
];

const FALLBACK_MONTHLY = {
  images_eur: 0, video_eur: 0, audio_eur: 0, llm_eur: 0,
  total_variable_eur: 0, fixed_infra_eur: 47, total_eur: 47,
  images_this_month: 0, videos_this_month: 0, audio_this_month: 0
};

// ─────────────────────────────────────────────────────────────────
// API HELPER
// ─────────────────────────────────────────────────────────────────
async function supabaseGet(table, params = "") {
  const url = `${SUPABASE_URL}/rest/v1/${table}${params}`;
  const res = await fetch(url, {
    headers: { apikey: SUPABASE_ANON, Authorization: `Bearer ${SUPABASE_ANON}` }
  });
  if (!res.ok) throw new Error(`${res.status}: ${await res.text()}`);
  return res.json();
}

// ─────────────────────────────────────────────────────────────────
// COMPONENTI UI
// ─────────────────────────────────────────────────────────────────
function KPI({ label, value, sub, color = "#3b82f6", icon }) {
  return (
    <div style={{ background: "#fff", border: "1px solid #e5e7eb", borderRadius: 12, padding: "16px 20px", borderTop: `3px solid ${color}` }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>
        <div>
          <div style={{ fontSize: 12, color: "#6b7280", fontWeight: 600, marginBottom: 4 }}>{label}</div>
          <div style={{ fontSize: 28, fontWeight: 800, color: "#111827" }}>{value}</div>
          {sub && <div style={{ fontSize: 12, color: "#9ca3af", marginTop: 2 }}>{sub}</div>}
        </div>
        {icon && <span style={{ fontSize: 24 }}>{icon}</span>}
      </div>
    </div>
  );
}

function StatusDot({ ok }) {
  return <span style={{ display: "inline-block", width: 8, height: 8, borderRadius: "50%", background: ok ? "#22c55e" : "#ef4444", marginRight: 6 }} />;
}

function Bar({ value, max, color }) {
  const pct = max > 0 ? Math.min((value / max) * 100, 100) : 0;
  return (
    <div style={{ background: "#f3f4f6", borderRadius: 4, height: 8, overflow: "hidden" }}>
      <div style={{ width: `${pct}%`, height: "100%", background: color, borderRadius: 4, transition: "width 0.4s" }} />
    </div>
  );
}

function CostRow({ label, eur, max, color, icon }) {
  return (
    <div style={{ marginBottom: 14 }}>
      <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 4 }}>
        <span style={{ fontSize: 13, color: "#374151" }}>{icon} {label}</span>
        <span style={{ fontSize: 13, fontWeight: 700, color: eur > 0 ? color : "#9ca3af" }}>
          €{eur.toFixed(2)}
        </span>
      </div>
      <Bar value={eur} max={max} color={color} />
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────
// MAIN DASHBOARD
// ─────────────────────────────────────────────────────────────────
export default function CostDashboard() {
  const [prices, setPrices]       = useState(FALLBACK_PRICES);
  const [monthly, setMonthly]     = useState(FALLBACK_MONTHLY);
  const [history, setHistory]     = useState([]);
  const [byChar, setByChar]       = useState([]);
  const [loading, setLoading]     = useState(false);
  const [connected, setConnected] = useState(false);
  const [lastSync, setLastSync]   = useState(null);
  const [editMode, setEditMode]   = useState(false);
  const [editPrices, setEditPrices] = useState([]);
  const [tab, setTab]             = useState("overview");

  // Simulatore (usato quando non c'è ancora dati reali)
  const [simChars, setSimChars]     = useState(3);
  const [simPosts, setSimPosts]     = useState(2);
  const [simVideo, setSimVideo]     = useState(false);
  const [simAudio, setSimAudio]     = useState(false);
  const [simOptimized, setSimOpt]   = useState(false);

  const load = useCallback(async () => {
    if (SUPABASE_URL.includes("TUO_PROGETTO")) {
      setConnected(false);
      return;
    }
    setLoading(true);
    try {
      const [p, m, h, c] = await Promise.all([
        supabaseGet("api_prices", "?is_active=eq.true&order=category,service"),
        supabaseGet("cost_current_month"),
        supabaseGet("cost_summary_monthly", "?order=month.desc&limit=6"),
        supabaseGet("cost_by_character", "?order=month.desc,total_eur.desc&limit=20"),
      ]);
      if (p.length) setPrices(p);
      if (m.length) setMonthly(m[0]);
      setHistory(h);
      setByChar(c);
      setConnected(true);
      setLastSync(new Date());
    } catch (e) {
      console.warn("Supabase non raggiungibile:", e.message);
      setConnected(false);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  // Calcolo simulatore
  const fluxCost  = prices.find(p => p.operation === "flux_dev")?.unit_cost_usd || 0.055;
  const opusCost  = (prices.find(p => p.operation === "opus_input")?.unit_cost_usd || 0.015) * 2.6; // ~2600 tokens
  const sonnetQC  = (prices.find(p => p.operation === "sonnet_input")?.unit_cost_usd || 0.003) * 2.6;
  const sonnetLLM = (prices.find(p => p.operation === "sonnet_input")?.unit_cost_usd || 0.003) * 0.7;
  const klingCost = prices.find(p => p.operation === "i2v_4s")?.unit_cost_usd || 0.14;
  const audioCost = (prices.find(p => p.operation === "tts_char")?.unit_cost_usd || 0.0003) * 150;

  const qcCost = simOptimized ? sonnetQC : opusCost;
  const perImg = fluxCost + qcCost + sonnetLLM * 2;
  const perPost = perImg + (simVideo ? klingCost : 0) + (simAudio ? audioCost : 0);
  const simMonthly = simChars * simPosts * 30 * perPost * 0.93;
  const simTotal = 47 + simMonthly;

  const maxCost = Math.max(monthly.images_eur, monthly.video_eur, monthly.audio_eur, monthly.llm_eur, 1);

  const tabs = ["overview", "prezzi", "storico", "simulatore"];

  return (
    <div style={{ fontFamily: "'Inter', system-ui, sans-serif", maxWidth: 900, margin: "0 auto", padding: "20px 16px", background: "#f8fafc", minHeight: "100vh" }}>

      {/* HEADER */}
      <div style={{ background: "linear-gradient(135deg, #0f172a, #1e293b)", borderRadius: 14, padding: "20px 24px", marginBottom: 20, color: "#fff" }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <div>
            <div style={{ fontSize: 20, fontWeight: 800 }}>💸 Cost Monitor</div>
            <div style={{ fontSize: 13, color: "#94a3b8", marginTop: 2 }}>AI Character System — costi reali dal tuo Supabase</div>
          </div>
          <div style={{ textAlign: "right" }}>
            <div style={{ fontSize: 12, color: "#64748b" }}>
              <StatusDot ok={connected} />
              {connected ? "Supabase connesso" : "Modalità offline (dati simulati)"}
            </div>
            {lastSync && <div style={{ fontSize: 11, color: "#475569", marginTop: 2 }}>Sync: {lastSync.toLocaleTimeString("it-IT")}</div>}
            <button onClick={load} disabled={loading} style={{ marginTop: 6, background: "#1d4ed8", color: "#fff", border: "none", borderRadius: 6, padding: "4px 12px", fontSize: 12, cursor: "pointer" }}>
              {loading ? "⏳" : "↺ Aggiorna"}
            </button>
          </div>
        </div>
        {!connected && (
          <div style={{ marginTop: 12, background: "#1e3a5f", borderRadius: 8, padding: "8px 12px", fontSize: 12, color: "#93c5fd" }}>
            ℹ️ Configura <code>SUPABASE_URL</code> e <code>SUPABASE_ANON</code> in cima al file + esegui <code>migration_v6_cost_tracking.sql</code> per dati reali
          </div>
        )}
      </div>

      {/* TABS */}
      <div style={{ display: "flex", gap: 4, marginBottom: 20, background: "#fff", padding: 4, borderRadius: 10, border: "1px solid #e5e7eb" }}>
        {tabs.map(t => (
          <button key={t} onClick={() => setTab(t)} style={{ flex: 1, padding: "8px 4px", borderRadius: 7, border: "none", background: tab === t ? "#1d4ed8" : "transparent", color: tab === t ? "#fff" : "#6b7280", fontWeight: tab === t ? 700 : 500, fontSize: 13, cursor: "pointer", textTransform: "capitalize" }}>
            {t === "overview" ? "📊 Overview" : t === "prezzi" ? "🏷️ Prezzi API" : t === "storico" ? "📅 Storico" : "🧮 Simulatore"}
          </button>
        ))}
      </div>

      {/* ── TAB: OVERVIEW ── */}
      {tab === "overview" && (
        <>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: 12, marginBottom: 20 }}>
            <KPI label="Totale mese corrente" value={`€${monthly.total_eur}`} sub="fissi + variabili" color="#3b82f6" icon="💰" />
            <KPI label="Solo API variabili" value={`€${monthly.total_variable_eur}`} color="#8b5cf6" icon="📡" />
            <KPI label="Immagini generate" value={monthly.images_this_month} sub="questo mese" color="#22c55e" icon="🖼️" />
            <KPI label="Video generati" value={monthly.videos_this_month} sub="questo mese" color="#f59e0b" icon="🎥" />
          </div>

          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16 }}>
            <div style={{ background: "#fff", border: "1px solid #e5e7eb", borderRadius: 12, padding: 20 }}>
              <div style={{ fontWeight: 700, fontSize: 15, marginBottom: 16, color: "#111827" }}>Breakdown costi variabili</div>
              <CostRow label="Immagini (FLUX + LLM)" eur={monthly.images_eur + monthly.llm_eur} max={maxCost * 2} color="#3b82f6" icon="🖼️" />
              <CostRow label="Video I2V" eur={monthly.video_eur} max={maxCost * 2} color="#f59e0b" icon="🎥" />
              <CostRow label="Audio ElevenLabs" eur={monthly.audio_eur} max={maxCost * 2} color="#8b5cf6" icon="🎙️" />
              <div style={{ borderTop: "1px solid #f3f4f6", paddingTop: 12, marginTop: 4 }}>
                <div style={{ display: "flex", justifyContent: "space-between" }}>
                  <span style={{ fontSize: 13, color: "#6b7280" }}>🏗️ Infrastruttura fissa</span>
                  <span style={{ fontSize: 13, fontWeight: 700, color: "#6b7280" }}>€{monthly.fixed_infra_eur}</span>
                </div>
              </div>
            </div>

            <div style={{ background: "#fff", border: "1px solid #e5e7eb", borderRadius: 12, padding: 20 }}>
              <div style={{ fontWeight: 700, fontSize: 15, marginBottom: 16, color: "#111827" }}>Per personaggio (mese corrente)</div>
              {byChar.filter(r => r.month === byChar[0]?.month).length === 0
                ? <div style={{ color: "#9ca3af", fontSize: 13, textAlign: "center", paddingTop: 20 }}>
                    {connected ? "Nessun dato ancora — i costi appaiono qui dopo che i workflow loggano tramite log_cost_event()" : "Dati disponibili dopo connessione Supabase"}
                  </div>
                : byChar.filter(r => r.month === byChar[0]?.month).map((r, i) => (
                    <div key={i} style={{ display: "flex", justifyContent: "space-between", padding: "8px 0", borderBottom: "1px solid #f3f4f6" }}>
                      <div>
                        <div style={{ fontSize: 13, fontWeight: 600 }}>{r.character_name}</div>
                        <div style={{ fontSize: 11, color: "#9ca3af" }}>{r.images_generated} immagini · €{r.cost_per_image_usd} /img</div>
                      </div>
                      <div style={{ fontSize: 16, fontWeight: 800, color: "#374151" }}>€{r.total_eur}</div>
                    </div>
                  ))
              }
            </div>
          </div>
        </>
      )}

      {/* ── TAB: PREZZI API ── */}
      {tab === "prezzi" && (
        <div style={{ background: "#fff", border: "1px solid #e5e7eb", borderRadius: 12, padding: 20 }}>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
            <div>
              <div style={{ fontWeight: 700, fontSize: 16 }}>Prezzi API correnti</div>
              <div style={{ fontSize: 12, color: "#9ca3af", marginTop: 2 }}>
                {connected ? "Dati live da Supabase — aggiorna via SQL: UPDATE api_prices SET unit_cost_usd=X WHERE operation=Y" : "Prezzi di default (migration_v6)"}
              </div>
            </div>
            {connected && (
              <button onClick={() => { setEditMode(!editMode); setEditPrices(prices.map(p => ({...p}))); }}
                style={{ background: editMode ? "#ef4444" : "#f0fdf4", border: `1px solid ${editMode ? "#fca5a5" : "#86efac"}`, borderRadius: 8, padding: "6px 14px", fontSize: 13, cursor: "pointer", color: editMode ? "#dc2626" : "#16a34a", fontWeight: 600 }}>
                {editMode ? "✗ Annulla" : "✎ Modifica prezzi"}
              </button>
            )}
          </div>

          {["image", "video", "audio", "llm"].map(cat => {
            const catPrices = prices.filter(p => p.category === cat);
            if (!catPrices.length) return null;
            const icons = { image: "🖼️", video: "🎥", audio: "🎙️", llm: "🧠" };
            const colors = { image: "#3b82f6", video: "#f59e0b", audio: "#8b5cf6", llm: "#06b6d4" };
            return (
              <div key={cat} style={{ marginBottom: 20 }}>
                <div style={{ fontSize: 13, fontWeight: 700, color: colors[cat], marginBottom: 8, textTransform: "uppercase", letterSpacing: 1 }}>
                  {icons[cat]} {cat}
                </div>
                {catPrices.map((p, i) => (
                  <div key={i} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "10px 12px", background: "#f9fafb", borderRadius: 8, marginBottom: 6 }}>
                    <div>
                      <div style={{ fontSize: 13, fontWeight: 600 }}>{p.label}</div>
                      <div style={{ fontSize: 11, color: "#9ca3af" }}>{p.service} · {p.operation}</div>
                    </div>
                    <div style={{ textAlign: "right" }}>
                      {editMode ? (
                        <input type="number" step="0.000001" value={editPrices.find(ep => ep.operation === p.operation)?.unit_cost_usd || p.unit_cost_usd}
                          onChange={e => setEditPrices(prev => prev.map(ep => ep.operation === p.operation ? {...ep, unit_cost_usd: parseFloat(e.target.value)} : ep))}
                          style={{ width: 90, padding: "4px 8px", border: "1px solid #d1d5db", borderRadius: 6, fontSize: 13, textAlign: "right" }} />
                      ) : (
                        <div style={{ fontSize: 16, fontWeight: 800, color: "#111827" }}>${p.unit_cost_usd}</div>
                      )}
                      <div style={{ fontSize: 11, color: "#9ca3af" }}>{p.unit_label}</div>
                    </div>
                  </div>
                ))}
              </div>
            );
          })}

          {editMode && (
            <div style={{ background: "#fffbeb", border: "1px solid #fde68a", borderRadius: 8, padding: "10px 14px", fontSize: 13, color: "#92400e" }}>
              ⚠️ La modifica diretta via UI non è implementata per sicurezza. Aggiorna i prezzi con questo SQL su Supabase:<br/>
              <code style={{ display: "block", marginTop: 6, background: "#fef3c7", padding: "6px 8px", borderRadius: 4, fontSize: 12 }}>
                UPDATE api_prices SET unit_cost_usd = [NUOVO_VALORE] WHERE service = '[SERVICE]' AND operation = '[OPERATION]';
              </code>
            </div>
          )}
        </div>
      )}

      {/* ── TAB: STORICO ── */}
      {tab === "storico" && (
        <div style={{ background: "#fff", border: "1px solid #e5e7eb", borderRadius: 12, padding: 20 }}>
          <div style={{ fontWeight: 700, fontSize: 16, marginBottom: 16 }}>Storico mensile</div>
          {history.length === 0
            ? <div style={{ textAlign: "center", padding: "40px 0", color: "#9ca3af" }}>
                <div style={{ fontSize: 32, marginBottom: 8 }}>📭</div>
                <div style={{ fontSize: 14 }}>
                  {connected
                    ? "Nessun dato storico ancora. I costi appaiono qui dopo che i workflow n8n iniziano a chiamare log_cost_event()"
                    : "Connetti Supabase per vedere lo storico reale"}
                </div>
              </div>
            : (() => {
                const months = [...new Set(history.map(r => r.month_label))];
                return months.map(m => {
                  const rows = history.filter(r => r.month_label === m);
                  const total = rows.reduce((a, r) => a + parseFloat(r.total_eur || 0), 0);
                  return (
                    <div key={m} style={{ marginBottom: 20 }}>
                      <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 8 }}>
                        <span style={{ fontWeight: 700, color: "#374151" }}>{m}</span>
                        <span style={{ fontWeight: 800, color: "#111827" }}>€{total.toFixed(2)} totale</span>
                      </div>
                      {rows.map((r, i) => (
                        <div key={i} style={{ display: "flex", justifyContent: "space-between", padding: "6px 10px", background: "#f9fafb", borderRadius: 6, marginBottom: 4, fontSize: 13 }}>
                          <span>{r.service} — {r.category}</span>
                          <span style={{ fontWeight: 600 }}>€{parseFloat(r.total_eur).toFixed(2)} ({r.event_count} op.)</span>
                        </div>
                      ))}
                    </div>
                  );
                });
              })()
          }
        </div>
      )}

      {/* ── TAB: SIMULATORE ── */}
      {tab === "simulatore" && (
        <div>
          <div style={{ background: "#fff", border: "1px solid #e5e7eb", borderRadius: 12, padding: 20, marginBottom: 16 }}>
            <div style={{ fontWeight: 700, fontSize: 15, marginBottom: 16 }}>Proiezione costi con i tuoi prezzi attuali</div>
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16, marginBottom: 16 }}>
              <div>
                <label style={{ fontSize: 12, fontWeight: 600, color: "#374151", display: "block", marginBottom: 6 }}>Personaggi attivi</label>
                <div style={{ display: "flex", gap: 6 }}>
                  {[1,2,3,4,5].map(n => (
                    <button key={n} onClick={() => setSimChars(n)} style={{ width: 40, height: 40, borderRadius: 8, border: simChars===n ? "2px solid #3b82f6" : "1px solid #d1d5db", background: simChars===n ? "#eff6ff" : "#f9fafb", fontWeight: 700, cursor: "pointer", color: simChars===n ? "#1d4ed8" : "#374151" }}>{n}</button>
                  ))}
                </div>
              </div>
              <div>
                <label style={{ fontSize: 12, fontWeight: 600, color: "#374151", display: "block", marginBottom: 6 }}>Post/giorno per personaggio</label>
                <div style={{ display: "flex", gap: 6 }}>
                  {[1,2,3,4].map(n => (
                    <button key={n} onClick={() => setSimPosts(n)} style={{ width: 40, height: 40, borderRadius: 8, border: simPosts===n ? "2px solid #3b82f6" : "1px solid #d1d5db", background: simPosts===n ? "#eff6ff" : "#f9fafb", fontWeight: 700, cursor: "pointer", color: simPosts===n ? "#1d4ed8" : "#374151" }}>{n}</button>
                  ))}
                </div>
              </div>
            </div>

            <div style={{ display: "flex", flexWrap: "wrap", gap: 10, marginBottom: 16 }}>
              {[
                { state: simVideo, set: setSimVideo, label: "🎥 Video I2V attivo" },
                { state: simAudio, set: setSimAudio, label: "🎙️ Audio ElevenLabs" },
                { state: simOptimized, set: setSimOpt, label: "⚡ QC con Sonnet invece di Opus" },
              ].map((item, i) => (
                <label key={i} style={{ display: "flex", alignItems: "center", gap: 8, padding: "8px 14px", border: `1px solid ${item.state ? "#3b82f6" : "#e5e7eb"}`, borderRadius: 8, background: item.state ? "#eff6ff" : "#f9fafb", cursor: "pointer", fontSize: 13, fontWeight: 600 }}>
                  <input type="checkbox" checked={item.state} onChange={e => item.set(e.target.checked)} style={{ accentColor: "#3b82f6" }} />
                  {item.label}
                </label>
              ))}
            </div>

            <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 12 }}>
              {[
                { label: "Per immagine", value: `€${(perImg * 0.93).toFixed(4)}`, color: "#3b82f6" },
                { label: `API/mese (${simChars * simPosts * 30} post)`, value: `€${simMonthly.toFixed(2)}`, color: "#8b5cf6" },
                { label: "Totale operativo/mese", value: `€${simTotal.toFixed(2)}`, color: simTotal < 80 ? "#22c55e" : simTotal < 150 ? "#f59e0b" : "#ef4444" },
              ].map((item, i) => (
                <div key={i} style={{ background: "#f8fafc", borderRadius: 10, padding: 14, textAlign: "center", border: "1px solid #e5e7eb" }}>
                  <div style={{ fontSize: 11, color: "#9ca3af", marginBottom: 4 }}>{item.label}</div>
                  <div style={{ fontSize: 22, fontWeight: 800, color: item.color }}>{item.value}</div>
                </div>
              ))}
            </div>

            {connected && (
              <div style={{ marginTop: 12, background: "#f0fdf4", border: "1px solid #bbf7d0", borderRadius: 8, padding: "8px 12px", fontSize: 12, color: "#166534" }}>
                ✅ I prezzi usati nella simulazione sono quelli <strong>live dal tuo Supabase</strong> — aggiornati automaticamente quando modifichi <code>api_prices</code>
              </div>
            )}
          </div>
        </div>
      )}

      <div style={{ textAlign: "center", fontSize: 11, color: "#d1d5db", marginTop: 16 }}>
        Aggiorna i prezzi: <code>UPDATE api_prices SET unit_cost_usd = X WHERE operation = 'Y';</code>
      </div>
    </div>
  );
}
