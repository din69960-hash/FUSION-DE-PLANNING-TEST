// SITE TEST — Mails des conventions de partenariat.
// Le site envoie { token, id, evt } ; la base vérifie le droit d'envoyer ce mail, choisit le destinataire
// et fournit le contenu (pas de relais de mails ouvert).
//   a_signer → association : la convention est prête à signer (envoyé par l'administrateur)
//   code     → association : code de signature à 6 chiffres, valable 15 minutes
//   signee   → association + service des sports : confirmation de signature
//   demande  → service des sports : nouvelle demande de compte association (sans session)
//   reponse  → demandeur : compte créé ou demande refusée (envoyé par l'administrateur)
import { createClient } from "npm:@supabase/supabase-js@2";
import { envoiMail, MAIL_PRET, MAIL_ABSENT } from "./envoi.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const SITE = "https://din69960-hash.github.io/FUSION-DE-PLANNING-TEST/";
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const dateHeure = (d: string) => new Date(d).toLocaleString("fr-FR", { dateStyle: "long", timeStyle: "short", timeZone: "Europe/Paris" });
const saisonLib = (a: number) => `${a}–${Number(a) + 1}`;
const bouton = (href: string, txt: string, coul = "#1a3a5c") =>
  `<p style="margin:18px 0"><a href="${href}" style="background:${coul};color:#fff;text-decoration:none;font-weight:bold;padding:12px 22px;border-radius:8px;display:inline-block">${txt}</a></p>`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ erreur: "Méthode non autorisée" }, 405);
  let body: { token?: string; id?: number; evt?: string };
  try { body = await req.json(); } catch { return json({ erreur: "Requête invalide" }, 400); }
  const { token, id, evt } = body;
  if (!id || !evt) return json({ erreur: "Paramètres manquants" }, 400);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data: prep, error } = await sb.rpc("ft_conv_mail_preparer", { p_token: token ?? null, p_id: Number(id), p_evt: String(evt) });
  if (error) return json({ erreur: error.message }, 400);
  if (prep?.deja) return json({ envoye: false, deja: true });

  const c = prep.conv || {}, f = prep.fiche || {}, d = prep.demande || {};
  const nomAsso = f.nom_officiel || c.asso || "";
  let sujet = "", corps = "";
  switch (evt) {
    case "a_signer":
      sujet = `Convention de partenariat ${saisonLib(c.saison)} à signer — ${nomAsso}`;
      corps = `<p>Bonjour,</p>
        <p>La convention annuelle de partenariat <b>${esc(saisonLib(c.saison))}</b> entre la Ville de Corbas et <b>${esc(nomAsso)}</b> est prête.</p>
        <p>Le président ou la présidente peut la lire et la signer en ligne : connectez-vous à l'espace association, menu <b>« Ma fiche et mes conventions »</b>.
        Un code de vérification sera envoyé à cette adresse au moment de signer.</p>
        ${bouton(`${SITE}conventions.html`, "✍️ Lire et signer la convention")}
        <p style="font-size:12px;color:#5a6b85">La Ville signera ensuite la convention de son côté et vous pourrez télécharger la version définitive au même endroit.</p>`;
      break;
    case "code":
      sujet = `${prep.code} — votre code de signature de la convention`;
      corps = `<p>Bonjour,</p>
        <p>Voici le code pour signer la convention de partenariat <b>${esc(saisonLib(c.saison))}</b> de <b>${esc(nomAsso)}</b> :</p>
        <p style="font-size:30px;font-weight:bold;letter-spacing:8px;background:#f4f7fb;border:2px dashed #1a3a5c;border-radius:10px;padding:14px 20px;display:inline-block">${esc(prep.code)}</p>
        <p>Il est valable <b>15 minutes</b>. Saisissez-le sur le site pour valider votre signature.</p>
        <p style="font-size:12px;color:#5a6b85">Si vous n'êtes pas à l'origine de cette demande, ne communiquez ce code à personne et prévenez le service des sports.</p>`;
      break;
    case "signee":
      sujet = `Convention ${saisonLib(c.saison)} signée par ${nomAsso}`;
      corps = `<p>Bonjour,</p>
        <p>La convention de partenariat <b>${esc(saisonLib(c.saison))}</b> a été signée électroniquement pour <b>${esc(nomAsso)}</b>.</p>
        <table style="border-collapse:collapse;margin:12px 0">
          <tr><td style="padding:4px 12px 4px 0;color:#5a6b85">Signataire</td><td><b>${esc(c.signataire)}</b>${c.signataire_qualite ? ` (${esc(c.signataire_qualite)})` : ""}</td></tr>
          <tr><td style="padding:4px 12px 4px 0;color:#5a6b85">Date</td><td>${esc(dateHeure(c.signe_le))}</td></tr>
          <tr><td style="padding:4px 12px 4px 0;color:#5a6b85">Empreinte du texte</td><td style="font-family:monospace;font-size:11px">${esc(prep.empreinte)}</td></tr>
        </table>
        <p>La Ville va maintenant faire signer la convention par le Maire. La version définitive sera disponible dans l'espace association.</p>
        ${bouton(`${SITE}conventions.html`, "Voir la convention")}`;
      break;
    case "demande":
      sujet = `Demande de compte association — ${d.infos?.nom_officiel ?? ""}`;
      corps = `<p>Bonjour,</p><p>Nouvelle demande de création de compte association :</p>
        <table style="border-collapse:collapse;margin:12px 0">
          ${[["Association", d.infos?.nom_officiel], ["SIRET", d.infos?.siret], ["Président(e)", d.infos?.president], ["Mail", d.infos?.mail],
             ["Téléphone", d.infos?.telephone], ["Siège social", d.infos?.siege], ["Activité", d.infos?.activite], ["Fédération", d.infos?.federation],
             ["Message", d.infos?.message]].filter(([, v]) => v)
            .map(([k, v]) => `<tr><td style="padding:4px 12px 4px 0;color:#5a6b85;vertical-align:top">${k}</td><td style="white-space:pre-line">${esc(v)}</td></tr>`).join("")}
        </table>
        ${bouton(`${SITE}conventions.html#demandes`, "Traiter la demande")}`;
      break;
    case "reponse":
      if (d.statut === "acceptee") {
        sujet = "Votre compte association est créé — Ville de Corbas";
        corps = `<p>Bonjour,</p><p>Le compte de <b>${esc(d.infos?.nom_officiel)}</b> est créé sous le nom <b>« ${esc(d.nom_compte)} »</b>.</p>
          <p>Sur le site, cliquez sur « Association », choisissez « ${esc(d.nom_compte)} » dans la liste puis créez votre mot de passe (première connexion).</p>
          ${d.message ? `<p style="background:#f4f7fb;border-left:4px solid #1a3a5c;padding:10px 14px;white-space:pre-line">${esc(d.message)}</p>` : ""}
          ${bouton(SITE, "Accéder au site")}`;
      } else {
        sujet = "Votre demande de compte association — Ville de Corbas";
        corps = `<p>Bonjour,</p><p>Votre demande de compte pour <b>${esc(d.infos?.nom_officiel)}</b> n'a pas pu être acceptée.</p>
          ${d.message ? `<p style="background:#f4f7fb;border-left:4px solid #1a3a5c;padding:10px 14px;white-space:pre-line">${esc(d.message)}</p>` : ""}
          <p>Pour toute question : service des sports de la Ville de Corbas.</p>`;
      }
      break;
    default:
      return json({ erreur: "Évènement inconnu" }, 400);
  }
  const html = `<div style="font-family:Arial,sans-serif;font-size:14px;color:#1a2b44;line-height:1.5">${corps}
    <p style="color:#5a6b85;font-size:12px">Service des sports — Ville de Corbas · message automatique (SITE TEST).</p></div>`;

  if (!MAIL_PRET) {
    await sb.rpc("ft_mail_resultat", { p_log: prep.log, p_statut: "erreur", p_detail: MAIL_ABSENT });
    return json({ envoye: false, detail: MAIL_ABSENT }, 503);
  }
  const e = await envoiMail(prep.dest, `[TEST] ${sujet}`, html);
  const statut = e.ok ? "envoye" : "erreur";
  await sb.rpc("ft_mail_resultat", { p_log: prep.log, p_statut: statut, p_detail: e.detail });
  return json({ envoye: e.ok, detail: e.ok ? undefined : e.detail }, e.ok ? 200 : 502);
});
