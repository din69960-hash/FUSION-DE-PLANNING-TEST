// SITE TEST — « Mot de passe oublié » des comptes Entreprise / Particulier.
// Le site envoie { profil, identifiant } ; la base prépare un lien à usage unique (valable 1 heure)
// et ce lien est envoyé UNIQUEMENT à l'adresse mail du compte. La réponse est toujours la même,
// que le compte existe ou non (on ne révèle pas quels comptes existent).
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const FROM = Deno.env.get("RESEND_FROM") ?? "Planning Corbas <onboarding@resend.dev>";
const SITE = "https://din69960-hash.github.io/FUSION-DE-PLANNING-TEST/index.html";

const esc = (s: unknown) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ erreur: "Méthode non autorisée" }, 405);
  let body: { profil?: string; identifiant?: string };
  try { body = await req.json(); } catch { return json({ erreur: "Requête invalide" }, 400); }
  const profil = String(body.profil ?? ""), identifiant = String(body.identifiant ?? "").trim();
  if (!["entreprise", "particulier"].includes(profil) || !identifiant) return json({ erreur: "Paramètres manquants" }, 400);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data: prep, error } = await sb.rpc("ft_usager_oubli_preparer", { p_profil: profil, p_identifiant: identifiant });
  if (error) return json({ erreur: "Service momentanément indisponible." }, 500);
  if (!prep?.trouve) return json({ ok: true });

  const lien = `${SITE}?reset=${encodeURIComponent(prep.jeton)}`;
  const html = `<div style="font-family:Arial,sans-serif;font-size:14px;color:#1a2b44;line-height:1.5">
    <p>Bonjour ${esc(prep.nom)},</p>
    <p>Vous avez demandé à changer le mot de passe de votre compte de réservation des salles municipales de Corbas.</p>
    <p><a href="${lien}" style="display:inline-block;background:#1a3a5c;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none;font-weight:bold">Choisir un nouveau mot de passe</a></p>
    <p style="color:#5a6b85;font-size:12px">Ce lien est valable 1 heure et ne fonctionne qu'une fois. Si vous n'êtes pas à l'origine de cette demande, ignorez ce message : votre mot de passe actuel reste valable.<br>Service des sports — Ville de Corbas (SITE TEST).</p>
  </div>`;
  if (!RESEND_KEY) return json({ ok: true });
  try {
    await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${RESEND_KEY}` },
      body: JSON.stringify({ from: FROM, to: [prep.mail], subject: "[TEST] Votre mot de passe — Salles municipales de Corbas", html }),
    });
  } catch (_e) { /* la réponse reste identique */ }
  return json({ ok: true });
});
