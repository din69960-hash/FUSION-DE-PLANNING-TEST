-- Étape 8 — Conventions de partenariat et signature en ligne (20/11/2026)
--   ft_conv_fiches            fiche de chaque association (SIRET, président, siège, AG, activité, fédération, statuts)
--   ft_conv_modeles           modèles de convention (texte avec champs automatiques)
--   ft_conv_saisons           paramètres communs d'une saison (délibération, dates, années, texte sans subvention…)
--   ft_conv_donnees           tableau « données automatiques » : une ligne par association et par saison
--   ft_conv_conventions       conventions envoyées, signées par l'association, puis finalisées (retour i-parapheur)
--   ft_conv_demandes_compte   demandes de création de compte association
-- Aucun accès direct aux tables : tout passe par les fonctions ci-dessous (session vérifiée par la base).

create table if not exists public.ft_conv_fiches(
  asso text primary key,
  nom_officiel text, siret text, forme text default 'Association loi 1901',
  president text, president_qualite text default 'Président(e)', mail text, telephone text,
  date_ag date, siege text, activite text, federation text,
  statuts_nom text, statuts_type text, statuts_contenu text, statuts_maj timestamptz,
  maj timestamptz not null default now(), maj_par text
);
create table if not exists public.ft_conv_modeles(
  id bigserial primary key, nom text not null, contenu text not null default '', ordre int not null default 0,
  maj timestamptz not null default now(), supprime boolean not null default false
);
create table if not exists public.ft_conv_saisons(
  saison int primary key, params jsonb not null default '{}'::jsonb, maj timestamptz not null default now()
);
create table if not exists public.ft_conv_donnees(
  saison int not null, asso text not null,
  concernee boolean not null default true, modele_id bigint,
  afficher_subvention boolean not null default true,
  montant_global numeric, versements jsonb not null default '[]'::jsonb, autres_aides jsonb not null default '[]'::jsonb,
  activite text, lieux text, avantages numeric, avantages_annee int, article_specifique text, remarque text,
  maj timestamptz not null default now(),
  primary key (saison, asso)
);
create table if not exists public.ft_conv_conventions(
  id bigserial primary key, saison int not null, asso text not null, modele_id bigint, modele_nom text,
  statut text not null default 'a_signer' check (statut in ('a_signer','signee','finalisee','annulee')),
  contenu text not null, empreinte text not null,
  envoyee_le timestamptz not null default now(), lu_le timestamptz,
  signataire text, signataire_qualite text, signataire_mail text, signature text,
  signe_le timestamptz, signe_ip text, signe_agent text,
  code_hash text, code_expire timestamptz, code_essais int not null default 0, code_mail text,
  final_nom text, final_contenu text, final_le timestamptz,
  annulee_le timestamptz, motif text, historique jsonb not null default '[]'::jsonb
);
create unique index if not exists ft_conv_conventions_active on public.ft_conv_conventions(saison, asso) where statut <> 'annulee';
create table if not exists public.ft_conv_demandes_compte(
  id bigserial primary key, infos jsonb not null, statut text not null default 'en_attente'
    check (statut in ('en_attente','acceptee','refusee')),
  cree timestamptz not null default now(), traite_le timestamptz, nom_compte text, message text
);
alter table public.ft_conv_fiches enable row level security;
alter table public.ft_conv_modeles enable row level security;
alter table public.ft_conv_saisons enable row level security;
alter table public.ft_conv_donnees enable row level security;
alter table public.ft_conv_conventions enable row level security;
alter table public.ft_conv_demandes_compte enable row level security;

-- ---------- Outils ----------
create or replace function app.ft_conv_hist(h jsonb, quoi text, qui text) returns jsonb
language sql stable set search_path to '' as $$
  select coalesce(h, '[]'::jsonb) || jsonb_build_array(jsonb_build_object('at', now(), 'quoi', quoi, 'qui', qui));
$$;
create or replace function app.ft_conv_ip() returns text language sql stable set search_path to '' as $$
  select left(btrim(split_part(coalesce(nullif(current_setting('request.headers', true), '')::json->>'x-forwarded-for', ''), ',', 1)), 60);
$$;
create or replace function app.ft_conv_agent() returns text language sql stable set search_path to '' as $$
  select left(coalesce(nullif(current_setting('request.headers', true), '')::json->>'user-agent', ''), 300);
$$;
-- Une association ne voit que la sienne ; l'administrateur voit tout
create or replace function app.ft_conv_droit(s app.sessions, p_asso text) returns void
language plpgsql stable set search_path to '' as $$
begin
  if s.role = 'admin' then return; end if;
  if s.role = 'asso' and app.norm(s.nom) = app.norm(p_asso) then return; end if;
  raise exception 'Accès refusé.' using errcode = '42501';
