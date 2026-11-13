// SITE TEST — Paiement en ligne des locations de salles.
// La page paiement.html envoie { action, r, k } (r = n° de réservation, k = jeton du lien reçu par mail).
//   action = infos   → récapitulatif + mode de paiement
//   action = payer   → Stripe : crée la page de paiement et renvoie son adresse
//   action = simuler → mode démonstration (aucun compte Stripe) : paiement fictif, aucun argent ne bouge
// Stripe appelle aussi cette fonction (en-tête stripe-signature) quand un paiement est réussi.
// Après chaque paiement : la réservation passe « réservée », mail au demandeur et au service des sports.
//
// Secrets Supabase (Edge Functions → Secrets) :
//   STRIPE_SECRET_KEY      sk_test_…  (absent = mode démonstration)
//   STRIPE_WEBHOOK_SECRET  whsec_…    (signature des notifications Stripe)
//   RESEND_API_KEY, RESEND_FROM       (mails, déjà utilisés par les autres fonctions)
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const STRIPE_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const STRIPE_WH = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const FROM = Deno.env.get("RESEND_FROM") ?? "Planning Corbas <onboarding@resend.dev>";
const SITE = "https://din69960-hash.github.io/FUSION-DE-PLANNING-TEST/";
const MODE = STRIPE_KEY ? "stripe" : "simulation";

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
const PERIODES: Record<string, string> = { matin: "Matin", apres_midi: "Après-midi", soir: "Soir", journee: "Journée", weekend: "Week-end" };
const dateFr = (d: string) => new Date(d + "T12:00:00").toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long", year: "numeric", timeZone: "Europe/Paris" });
const eur = (v: unknown) => v === null || v === undefined || v === "" ? "—" : `${Number(v).toLocaleString("fr-FR")} €`;
const sb = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

