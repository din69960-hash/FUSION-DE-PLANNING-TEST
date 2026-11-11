// SITE TEST — Mails automatiques de la réservation des salles municipales.
// Le site envoie { token, id, evt } ; la base vérifie le droit d'envoyer ce mail,
// choisit le destinataire et fournit le contenu (pas de relais de mails ouvert).
//   evt = nouvelle  → service des sports (envoyé par le demandeur après sa demande)
//   evt = validee | pieces | refusee | reservee | annulee → demandeur (envoyé par l'administrateur)
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const FROM = Deno.env.get("RESEND_FROM") ?? "Planning Corbas <onboarding@resend.dev>";
const SITE = "https://din69960-hash.github.io/FUSION-DE-PLANNING-TEST/";

const esc = (s: unknown) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const PERIODES: Record<string, string> = { matin: "Matin", apres_midi: "Après-midi", soir: "Soir", journee: "Journée", weekend: "Week-end" };
const PROFILS: Record<string, string> = { asso: "Association", entreprise: "Entreprise", particulier: "Particulier" };
const dateFr = (d: string) => {
  const x = new Date(d + "T12:00:00");
  return x.toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long", year: "numeric", timeZone: "Europe/Paris" });
};
const euros = (t: unknown) => t === null || t === undefined ? "communiqué par le service des sports" : Number(t) === 0 ? "gratuit" : `${Number(t).toLocaleString("fr-FR")} €`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ erreur: "Méthode non autorisée" }, 405);
  let body: { token?: string; id?: number; evt?: string };
  try { body = await req.json(); } catch { return json({ erreur: "Requête invalide" }, 400); }
  const { token, id, evt } = body;
  if (!token || !id || !evt) return json({ erreur: "Paramètres manquants" }, 400);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data: prep, error } = await sb.rpc("ft_resa_mail_preparer", { p_token: token, p_resa: Number(id), p_evt: String(evt) });
  if (error) return json({ erreur: error.message }, 400);
  if (prep?.deja) return json({ envoye: false, deja: true, sans_adresse: !!prep.sans_adresse });

  const r = prep.resa || {};
  const quand = `${dateFr(r.date)}${r.periode === "weekend" ? " (week-end)" : ""} — ${PERIODES[r.periode] ?? r.periode}`;
  const nature = r.nature_libelle + (r.precision ? ` (${r.precision})` : "");
  const ligne = (k: string, v: string) => `<tr><td style="padding:4px 12px 4px 0;color:#5a6b85;vertical-align:top">${k}</td><td>${v}</td></tr>`;
  const detail = `<table style="border-collapse:collapse;margin:12px 0">
    ${ligne("Salle", `<b>${esc(r.salle)}</b>`)}
    ${ligne("Date", esc(quand))}
    ${ligne("Nature", esc(nature))}
    ${r.nb_personnes ? ligne("Personnes", esc(r.nb_personnes)) : ""}
    ${ligne("Tarif", esc(euros(r.tarif)))}
  </table>`;
  const msg = r.message ? `<p style="background:#f4f7fb;border-left:4px solid #1a3a5c;padding:10px 14px;white-space:pre-line">${esc(r.message)}</p>` : "";

  let sujet = "", corps = "";
  switch (evt) {
    case "nouvelle":
      sujet = `Nouvelle demande de salle — ${r.demandeur_nom}`;
      corps = `<p>Bonjour,</p><p>Nouvelle demande de réservation de salle municipale de la part de <b>${esc(r.demandeur_nom)}</b> (${esc(PROFILS[r.profil] ?? r.profil)}).</p>
        ${detail}${r.remarque ? `<p><b>Remarque :</b><br><span style="white-space:pre-line">${esc(r.remarque)}</span></p>` : ""}
        <p>Pièces déposées : ${(r.pieces || []).length}. <a href="${SITE}salles.html">Traiter la demande</a> (espace administrateur).</p>`;
      break;
    case "validee": {
      const ech = r.echeance ? new Date(r.echeance + "T12:00:00").toLocaleDateString("fr-FR", { timeZone: "Europe/Paris" }) : "";
      sujet = "Votre demande de salle est validée — paiement à effectuer";
      corps = `<p>Bonjour,</p><p>Votre demande de réservation est <b>validée</b>. La date vous est réservée en option.</p>${detail}${msg}
        <p><b>Pour confirmer la réservation, vous devez procéder au paiement avant le ${esc(ech)}</b> (délai de ${esc(prep.delai)} jours).
        Sans paiement dans ce délai, la réservation est annulée automatiquement et la date redevient libre.</p>`;
      break;
    }
    case "pieces":
      sujet = "Votre demande de salle — pièces à compléter";
      corps = `<p>Bonjour,</p><p>Votre demande de réservation est bien enregistrée, mais il manque des pièces pour la traiter :</p>${msg}${detail}
        <p>Ajoutez-les depuis le site, menu <b>« Mes demandes »</b>. La date reste réservée pour vous pendant ce temps.</p>`;
      break;
    case "refusee":
      sujet = "Votre demande de salle n'a pas pu être acceptée";
      corps = `<p>Bonjour,</p><p>Nous sommes au regret de ne pas pouvoir donner suite à votre demande de réservation.</p>${detail}${msg}`;
      break;
    case "reservee":
      sujet = "Votre réservation de salle est confirmée";
      corps = `<p>Bonjour,</p><p>Votre réservation est <b>confirmée</b>.</p>${detail}${msg}
        <p>Le service des sports vous contactera pour la remise des clés, les états des lieux d'entrée et de sortie et le chèque de caution.</p>`;
      break;
    case "annulee":
      sujet = "Votre réservation de salle est annulée";
      corps = `<p>Bonjour,</p><p>Votre réservation a été annulée par le service des sports.</p>${detail}${msg}`;
      break;
  }
  const html = `<div style="font-family:Arial,sans-serif;font-size:14px;color:#1a2b44;line-height:1.5">${corps}
    <p style="color:#5a6b85;font-size:12px">Service des sports — Ville de Corbas · <a href="${SITE}">Réservation des salles municipales</a> (SITE TEST).</p></div>`;

  let statut = "erreur", detailEnvoi = "";
  if (!RESEND_KEY) {
    detailEnvoi = "Secret RESEND_API_KEY non défini dans Supabase : mail non envoyé.";
    await sb.rpc("ft_mail_resultat", { p_log: prep.log, p_statut: statut, p_detail: detailEnvoi });
    return json({ envoye: false, detail: detailEnvoi }, 503);
  }
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${RESEND_KEY}` },
      body: JSON.stringify({ from: FROM, to: [prep.dest], subject: `[TEST] ${sujet}`, html }),
    });
    const out = await res.json().catch(() => ({}));
    statut = res.ok ? "envoye" : "erreur";
    detailEnvoi = JSON.stringify(out);
  } catch (e) { detailEnvoi = String(e); }
  await sb.rpc("ft_mail_resultat", { p_log: prep.log, p_statut: statut, p_detail: detailEnvoi });
  return json({ envoye: statut === "envoye", detail: statut === "envoye" ? undefined : detailEnvoi }, statut === "envoye" ? 200 : 502);
});