end $$;
create or replace function app.ft_conv_fiche_json(f public.ft_conv_fiches) returns jsonb
language sql stable set search_path to '' as $$
  select case when f.asso is null then null else jsonb_build_object(
    'asso', f.asso, 'nom_officiel', f.nom_officiel, 'siret', f.siret, 'forme', f.forme,
    'president', f.president, 'president_qualite', f.president_qualite, 'mail', f.mail, 'telephone', f.telephone,
    'date_ag', f.date_ag, 'siege', f.siege, 'activite', f.activite, 'federation', f.federation,
    'statuts_nom', f.statuts_nom, 'statuts_maj', f.statuts_maj, 'maj', f.maj, 'maj_par', f.maj_par) end;
$$;
create or replace function app.ft_conv_resume(c public.ft_conv_conventions) returns jsonb
language sql stable set search_path to '' as $$
  select jsonb_build_object('id', c.id, 'saison', c.saison, 'asso', c.asso, 'modele_id', c.modele_id, 'modele_nom', c.modele_nom,
    'statut', c.statut, 'envoyee_le', c.envoyee_le, 'lu_le', c.lu_le, 'signataire', c.signataire, 'signataire_qualite', c.signataire_qualite,
    'signe_le', c.signe_le, 'final_nom', c.final_nom, 'final_le', c.final_le, 'annulee_le', c.annulee_le, 'motif', c.motif,
    'code_envoye', c.code_expire is not null and c.code_expire > now());
$$;

-- ---------- Fiche association ----------
create or replace function public.ft_conv_ma_fiche(p_token text) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); f public.ft_conv_fiches;
begin
  perform app.exiger(s, array['asso']);
  select * into f from public.ft_conv_fiches where app.norm(asso) = app.norm(s.nom);
  return jsonb_build_object('asso', s.nom, 'fiche', app.ft_conv_fiche_json(f),
    'conventions', coalesce((select jsonb_agg(app.ft_conv_resume(c) order by c.saison desc, c.id desc)
       from public.ft_conv_conventions c where app.norm(c.asso) = app.norm(s.nom) and c.statut <> 'annulee'), '[]'::jsonb));
end $$;

create or replace function public.ft_conv_fiche_sauver(p_token text, p_asso text, p_fiche jsonb) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); a text; f public.ft_conv_fiches; siret text; d date;
  qui text;
begin
  a := case when s.role = 'asso' then s.nom else btrim(coalesce(p_asso, '')) end;
  perform app.ft_conv_droit(s, a);
  if a = '' or not app.ft_asso_existe(a) then raise exception 'Association inconnue.'; end if;
  siret := regexp_replace(coalesce(p_fiche->>'siret', ''), '\D', '', 'g');
  if siret <> '' and length(siret) <> 14 then raise exception 'Le n° SIRET doit comporter 14 chiffres.'; end if;
  if coalesce(p_fiche->>'mail', '') <> '' and (p_fiche->>'mail') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Adresse mail invalide.'; end if;
  begin d := nullif(p_fiche->>'date_ag', '')::date; exception when others then raise exception 'Date de la dernière AG invalide.'; end;
  if d > current_date then raise exception 'La date de la dernière AG ne peut pas être dans le futur.'; end if;
  qui := case when s.role = 'admin' then 'service des sports' else 'association' end;
  insert into public.ft_conv_fiches as x(asso, nom_officiel, siret, forme, president, president_qualite, mail, telephone, date_ag, siege, activite, federation, maj, maj_par)
  values (a, nullif(btrim(p_fiche->>'nom_officiel'), ''), nullif(siret, ''), coalesce(nullif(btrim(p_fiche->>'forme'), ''), 'Association loi 1901'),
          nullif(btrim(p_fiche->>'president'), ''), coalesce(nullif(btrim(p_fiche->>'president_qualite'), ''), 'Président(e)'),
          nullif(btrim(lower(p_fiche->>'mail')), ''), nullif(btrim(p_fiche->>'telephone'), ''), d,
          nullif(btrim(p_fiche->>'siege'), ''), nullif(btrim(p_fiche->>'activite'), ''), nullif(btrim(p_fiche->>'federation'), ''), now(), qui)
  on conflict (asso) do update set nom_officiel = excluded.nom_officiel, siret = excluded.siret, forme = excluded.forme,
    president = excluded.president, president_qualite = excluded.president_qualite, mail = excluded.mail, telephone = excluded.telephone,
    date_ag = excluded.date_ag, siege = excluded.siege, activite = excluded.activite, federation = excluded.federation, maj = now(), maj_par = qui
  returning * into f;
  return app.ft_conv_fiche_json(f);
end $$;