async function envoyer(dest: string, sujet: string, corps: string) {
  if (!RESEND_KEY) return { statut: "erreur", detail: "Secret RESEND_API_KEY non défini : mail non envoyé." };
  const html = `<div style="font-family:Arial,sans-serif;font-size:14px;color:#1a2b44;line-height:1.5">${corps}
    <p style="color:#5a6b85;font-size:12px">Service des sports — Ville de Corbas · <a href="${SITE}">Réservation des salles municipales</a> (SITE TEST).</p></div>`;
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${RESEND_KEY}` },
      body: JSON.stringify({ from: FROM, to: [dest], subject: `[TEST] ${sujet}`, html }),
    });
    const out = await res.json().catch(() => ({}));
    return { statut: res.ok ? "envoye" : "erreur", detail: JSON.stringify(out) };
  } catch (e) { return { statut: "erreur", detail: String(e) }; }
}

// Paiement confirmé → réservation confirmée + mails (demandeur, service des sports)
async function confirmer(id: number, jeton: string, mode: string, ref: string | null, montant: number | null) {
  const c = sb();
  const { data, error } = await c.rpc("ft_paiement_confirmer", { p_resa: id, p_jeton: jeton, p_mode: mode, p_ref: ref, p_montant: montant });
  if (error) throw new Error(error.message);
  if (data?.deja) return { deja: true };
  const r = data.resa;
  const quand = `${dateFr(r.date)} — ${PERIODES[r.periode] ?? r.periode}`;
  const demo = mode === "simulation" ? " <i>(paiement de démonstration : aucun argent n'a été prélevé)</i>" : "";
  const cautions = r.caution_menage !== null || r.caution_reparation !== null
    ? `<p>🗝️ <b>Passez au service des sports le ${esc(dateFr(r.veille))}</b> (veille de l'événement) pour remettre les chèques de caution :
       caution ménage de <b>${esc(eur(r.caution_menage))}</b> et caution réparation de <b>${esc(eur(r.caution_reparation))}</b>.</p>` : "";
  const detail = `<table style="border-collapse:collapse;margin:12px 0">
    <tr><td style="padding:4px 12px 4px 0;color:#5a6b85">Salle</td><td><b>${esc(r.salle)}</b></td></tr>
    <tr><td style="padding:4px 12px 4px 0;color:#5a6b85">Date</td><td>${esc(quand)}</td></tr>
    <tr><td style="padding:4px 12px 4px 0;color:#5a6b85">Nature</td><td>${esc(r.nature_libelle)}</td></tr>
    <tr><td style="padding:4px 12px 4px 0;color:#5a6b85">Montant payé</td><td><b>${esc(eur(r.tarif))}</b>${demo}</td></tr></table>`;
  const s = await envoyer(data.dest_service, `💳 Paiement reçu — ${r.demandeur_nom} — ${r.salle} le ${new Date(r.date + "T12:00:00").toLocaleDateString("fr-FR")}`,
    `<p>Bonjour,</p><p><b>${esc(r.demandeur_nom)}</b> vient de payer en ligne sa location. La réservation est <b>confirmée</b> (rouge sur le planning).</p>${detail}
     <p>Contact : ${esc(r.contact_mail ?? "—")} · ${esc(r.contact_tel ?? "—")}</p>
     <p>Remise des chèques de caution prévue le <b>${esc(dateFr(r.veille))}</b> : ménage ${esc(eur(r.caution_menage))}, réparation ${esc(eur(r.caution_reparation))}.</p>
     <p><a href="${SITE}salles.html#demandes">Ouvrir les demandes</a> (espace administrateur).</p>`);
  await c.rpc("ft_mail_resultat", { p_log: data.log_service, p_statut: s.statut, p_detail: s.detail });
  if (data.dest_usager && data.log_usager) {
    const u = await envoyer(data.dest_usager, "Paiement reçu — votre réservation de salle est confirmée",
      `<p>Bonjour,</p><p>Nous avons bien reçu votre paiement. Votre réservation est <b>confirmée</b>.</p>${detail}${cautions}`);
    await c.rpc("ft_mail_resultat", { p_log: data.log_usager, p_statut: u.statut, p_detail: u.detail });
  }
  return { deja: false };
}

// Vérification de la signature Stripe (en-tête « t=…,v1=… »)
async function signatureOk(brut: string, entete: string) {
  const parts = Object.fromEntries(entete.split(",").map((x) => x.split("=") as [string, string]).filter((x) => x.length === 2).map(([k, v]) => [k, v]));
  const v1s = entete.split(",").filter((x) => x.startsWith("v1=")).map((x) => x.slice(3));
  const t = parts["t"];
  if (!t || !v1s.length || Math.abs(Date.now() / 1000 - Number(t)) > 600) return false;
  const cle = await crypto.subtle.importKey("raw", new TextEncoder().encode(STRIPE_WH), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", cle, new TextEncoder().encode(`${t}.${brut}`)));
  const hex = Array.from(sig).map((b) => b.toString(16).padStart(2, "0")).join("");
  return v1s.includes(hex);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ erreur: "Méthode non autorisée" }, 405);
  const brut = await req.text();

  // ---------- Notification Stripe ----------
  const sigStripe = req.headers.get("stripe-signature");
  if (sigStripe) {
    if (!STRIPE_WH || !(await signatureOk(brut, sigStripe))) return json({ erreur: "Signature invalide" }, 400);
    const evt = JSON.parse(brut);
    if (evt.type === "checkout.session.completed" || evt.type === "checkout.session.async_payment_succeeded") {
      const o = evt.data.object;
      if (o.payment_status === "paid" && o.metadata?.resa && o.metadata?.jeton) {
        try { await confirmer(Number(o.metadata.resa), String(o.metadata.jeton), "stripe", String(o.payment_intent ?? o.id), Number(o.amount_total) / 100); }
        catch (e) { return json({ erreur: String(e) }, 500); }   // Stripe réessaiera
      }
    }
    return json({ recu: true });
  }

  // ---------- Page de paiement ----------
  let body: { action?: string; r?: number | string; k?: string };
  try { body = JSON.parse(brut); } catch { return json({ erreur: "Requête invalide" }, 400); }
  const id = Number(body.r), k = String(body.k ?? "");
  if (!id || k.length < 20) return json({ erreur: "Lien de paiement invalide." }, 400);
  const { data: info, error } = await sb().rpc("ft_paiement_infos", { p_resa: id, p_jeton: k });
  if (error) return json({ erreur: error.message }, 400);

  if (body.action === "infos") return json({ mode: MODE, resa: info });

  if (info.statut !== "option") return json({ erreur: "Cette réservation n'attend pas de paiement.", resa: info }, 409);

  if (body.action === "simuler") {
    if (MODE !== "simulation") return json({ erreur: "Paiement de démonstration désactivé : Stripe est configuré." }, 400);
    try { await confirmer(id, k, "simulation", "DEMO-" + Date.now(), Number(info.tarif)); }
    catch (e) { return json({ erreur: String(e).replace(/^Error: /, "") }, 400); }
    return json({ ok: true });
  }

  if (body.action === "payer") {
    if (MODE !== "stripe") return json({ simulation: true });
    const retour = `${SITE}paiement.html?r=${id}&k=${k}`;
    const p = new URLSearchParams({
      mode: "payment",
      success_url: `${retour}&retour=ok`,
      cancel_url: `${retour}&retour=annule`,
      client_reference_id: String(id),
      "metadata[resa]": String(id), "metadata[jeton]": k,
      "payment_intent_data[metadata][resa]": String(id),
      "line_items[0][quantity]": "1",
      "line_items[0][price_data][currency]": "eur",
      "line_items[0][price_data][unit_amount]": String(Math.round(Number(info.tarif) * 100)),
      "line_items[0][price_data][product_data][name]": `Location ${info.salle} — ${new Date(info.date + "T12:00:00").toLocaleDateString("fr-FR")}`,
      "line_items[0][price_data][product_data][description]": `${info.nature_libelle} · ${info.demandeur_nom} · réservation n° ${id}`,
      locale: "fr",
      expires_at: String(Math.floor(Date.now() / 1000) + 3600),
    });
    if (info.contact_mail) p.set("customer_email", info.contact_mail);
    const res = await fetch("https://api.stripe.com/v1/checkout/sessions", {
      method: "POST", headers: { Authorization: `Bearer ${STRIPE_KEY}`, "Content-Type": "application/x-www-form-urlencoded" }, body: p,
    });
    const out = await res.json().catch(() => ({}));
    if (!res.ok || !out.url) return json({ erreur: out?.error?.message ?? "Stripe indisponible" }, 502);
    return json({ url: out.url });
  }
  return json({ erreur: "Action inconnue" }, 400);
});