create or replace function public.ft_conv_statuts_deposer(p_token text, p_asso text, p_nom text, p_type text, p_contenu text) returns void
language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); a text;
begin
  a := case when s.role = 'asso' then s.nom else btrim(coalesce(p_asso, '')) end;
  perform app.ft_conv_droit(s, a);
  if coalesce(p_contenu, '') = '' then raise exception 'Fichier vide.'; end if;
  if length(p_contenu) > 11000000 then raise exception 'Fichier trop lourd (8 Mo maximum).'; end if;
  if not exists (select 1 from public.ft_conv_fiches where app.norm(asso) = app.norm(a)) then
    insert into public.ft_conv_fiches(asso, maj_par) values (a, case when s.role = 'admin' then 'service des sports' else 'association' end);
  end if;
  update public.ft_conv_fiches set statuts_nom = coalesce(nullif(btrim(p_nom), ''), 'statuts.pdf'), statuts_type = p_type,
    statuts_contenu = p_contenu, statuts_maj = now() where app.norm(asso) = app.norm(a);
end $$;

create or replace function public.ft_conv_statuts_lire(p_token text, p_asso text) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); a text; f public.ft_conv_fiches;
begin
  a := case when s.role = 'asso' then s.nom else p_asso end;
  perform app.ft_conv_droit(s, a);
  select * into f from public.ft_conv_fiches where app.norm(asso) = app.norm(a);
  if f.statuts_contenu is null then raise exception 'Aucun fichier de statuts.'; end if;
  return jsonb_build_object('nom', f.statuts_nom, 'type', f.statuts_type, 'contenu', f.statuts_contenu);
end $$;

-- ---------- Administration : chargement complet d'une saison ----------
create or replace function public.ft_conv_admin_charger(p_token text, p_saison int) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest');
begin
  perform app.exiger(s, array['admin']);
  return jsonb_build_object(
    'assos', app.ft_assos(),
    'params', coalesce((select params from public.ft_conv_saisons where saison = p_saison), '{}'::jsonb),
    'modeles', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nom', nom, 'contenu', contenu, 'ordre', ordre, 'maj', maj) order by ordre, id)
                         from public.ft_conv_modeles where not supprime), '[]'::jsonb),
    'fiches', coalesce((select jsonb_agg(app.ft_conv_fiche_json(f)) from public.ft_conv_fiches f), '[]'::jsonb),
    'donnees', coalesce((select jsonb_agg(to_jsonb(d) - 'saison') from public.ft_conv_donnees d where d.saison = p_saison), '[]'::jsonb),
    'conventions', coalesce((select jsonb_agg(app.ft_conv_resume(c) order by c.id) from public.ft_conv_conventions c
                             where c.saison = p_saison and c.statut <> 'annulee'), '[]'::jsonb),
    'demandes', (select count(*) from public.ft_conv_demandes_compte where statut = 'en_attente'));
end $$;

create or replace function public.ft_conv_params_sauver(p_token text, p_saison int, p_params jsonb) returns void
language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest');
begin
  perform app.exiger(s, array['admin']);
  if jsonb_typeof(p_params) <> 'object' then raise exception 'Paramètres invalides.'; end if;
  insert into public.ft_conv_saisons(saison, params, maj) values (p_saison, p_params, now())
  on conflict (saison) do update set params = excluded.params, maj = now();
end $$;

create or replace function public.ft_conv_modele_sauver(p_token text, p_modele jsonb) returns bigint
language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); i bigint := nullif(p_modele->>'id', '')::bigint;
  n text := btrim(coalesce(p_modele->>'nom', ''));
begin
  perform app.exiger(s, array['admin']);
  if n = '' then raise exception 'Donnez un nom au modèle.'; end if;
  if length(coalesce(p_modele->>'contenu', '')) > 3000000 then raise exception 'Modèle trop lourd (images ?).'; end if;
  if i is null then
    insert into public.ft_conv_modeles(nom, contenu, ordre) values (n, coalesce(p_modele->>'contenu', ''),
      coalesce((select max(ordre) + 1 from public.ft_conv_modeles), 1)) returning id into i;
  else
    update public.ft_conv_modeles set nom = n, contenu = coalesce(p_modele->>'contenu', contenu), maj = now() where id = i and not supprime;
    if not found then raise exception 'Modèle introuvable.'; end if;
  end if;
  return i;
end $$;

create or replace function public.ft_conv_modele_supprimer(p_token text, p_id bigint) returns void
language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest');
begin
  perform app.exiger(s, array['admin']);
  update public.ft_conv_modeles set supprime = true, maj = now() where id = p_id;
  update public.ft_conv_donnees set modele_id = null where modele_id = p_id;
end $$;

-- Une ligne du tableau (les champs absents ne sont pas modifiés)
create or replace function public.ft_conv_donnees_sauver(p_token text, p_saison int, p_asso text, p_d jsonb) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); d public.ft_conv_donnees;
  num numeric; nm text;
begin
  perform app.exiger(s, array['admin']);
  if not app.ft_asso_existe(p_asso) then raise exception 'Association inconnue.'; end if;
  insert into public.ft_conv_donnees(saison, asso) values (p_saison, p_asso) on conflict do nothing;
  select * into d from public.ft_conv_donnees where saison = p_saison and asso = p_asso;
  if p_d ? 'concernee' then d.concernee := coalesce((p_d->>'concernee')::boolean, true); end if;
  if p_d ? 'modele_id' then d.modele_id := nullif(p_d->>'modele_id', '')::bigint; end if;
  if p_d ? 'afficher_subvention' then d.afficher_subvention := coalesce((p_d->>'afficher_subvention')::boolean, true); end if;
  foreach nm in array array['montant_global','avantages'] loop
    if p_d ? nm then
      begin num := nullif(replace(replace(p_d->>nm, ' ', ''), ',', '.'), '')::numeric;
      exception when others then raise exception 'Montant invalide : %', p_d->>nm; end;
      if nm = 'montant_global' then d.montant_global := num; else d.avantages := num; end if;
    end if;
  end loop;
  if p_d ? 'versements' then d.versements := case when jsonb_typeof(p_d->'versements') = 'array' then p_d->'versements' else '[]'::jsonb end; end if;
  if p_d ? 'autres_aides' then d.autres_aides := case when jsonb_typeof(p_d->'autres_aides') = 'array' then p_d->'autres_aides' else '[]'::jsonb end; end if;
  if p_d ? 'avantages_annee' then d.avantages_annee := nullif(p_d->>'avantages_annee', '')::int; end if;
  if p_d ? 'activite' then d.activite := nullif(btrim(p_d->>'activite'), ''); end if;
  if p_d ? 'lieux' then d.lieux := nullif(btrim(p_d->>'lieux'), ''); end if;
  if p_d ? 'article_specifique' then d.article_specifique := nullif(btrim(p_d->>'article_specifique'), ''); end if;
  if p_d ? 'remarque' then d.remarque := nullif(btrim(p_d->>'remarque'), ''); end if;
  update public.ft_conv_donnees set concernee = d.concernee, modele_id = d.modele_id, afficher_subvention = d.afficher_subvention,
    montant_global = d.montant_global, versements = d.versements, autres_aides = d.autres_aides, activite = d.activite, lieux = d.lieux,
    avantages = d.avantages, avantages_annee = d.avantages_annee, article_specifique = d.article_specifique, remarque = d.remarque, maj = now()
  where saison = p_saison and asso = p_asso returning * into d;
  return to_jsonb(d) - 'saison';
end $$;

-- Même réglage pour plusieurs associations (modèle, concernée, affichage de la subvention)
create or replace function public.ft_conv_donnees_groupe(p_token text, p_saison int, p_assos text[], p_d jsonb) returns int
language plpgsql security definer set search_path to '' as $$
declare a text; n int := 0;
begin
  perform app.exiger(app.session(p_token, 'fusiontest'), array['admin']);
  foreach a in array coalesce(p_assos, '{}') loop
    perform public.ft_conv_donnees_sauver(p_token, p_saison, a, p_d - 'versements' - 'autres_aides' - 'montant_global');
    n := n + 1;
  end loop;
  return n;
end $$;

-- Reprend les lignes d'une autre saison (lieux, activité, modèle, article spécifique) — les montants restent à saisir
create or replace function public.ft_conv_reprendre(p_token text, p_de int, p_vers int) returns int
language plpgsql security definer set search_path to '' as $$
declare n int;
begin
  perform app.exiger(app.session(p_token, 'fusiontest'), array['admin']);
  insert into public.ft_conv_donnees(saison, asso, concernee, modele_id, afficher_subvention, activite, lieux, article_specifique)
  select p_vers, asso, concernee, modele_id, afficher_subvention, activite, lieux, article_specifique
    from public.ft_conv_donnees where saison = p_de
  on conflict (saison, asso) do nothing;
  get diagnostics n = row_count;
  insert into public.ft_conv_saisons(saison, params)
  select p_vers, params - 'deliberation' - 'date_debut' - 'date_fin' - 'annee_subvention' - 'annee_avantages' from public.ft_conv_saisons where saison = p_de
  on conflict (saison) do nothing;
  return n;
end $$;

-- ---------- Envoi d'une convention à signer ----------
create or replace function public.ft_conv_envoyer(p_token text, p_saison int, p_asso text, p_modele bigint, p_contenu text, p_remplacer boolean default false) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); c public.ft_conv_conventions; f public.ft_conv_fiches; mn text;
begin
  perform app.exiger(s, array['admin']);
  if not app.ft_asso_existe(p_asso) then raise exception 'Association inconnue.'; end if;
  if coalesce(p_contenu, '') = '' then raise exception 'Convention vide.'; end if;
  select * into f from public.ft_conv_fiches where app.norm(asso) = app.norm(p_asso);
  if f.mail is null then raise exception '% : pas d''adresse mail dans la fiche de l''association.', p_asso; end if;
  select * into c from public.ft_conv_conventions where saison = p_saison and app.norm(asso) = app.norm(p_asso) and statut <> 'annulee';
  if found then
    if c.statut in ('signee','finalisee') and not p_remplacer then
      raise exception '% : la convention est déjà signée. Cochez « remplacer » pour en envoyer une nouvelle.', p_asso;
    end if;
    update public.ft_conv_conventions set statut = 'annulee', annulee_le = now(), motif = 'Remplacée par une nouvelle version',
      historique = app.ft_conv_hist(historique, 'annulée (nouvelle version envoyée)', 'service des sports') where id = c.id;
  end if;
  select nom into mn from public.ft_conv_modeles where id = p_modele;
  insert into public.ft_conv_conventions(saison, asso, modele_id, modele_nom, contenu, empreinte, historique)
  values (p_saison, p_asso, p_modele, mn, p_contenu, encode(extensions.digest(convert_to(p_contenu, 'UTF8'), 'sha256'), 'hex'),
          app.ft_conv_hist('[]'::jsonb, 'envoyée pour signature', 'service des sports'))
  returning * into c;
  return app.ft_conv_resume(c);
end $$;

create or replace function public.ft_conv_annuler(p_token text, p_id bigint, p_motif text) returns void
language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest');
begin
  perform app.exiger(s, array['admin']);
  update public.ft_conv_conventions set statut = 'annulee', annulee_le = now(), motif = nullif(btrim(p_motif), ''),
    historique = app.ft_conv_hist(historique, 'annulée', 'service des sports') where id = p_id and statut <> 'annulee';
  if not found then raise exception 'Convention introuvable.'; end if;
end $$;

-- Convention complète (texte, signature, preuve)
create or replace function public.ft_conv_lire(p_token text, p_id bigint) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); c public.ft_conv_conventions;
begin
  select * into c from public.ft_conv_conventions where id = p_id;
  if not found then raise exception 'Convention introuvable.'; end if;
  perform app.ft_conv_droit(s, c.asso);
  if s.role = 'asso' and c.statut = 'annulee' then raise exception 'Cette convention a été annulée.'; end if;
  if s.role = 'asso' and c.lu_le is null then
    update public.ft_conv_conventions set lu_le = now(), historique = app.ft_conv_hist(historique, 'ouverte par l''association', 'association')
     where id = p_id returning * into c;
  end if;
  return app.ft_conv_resume(c) || jsonb_build_object('contenu', c.contenu, 'empreinte', c.empreinte, 'signature', c.signature,
    'signataire_mail', c.signataire_mail, 'signe_ip', c.signe_ip, 'signe_agent', c.signe_agent, 'historique', c.historique,
    'mail_code', case when c.code_mail is null then null else regexp_replace(c.code_mail, '^(.).*(@.*)$', '\1•••\2') end,
    'mail_fiche', case when s.role = 'admin' then (select mail from public.ft_conv_fiches where app.norm(asso) = app.norm(c.asso)) end);
end $$;

-- Signature par l'association : code reçu par mail + signature tracée
create or replace function public.ft_conv_signer(p_token text, p_id bigint, p_code text, p_signataire text, p_qualite text, p_signature text, p_empreinte text) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); c public.ft_conv_conventions;
begin
  perform app.exiger(s, array['asso']);
  select * into c from public.ft_conv_conventions where id = p_id for update;
  if not found then raise exception 'Convention introuvable.'; end if;
  perform app.ft_conv_droit(s, c.asso);
  if c.statut <> 'a_signer' then raise exception 'Cette convention n''est pas (ou plus) à signer.'; end if;
  if btrim(coalesce(p_signataire, '')) = '' then raise exception 'Indiquez le nom du signataire.'; end if;
  if coalesce(p_signature, '') !~ '^data:image/png;base64,' or length(p_signature) > 400000 then raise exception 'Signature manquante.'; end if;
  if p_empreinte is distinct from c.empreinte then raise exception 'Le texte de la convention a changé : rechargez la page.'; end if;
  if c.code_hash is null or c.code_expire < now() then raise exception 'Code expiré : demandez un nouveau code.'; end if;
  if c.code_essais >= 5 then raise exception 'Trop d''essais : demandez un nouveau code.'; end if;
  if c.code_hash <> encode(extensions.digest(convert_to(c.id || ':' || btrim(coalesce(p_code, '')), 'UTF8'), 'sha256'), 'hex') then
    update public.ft_conv_conventions set code_essais = code_essais + 1 where id = p_id;
    return jsonb_build_object('erreur', 'Code incorrect (' || (4 - c.code_essais) || ' essai(s) restant(s)).');
  end if;
  update public.ft_conv_conventions set statut = 'signee', signataire = btrim(p_signataire), signataire_qualite = nullif(btrim(p_qualite), ''),
    signataire_mail = c.code_mail, signature = p_signature, signe_le = now(), signe_ip = app.ft_conv_ip(), signe_agent = app.ft_conv_agent(),
    code_hash = null, code_expire = null,
    historique = app.ft_conv_hist(historique, 'signée par ' || btrim(p_signataire) || ' (code vérifié envoyé à ' || coalesce(c.code_mail, '?') || ')', 'association')
  where id = p_id returning * into c;
  return app.ft_conv_resume(c);
end $$;

-- Retour d'i-parapheur : la convention signée par le Maire
create or replace function public.ft_conv_final_deposer(p_token text, p_id bigint, p_nom text, p_contenu text) returns void
language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest');
begin
  perform app.exiger(s, array['admin']);
  if coalesce(p_contenu, '') = '' then raise exception 'Fichier vide.'; end if;
  if length(p_contenu) > 14000000 then raise exception 'Fichier trop lourd (10 Mo maximum).'; end if;
  update public.ft_conv_conventions set statut = 'finalisee', final_nom = coalesce(nullif(btrim(p_nom), ''), 'convention.pdf'),
    final_contenu = p_contenu, final_le = now(), historique = app.ft_conv_hist(historique, 'convention signée par le Maire déposée', 'service des sports')
  where id = p_id and statut in ('signee','finalisee');
  if not found then raise exception 'La convention doit d''abord être signée par l''association.'; end if;
end $$;

create or replace function public.ft_conv_final_lire(p_token text, p_id bigint) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); c public.ft_conv_conventions;
begin
  select * into c from public.ft_conv_conventions where id = p_id;
  if not found or c.final_contenu is null then raise exception 'Document introuvable.'; end if;
  perform app.ft_conv_droit(s, c.asso);
  return jsonb_build_object('nom', c.final_nom, 'contenu', c.final_contenu);
end $$;

-- ---------- Demandes de compte association ----------
create or replace function public.ft_conv_demande_compte(p_infos jsonb) returns bigint
language plpgsql security definer set search_path to '' as $$
declare i bigint; m text := lower(btrim(coalesce(p_infos->>'mail', ''))); n text := btrim(coalesce(p_infos->>'nom_officiel', ''));
begin
  if n = '' then raise exception 'Indiquez le nom de l''association.'; end if;
  if m !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Adresse mail invalide.'; end if;
  if length(regexp_replace(coalesce(p_infos->>'siret', ''), '\D', '', 'g')) <> 14 then raise exception 'Le n° SIRET doit comporter 14 chiffres.'; end if;
  if (select count(*) from public.ft_conv_demandes_compte where cree > now() - interval '1 hour') >= 20
     or exists (select 1 from public.ft_conv_demandes_compte where lower(infos->>'mail') = m and statut = 'en_attente') then
    raise exception 'Une demande est déjà en attente pour cette adresse.';
  end if;
  insert into public.ft_conv_demandes_compte(infos) values (jsonb_strip_nulls(jsonb_build_object(
    'nom_officiel', left(n, 200), 'nom_court', left(btrim(p_infos->>'nom_court'), 80), 'siret', regexp_replace(p_infos->>'siret', '\D', '', 'g'),
    'forme', left(btrim(p_infos->>'forme'), 120), 'president', left(btrim(p_infos->>'president'), 150), 'president_qualite', left(btrim(p_infos->>'president_qualite'), 80),
    'mail', m, 'telephone', left(btrim(p_infos->>'telephone'), 30), 'date_ag', nullif(p_infos->>'date_ag', ''), 'siege', left(btrim(p_infos->>'siege'), 300),
    'activite', left(btrim(p_infos->>'activite'), 150), 'federation', left(btrim(p_infos->>'federation'), 200), 'message', left(btrim(p_infos->>'message'), 1000))))
  returning id into i;
  return i;
end $$;

create or replace function public.ft_conv_demandes_liste(p_token text) returns jsonb
language plpgsql security definer set search_path to '' as $$
begin
  perform app.exiger(app.session(p_token, 'fusiontest'), array['admin']);
  return coalesce((select jsonb_agg(to_jsonb(d) order by (d.statut = 'en_attente') desc, d.cree desc)
    from public.ft_conv_demandes_compte d where d.statut = 'en_attente' or d.traite_le > now() - interval '6 months'), '[]'::jsonb);
end $$;

create or replace function public.ft_conv_demande_traiter(p_token text, p_id bigint, p_action text, p_nom text, p_message text) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); d public.ft_conv_demandes_compte;
  n text := btrim(regexp_replace(coalesce(p_nom, ''), '\s+', ' ', 'g'));
begin
  perform app.exiger(s, array['admin']);
  select * into d from public.ft_conv_demandes_compte where id = p_id and statut = 'en_attente' for update;
  if not found then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  if p_action = 'refuser' then
    update public.ft_conv_demandes_compte set statut = 'refusee', traite_le = now(), message = nullif(btrim(p_message), '') where id = p_id;
    return jsonb_build_object('ok', true);
  end if;
  if p_action <> 'accepter' then raise exception 'Action inconnue.'; end if;
  if n = '' then raise exception 'Choisissez le nom du compte.'; end if;
  if not app.ft_asso_existe(n) then perform public.ft_asso_ajouter(p_token, n); end if;
  insert into public.ft_conv_fiches(asso, nom_officiel, siret, forme, president, president_qualite, mail, telephone, date_ag, siege, activite, federation, maj_par)
  values (n, d.infos->>'nom_officiel', d.infos->>'siret', coalesce(d.infos->>'forme', 'Association loi 1901'), d.infos->>'president',
    coalesce(d.infos->>'president_qualite', 'Président(e)'), d.infos->>'mail', d.infos->>'telephone', nullif(d.infos->>'date_ag', '')::date,
    d.infos->>'siege', d.infos->>'activite', d.infos->>'federation', 'association')
  on conflict (asso) do nothing;
  update public.ft_conv_demandes_compte set statut = 'acceptee', traite_le = now(), nom_compte = n, message = nullif(btrim(p_message), '') where id = p_id;
  return jsonb_build_object('ok', true, 'nom', n);
end $$;

-- ---------- Mails (appelé uniquement par la fonction fusiontest-conv-mail) ----------
--   a_signer  → association (adresse de la fiche)       : admin
--   code      → association (adresse de la fiche)       : association connectée ; renvoie le code à 6 chiffres
--   signee    → association + service des sports        : association connectée, juste après la signature
--   demande   → service des sports                      : sans session, dans les 10 minutes qui suivent la demande
--   reponse   → demandeur                               : admin, après acceptation ou refus
create or replace function public.ft_conv_mail_preparer(p_token text, p_id bigint, p_evt text) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare s app.sessions; c public.ft_conv_conventions; f public.ft_conv_fiches; d public.ft_conv_demandes_compte;
  service text; code text; lid bigint; cle text := 'conv-' || p_evt || '-' || p_id;
begin
  if not app.ft_est_serveur() then raise exception 'Réservé au serveur.'; end if;
  service := coalesce(nullif(btrim((select valeur from public.ft_reglages where cle = 'mail_dest')), ''), 'sports@ville-corbas.fr');
  if p_evt in ('demande','reponse') then
    select * into d from public.ft_conv_demandes_compte where id = p_id;
    if not found then raise exception 'Demande introuvable.'; end if;
    if p_evt = 'demande' then
      if d.cree < now() - interval '10 minutes' then raise exception 'Délai dépassé.'; end if;
      if exists (select 1 from public.ft_mails where demande_id = cle) then return jsonb_build_object('deja', true); end if;
      insert into public.ft_mails(demande_id, association, destinataire) values (cle, d.infos->>'nom_officiel', service) returning id into lid;
      return jsonb_build_object('log', lid, 'dest', jsonb_build_array(service), 'demande', to_jsonb(d));
    end if;
    s := app.session(p_token, 'fusiontest'); perform app.exiger(s, array['admin']);
    if d.statut = 'en_attente' then raise exception 'Demande non traitée.'; end if;
    if exists (select 1 from public.ft_mails where demande_id = cle) then return jsonb_build_object('deja', true); end if;
    insert into public.ft_mails(demande_id, association, destinataire) values (cle, d.infos->>'nom_officiel', d.infos->>'mail') returning id into lid;
    return jsonb_build_object('log', lid, 'dest', jsonb_build_array(d.infos->>'mail'), 'demande', to_jsonb(d));
  end if;

  s := app.session(p_token, 'fusiontest');
  select * into c from public.ft_conv_conventions where id = p_id;
  if not found then raise exception 'Convention introuvable.'; end if;
  perform app.ft_conv_droit(s, c.asso);
  select * into f from public.ft_conv_fiches where app.norm(asso) = app.norm(c.asso);
  if f.mail is null then raise exception 'Pas d''adresse mail dans la fiche de l''association.'; end if;
  if p_evt = 'a_signer' then
    perform app.exiger(s, array['admin']);
    if c.statut <> 'a_signer' then raise exception 'Convention non envoyée.'; end if;
    insert into public.ft_mails(saison, demande_id, association, destinataire) values (c.saison, cle, c.asso, f.mail) returning id into lid;
    return jsonb_build_object('log', lid, 'dest', jsonb_build_array(f.mail), 'conv', app.ft_conv_resume(c), 'fiche', app.ft_conv_fiche_json(f));
  elsif p_evt = 'code' then
    perform app.exiger(s, array['asso']);
    if c.statut <> 'a_signer' then raise exception 'Cette convention n''est pas à signer.'; end if;
    if c.code_expire is not null and c.code_expire > now() + interval '14 minutes' then raise exception 'Un code vient d''être envoyé : patientez une minute.'; end if;
    if (select count(*) from public.ft_mails where demande_id = cle and at > now() - interval '1 hour') >= 5 then raise exception 'Trop de codes demandés : réessayez dans une heure.'; end if;
    code := lpad((abs(('x' || encode(extensions.gen_random_bytes(7), 'hex'))::bit(56)::bigint) % 1000000)::text, 6, '0');
    update public.ft_conv_conventions set code_hash = encode(extensions.digest(convert_to(c.id || ':' || code, 'UTF8'), 'sha256'), 'hex'),
      code_expire = now() + interval '15 minutes', code_essais = 0, code_mail = f.mail where id = c.id;
    insert into public.ft_mails(saison, demande_id, association, destinataire) values (c.saison, cle, c.asso, f.mail) returning id into lid;
    return jsonb_build_object('log', lid, 'dest', jsonb_build_array(f.mail), 'code', code, 'conv', app.ft_conv_resume(c), 'fiche', app.ft_conv_fiche_json(f));
  elsif p_evt = 'signee' then
    if c.statut <> 'signee' or c.signe_le < now() - interval '1 hour' then raise exception 'Convention non signée.'; end if;
    if exists (select 1 from public.ft_mails where demande_id = cle) then return jsonb_build_object('deja', true); end if;
    insert into public.ft_mails(saison, demande_id, association, destinataire) values (c.saison, cle, c.asso, f.mail || ', ' || service) returning id into lid;
    return jsonb_build_object('log', lid, 'dest', jsonb_build_array(f.mail, service), 'conv', app.ft_conv_resume(c), 'fiche', app.ft_conv_fiche_json(f), 'empreinte', c.empreinte, 'ip', c.signe_ip);
  end if;
  raise exception 'Évènement inconnu.';
end $$;

-- Outil de remplacement ciblé dans une fonction existante
create or replace function app.ft_patch(p_fn regprocedure, p_old text, p_new text) returns void
language plpgsql set search_path to '' as $$
declare d text := pg_get_functiondef(p_fn); n text;
begin
  if position(p_old in d) = 0 then raise exception 'Patch introuvable dans % : %', p_fn, left(p_old, 80); end if;
  n := replace(d, p_old, p_new);
  execute n;
end $$;

-- ---------- Renommer / supprimer une association : suivre dans les conventions ----------
select app.ft_patch('public.ft_asso_renommer(text,text,text)',
  $o$  if app.norm(p_ancien) <> app.norm(cible) then
    ca := app.ft_compte('asso', p_ancien);$o$,
  $n$  update public.ft_conv_fiches set asso = cible where app.norm(asso) = app.norm(p_ancien)
     and not exists (select 1 from public.ft_conv_fiches x where app.norm(x.asso) = app.norm(cible) and app.norm(x.asso) <> app.norm(p_ancien));
  update public.ft_conv_donnees d set asso = cible where app.norm(d.asso) = app.norm(p_ancien)
     and not exists (select 1 from public.ft_conv_donnees x where x.saison = d.saison and app.norm(x.asso) = app.norm(cible) and app.norm(x.asso) <> app.norm(p_ancien));
  update public.ft_conv_conventions c set asso = cible where app.norm(c.asso) = app.norm(p_ancien)
     and (c.statut = 'annulee' or not exists (select 1 from public.ft_conv_conventions x where x.saison = c.saison and x.statut <> 'annulee' and app.norm(x.asso) = app.norm(cible) and app.norm(x.asso) <> app.norm(p_ancien)));
  if app.norm(p_ancien) <> app.norm(cible) then
    ca := app.ft_compte('asso', p_ancien);$n$);

revoke all on function public.ft_conv_mail_preparer(text,bigint,text) from public, anon, authenticated;
grant execute on function public.ft_conv_mail_preparer(text,bigint,text) to service_role;
