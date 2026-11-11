-- =====================================================================
-- SITE TEST — Réservation des salles municipales (étape 3)
-- Tables ft_salles, ft_resa_profils, ft_resa_docs, ft_reservations,
-- ft_resa_pieces, ft_salle_blocages. Accès uniquement par fonctions
-- (RLS activé, aucune politique : rien n'est lisible directement).
-- Appliqué dans Supabase par les migrations ft_salles_tables, ft_salles_fonctions_internes,
-- ft_salles_fonctions_reglages, ft_salles_fonctions_reservations et ft_reglage_mail_resa.
-- =====================================================================

-- ---------- Tables ----------
create table if not exists public.ft_salles (
  id bigserial primary key,
  nom text not null,
  adresse text,
  capacite text,
  descriptif text,
  youtube text,
  photo text,                                   -- image (data URL JPEG compressée)
  periodes text[] not null default array['matin','apres_midi','soir','journee'],
  enchainement jsonb not null default '{}'::jsonb, -- {"5":{"soir":false,"lendemain":true}} (0 = dimanche)
  conditions jsonb not null default '{}'::jsonb,   -- {"asso":{...},"entreprise":{...},"particulier":{...}}
  ordre int not null default 0,
  actif boolean not null default true,
  supprime boolean not null default false,
  maj timestamptz not null default now()
);

create table if not exists public.ft_resa_profils (
  profil text primary key check (profil in ('asso','entreprise','particulier')),
  ouvert boolean not null default false,
  limite_mode text not null default 'aucune' check (limite_mode in ('aucune','fixe','glissant')),
  limite_date date,
  limite_jours int,
  delai_paiement int not null default 15,
  natures jsonb not null default '[]'::jsonb,     -- [{code,libelle,tarif,pieces:[],precision}]
  maj timestamptz not null default now()
);

create table if not exists public.ft_resa_docs (
  cle text primary key,                           -- profil|nature
  nom text, type text, taille int, contenu text,
  maj timestamptz not null default now()
);

create table if not exists public.ft_reservations (
  id bigserial primary key,
  salle_id bigint not null references public.ft_salles(id),
  profil text not null,
  demandeur text not null,                        -- nom de l'association ou id du compte usager
  demandeur_nom text not null,
  contact_mail text,
  contact_tel text,
  date date not null,
  periode text not null check (periode in ('matin','apres_midi','soir','journee','weekend')),
  nature text not null,
  nature_libelle text not null,
  precision_nature text,
  nb_personnes int,
  remarque text,
  tarif numeric,
  statut text not null default 'demande'
    check (statut in ('demande','pieces','option','reservee','refusee','annulee','expiree')),
  message text,
  echeance date,
  historique jsonb not null default '[]'::jsonb,
  cree timestamptz not null default now(),
  maj timestamptz not null default now()
);
create index if not exists ft_reservations_salle_date on public.ft_reservations(salle_id, date);
create index if not exists ft_reservations_demandeur on public.ft_reservations(profil, demandeur);

create table if not exists public.ft_resa_pieces (
  id bigserial primary key,
  resa_id bigint not null references public.ft_reservations(id) on delete cascade,
  libelle text not null,
  nom text, type text, taille int, contenu text not null,
  cree timestamptz not null default now()
);
create index if not exists ft_resa_pieces_resa on public.ft_resa_pieces(resa_id);

create table if not exists public.ft_salle_blocages (
  id bigserial primary key,
  salle_id bigint references public.ft_salles(id),    -- null = toutes les salles
  date_debut date not null,
  date_fin date not null,
  creneaux text[] not null default array['matin','apres_midi','soir'],
  profils text[] not null default array['asso','entreprise','particulier'],
  motif text,
  cree timestamptz not null default now()
);

alter table public.ft_salles enable row level security;
alter table public.ft_resa_profils enable row level security;
alter table public.ft_resa_docs enable row level security;
alter table public.ft_reservations enable row level security;
alter table public.ft_resa_pieces enable row level security;
alter table public.ft_salle_blocages enable row level security;
revoke all on public.ft_salles, public.ft_resa_profils, public.ft_resa_docs, public.ft_reservations,
  public.ft_resa_pieces, public.ft_salle_blocages from anon, authenticated;

-- ---------- Réglages par défaut ----------
insert into public.ft_resa_profils(profil, ouvert, delai_paiement, natures) values
 ('asso', true, 15, '[
   {"code":"festif","libelle":"Moment festif","tarif":null,"pieces":["Attestation d''assurance"],"precision":false},
   {"code":"ag","libelle":"Assemblée générale","tarif":0,"pieces":["Attestation d''assurance"],"precision":false},
   {"code":"vente","libelle":"Vente de marchandises","tarif":null,"pieces":["Attestation d''assurance"],"precision":false},
   {"code":"reunion","libelle":"Réunion","tarif":0,"pieces":["Attestation d''assurance"],"precision":false}]'),
 ('entreprise', true, 15, '[
   {"code":"ag","libelle":"Assemblée générale","tarif":null,"pieces":["Attestation d''assurance"],"precision":false},
   {"code":"vente","libelle":"Vente de marchandises","tarif":null,"pieces":["Attestation d''assurance"],"precision":false},
   {"code":"reunion","libelle":"Réunion","tarif":null,"pieces":["Attestation d''assurance"],"precision":false}]'),
 ('particulier', true, 15, '[
   {"code":"anniversaire","libelle":"Anniversaire","tarif":null,"pieces":["Justificatif de domicile","Attestation d''assurance"],"precision":false},
   {"code":"mariage","libelle":"Mariage","tarif":null,"pieces":["Justificatif de domicile","Attestation d''assurance"],"precision":false},
   {"code":"bapteme","libelle":"Baptême","tarif":null,"pieces":["Justificatif de domicile","Attestation d''assurance"],"precision":false},
   {"code":"autre","libelle":"Autre","tarif":null,"pieces":["Justificatif de domicile","Attestation d''assurance"],"precision":true}]')
on conflict (profil) do nothing;

-- ---------- Fonctions internes ----------
create or replace function app.ft_resa_session(p_token text)
returns app.sessions language plpgsql set search_path = '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest');
begin
  perform app.exiger(s, array['admin','asso','entreprise','particulier']);
  if s.role in ('entreprise','particulier') then perform app.ft_session_usager(p_token); end if;
  return s;
end $$;

-- Créneaux (date, matin / après-midi / soir) occupés par une période
create or replace function app.ft_resa_slots(p_date date, p_periode text)
returns table(d date, s text) language sql immutable set search_path = '' as $$
  select p_date, x from unnest(case p_periode when 'matin' then array['matin'] when 'apres_midi' then array['apres_midi']
    when 'soir' then array['soir'] else array['matin','apres_midi','soir'] end) x
  union all
  select p_date + 1, x from unnest(case when p_periode = 'weekend' then array['matin','apres_midi','soir'] else array[]::text[] end) x;
$$;

create or replace function app.ft_resa_limite(p public.ft_resa_profils)
returns date language sql stable set search_path = '' as $$
  select case p.limite_mode when 'fixe' then p.limite_date
    when 'glissant' then (now() at time zone 'Europe/Paris')::date + coalesce(p.limite_jours, 0) else null end;
$$;

-- Les options non payées dans le délai sont annulées (contrôle à chaque consultation)
create or replace function app.ft_resa_expirer()
returns void language sql set search_path = '' as $$
  update public.ft_reservations set statut = 'expiree', maj = now(),
    historique = historique || jsonb_build_array(jsonb_build_object('at', now(), 'par', 'automatique', 'action', 'expiree',
      'message', 'Délai de paiement dépassé : réservation annulée.'))
  where statut = 'option' and echeance is not null and echeance < (now() at time zone 'Europe/Paris')::date;
$$;

-- Occupation d'une salle : réservations, blocages (pour ce profil, ou tous si null) et règles d'enchaînement.
-- prio : 1 réservation, 2 blocage, 3 règle d'enchaînement
create or replace function app.ft_salle_occupation(p_salle bigint, p_debut date, p_fin date, p_profil text)
returns table(d date, s text, e text, resa_id bigint, profil text, demandeur text, nom text, motif text, prio int)
language sql stable set search_path = '' as $$
  with occ as (
    select sl.d, sl.s, r.id, r.statut, r.profil, r.demandeur, r.demandeur_nom, r.nature_libelle
    from public.ft_reservations r cross join lateral app.ft_resa_slots(r.date, r.periode) sl
    where r.salle_id = p_salle and r.statut in ('demande','pieces','option','reservee')
      and r.date between p_debut - 2 and p_fin + 1
  ), regle as (select enchainement from public.ft_salles where id = p_salle)
  select o.d, o.s, case when o.statut in ('demande','pieces') then 'demande' when o.statut = 'option' then 'option' else 'reserve' end,
         o.id, o.profil, o.demandeur, o.demandeur_nom, o.nature_libelle, 1
  from occ o where o.d between p_debut and p_fin
  union all
  select g::date, c, 'bloque', null::bigint, null, null, null, coalesce(b.motif, 'Bloqué'), 2
  from public.ft_salle_blocages b
  cross join lateral generate_series(greatest(b.date_debut, p_debut), least(b.date_fin, p_fin), interval '1 day') g
  cross join lateral unnest(b.creneaux) c
  where (b.salle_id is null or b.salle_id = p_salle) and b.date_fin >= p_debut and b.date_debut <= p_fin
    and (p_profil is null or p_profil = any(b.profils))
  union all
  -- soir bloqué après une réservation du matin ou de l'après-midi, selon le jour
  select distinct o.d, 'soir', 'bloque', o.id, o.profil, o.demandeur, o.demandeur_nom, 'Règle d''enchaînement', 3
  from occ o, regle
  where o.s in ('matin','apres_midi') and o.d between p_debut and p_fin
    and coalesce((regle.enchainement -> (extract(dow from o.d)::int)::text ->> 'soir')::boolean, false)
  union all
  -- lendemain matin bloqué après une réservation du soir, selon le jour
  select distinct o.d + 1, 'matin', 'bloque', o.id, o.profil, o.demandeur, o.demandeur_nom, 'Règle d''enchaînement', 3
  from occ o, regle
  where o.s = 'soir' and o.d + 1 between p_debut and p_fin
    and coalesce((regle.enchainement -> (extract(dow from o.d)::int)::text ->> 'lendemain')::boolean, false);
$$;

create or replace function app.ft_resa_hist(p_par text, p_action text, p_message text)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_array(jsonb_build_object('at', now(), 'par', p_par, 'action', p_action, 'message', nullif(btrim(coalesce(p_message,'')),'')));
$$;

create or replace function app.ft_resa_json(r public.ft_reservations, p_admin boolean)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('id', r.id, 'salle_id', r.salle_id,
    'salle', (select nom from public.ft_salles where id = r.salle_id),
    'profil', r.profil, 'demandeur_nom', r.demandeur_nom, 'contact_mail', r.contact_mail, 'contact_tel', r.contact_tel,
    'date', r.date, 'periode', r.periode, 'nature', r.nature, 'nature_libelle', r.nature_libelle,
    'precision', r.precision_nature, 'nb_personnes', r.nb_personnes, 'remarque', r.remarque, 'tarif', r.tarif,
    'statut', r.statut, 'message', r.message, 'echeance', r.echeance,
    'cree', r.cree, 'maj', r.maj, 'historique', r.historique,
    'pieces', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'libelle', p.libelle, 'nom', p.nom, 'taille', p.taille, 'cree', p.cree) order by p.id)
                        from public.ft_resa_pieces p where p.resa_id = r.id), '[]'::jsonb));
$$;

-- ---------- Infos de réservation (profil connecté, ou les trois pour l'administrateur) ----------
create or replace function public.ft_resa_infos(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.ft_resa_session(p_token); res jsonb := '{}'::jsonb; p public.ft_resa_profils;
begin
  for p in select * from public.ft_resa_profils where s.role = 'admin' or profil = s.role loop
    res := res || jsonb_build_object(p.profil, jsonb_build_object(
      'ouvert', p.ouvert, 'limite_mode', p.limite_mode, 'limite_date', p.limite_date, 'limite_jours', p.limite_jours,
      'limite', app.ft_resa_limite(p), 'delai_paiement', p.delai_paiement,
      'natures', coalesce((select jsonb_agg(n || jsonb_build_object('convention',
          (select jsonb_build_object('nom', d.nom, 'taille', d.taille) from public.ft_resa_docs d where d.cle = p.profil || '|' || (n->>'code'))))
        from jsonb_array_elements(p.natures) n), '[]'::jsonb)));
  end loop;
  return jsonb_build_object('role', s.role, 'aujourdhui', (now() at time zone 'Europe/Paris')::date, 'profils', res);
end $$;

create or replace function public.ft_resa_profil_sauver(p_token text, p_profil text, p_reglages jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); n jsonb; codes text[] := '{}';
begin
  perform app.exiger(s, array['admin']);
  if p_profil not in ('asso','entreprise','particulier') then raise exception 'Profil inconnu.'; end if;
  if (p_reglages->>'limite_mode') not in ('aucune','fixe','glissant') then raise exception 'Mode de date limite inconnu.'; end if;
  if p_reglages->>'limite_mode' = 'fixe' and nullif(p_reglages->>'limite_date','') is null then raise exception 'Indiquez la date limite.'; end if;
  if p_reglages->>'limite_mode' = 'glissant' and coalesce(nullif(p_reglages->>'limite_jours','')::int, 0) < 1 then raise exception 'Indiquez le nombre de jours.'; end if;
  if jsonb_typeof(p_reglages->'natures') <> 'array' or jsonb_array_length(p_reglages->'natures') = 0 then raise exception 'Il faut au moins une nature de demande.'; end if;
  for n in select * from jsonb_array_elements(p_reglages->'natures') loop
    if coalesce(btrim(n->>'code'),'') = '' or coalesce(btrim(n->>'libelle'),'') = '' then raise exception 'Chaque nature doit avoir un nom.'; end if;
    if (n->>'code') = any(codes) then raise exception 'Nature en double : %', n->>'libelle'; end if;
    codes := codes || (n->>'code');
  end loop;
  update public.ft_resa_profils set ouvert = coalesce((p_reglages->>'ouvert')::boolean, false),
    limite_mode = p_reglages->>'limite_mode', limite_date = nullif(p_reglages->>'limite_date','')::date,
    limite_jours = nullif(p_reglages->>'limite_jours','')::int,
    delai_paiement = greatest(1, coalesce(nullif(p_reglages->>'delai_paiement','')::int, 15)),
    natures = p_reglages->'natures', maj = now()
  where profil = p_profil;
end $$;

-- ---------- Conventions et documents à télécharger (par profil et nature) ----------
create or replace function public.ft_resa_doc_enregistrer(p_token text, p_cle text, p_nom text, p_type text, p_contenu text)
returns void language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest');
begin
  perform app.exiger(s, array['admin']);
  if split_part(p_cle, '|', 1) not in ('asso','entreprise','particulier') or split_part(p_cle, '|', 2) = '' then raise exception 'Document inconnu.'; end if;
  if coalesce(p_contenu,'') = '' then raise exception 'Fichier vide.'; end if;
  if length(p_contenu) > 11000000 then raise exception 'Fichier trop lourd (8 Mo maximum).'; end if;
  insert into public.ft_resa_docs(cle, nom, type, taille, contenu, maj)
  values (p_cle, coalesce(nullif(btrim(p_nom),''),'convention'), p_type, length(p_contenu) * 3 / 4, p_contenu, now())
  on conflict (cle) do update set nom = excluded.nom, type = excluded.type, taille = excluded.taille, contenu = excluded.contenu, maj = now();
end $$;

create or replace function public.ft_resa_doc_supprimer(p_token text, p_cle text)
returns void language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest');
begin perform app.exiger(s, array['admin']); delete from public.ft_resa_docs where cle = p_cle; end $$;

create or replace function public.ft_resa_doc_lire(p_token text, p_cle text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.ft_resa_session(p_token); d public.ft_resa_docs;
begin
  if s.role <> 'admin' and split_part(p_cle, '|', 1) <> s.role then raise exception 'Document réservé à un autre profil.'; end if;
  select * into d from public.ft_resa_docs where cle = p_cle;
  if not found then raise exception 'Document introuvable.'; end if;
  return jsonb_build_object('nom', d.nom, 'type', d.type, 'contenu', d.contenu);
end $$;

-- ---------- Salles ----------
create or replace function public.ft_salles_liste(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.ft_resa_session(p_token);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'nom', x.nom, 'adresse', x.adresse, 'capacite', x.capacite,
      'descriptif', x.descriptif, 'youtube', x.youtube, 'photo', x.photo, 'periodes', x.periodes, 'actif', x.actif, 'ordre', x.ordre,
      'enchainement', case when s.role = 'admin' then x.enchainement else null end,
      'conditions', case when s.role = 'admin' then x.conditions else coalesce(x.conditions -> s.role, '{}'::jsonb) end)
    order by x.ordre, x.nom)
    from public.ft_salles x where not x.supprime and (s.role = 'admin' or x.actif)), '[]'::jsonb);
end $$;

create or replace function public.ft_salle_sauver(p_token text, p_salle jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); v_id bigint := nullif(p_salle->>'id','')::bigint; per text[];
begin
  perform app.exiger(s, array['admin']);
  if coalesce(btrim(p_salle->>'nom'),'') = '' then raise exception 'Indiquez le nom de la salle.'; end if;
  if length(coalesce(p_salle->>'photo','')) > 3000000 then raise exception 'Photo trop lourde.'; end if;
  select coalesce(array_agg(x), '{}') into per from jsonb_array_elements_text(coalesce(p_salle->'periodes','[]')) x
    where x in ('matin','apres_midi','soir','journee','weekend');
  if cardinality(per) = 0 then raise exception 'Cochez au moins une période réservable.'; end if;
  if v_id is null then
    insert into public.ft_salles(nom, adresse, capacite, descriptif, youtube, photo, periodes, enchainement, conditions, ordre, actif)
    values (btrim(p_salle->>'nom'), p_salle->>'adresse', p_salle->>'capacite', p_salle->>'descriptif', p_salle->>'youtube',
      nullif(p_salle->>'photo',''), per, coalesce(p_salle->'enchainement','{}'), coalesce(p_salle->'conditions','{}'),
      coalesce((select max(ordre) + 1 from public.ft_salles), 1), coalesce((p_salle->>'actif')::boolean, true))
    returning id into v_id;
  else
    update public.ft_salles set nom = btrim(p_salle->>'nom'), adresse = p_salle->>'adresse', capacite = p_salle->>'capacite',
      descriptif = p_salle->>'descriptif', youtube = p_salle->>'youtube',
      photo = case when p_salle ? 'photo' then nullif(p_salle->>'photo','') else photo end,
      periodes = per, enchainement = coalesce(p_salle->'enchainement', enchainement), conditions = coalesce(p_salle->'conditions', conditions),
      actif = coalesce((p_salle->>'actif')::boolean, actif), maj = now()
    where id = v_id and not supprime;
    if not found then raise exception 'Salle introuvable.'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.ft_salle_supprimer(p_token text, p_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest');
begin
  perform app.exiger(s, array['admin']);
  if exists (select 1 from public.ft_reservations where salle_id = p_id and statut in ('demande','pieces','option','reservee')
             and date >= (now() at time zone 'Europe/Paris')::date) then
    raise exception 'Cette salle a des demandes ou réservations à venir : traitez-les avant de la supprimer, ou masquez-la.';
  end if;
  update public.ft_salles set supprime = true, maj = now() where id = p_id;
end $$;

-- ---------- Calendrier ----------
create or replace function public.ft_salle_calendrier(p_token text, p_salle bigint, p_debut date, p_fin date)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ss app.sessions := app.ft_resa_session(p_token); adm boolean := ss.role = 'admin'; res jsonb;
begin
  if p_fin < p_debut or p_fin - p_debut > 62 then raise exception 'Période trop longue.'; end if;
  perform app.ft_resa_expirer();
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) into res from (
    select o.d::text || '|' || o.s as k,
      jsonb_strip_nulls(jsonb_build_object('e', o.e,
        'm', case when o.resa_id is not null and o.profil = ss.role and o.demandeur = ss.nom and o.prio = 1 then true end,
        'id', case when adm or (o.profil = ss.role and o.demandeur = ss.nom and o.prio = 1) then o.resa_id end,
        'n', case when adm then o.nom end,
        'p', case when adm then o.profil end,
        'mo', case when adm then o.motif end)) as v
    from (select distinct on (oc.d, oc.s) oc.* from app.ft_salle_occupation(p_salle, p_debut, p_fin, case when adm then null else ss.role end) oc
          order by oc.d, oc.s, oc.prio) o
  ) t;
  return jsonb_build_object('cases', res);
end $$;

create or replace function public.ft_blocages_liste(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest');
begin
  perform app.exiger(s, array['admin']);
  return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'salle_id', b.salle_id, 'salle', x.nom, 'date_debut', b.date_debut,
      'date_fin', b.date_fin, 'creneaux', b.creneaux, 'profils', b.profils, 'motif', b.motif) order by b.date_debut, b.id)
    from public.ft_salle_blocages b left join public.ft_salles x on x.id = b.salle_id
    where b.date_fin >= (now() at time zone 'Europe/Paris')::date - 31), '[]'::jsonb);
end $$;

-- ---------- Demande de réservation ----------
create or replace function public.ft_resa_demander(p_token text, p_demande jsonb, p_pieces jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.ft_resa_session(p_token); p public.ft_resa_profils; sa public.ft_salles; u app.ft_usagers;
  v_date date := nullif(p_demande->>'date','')::date; v_per text := p_demande->>'periode'; n jsonb; lim date; auj date;
  manque text[]; pc jsonb; r public.ft_reservations; v_nom text; v_mail text; v_tel text;
begin
  if s.role not in ('asso','entreprise','particulier') then raise exception 'Réservé aux associations, entreprises et particuliers.'; end if;
  select * into p from public.ft_resa_profils where profil = s.role;
  if not p.ouvert then raise exception 'Les réservations sont fermées pour le moment.'; end if;
  select * into sa from public.ft_salles where id = nullif(p_demande->>'salle_id','')::bigint and actif and not supprime;
  if not found then raise exception 'Salle introuvable.'; end if;
  auj := (now() at time zone 'Europe/Paris')::date;
  if v_date is null or v_date <= auj then raise exception 'Choisissez une date à partir de demain.'; end if;
  lim := app.ft_resa_limite(p);
  if lim is not null and v_date > lim then raise exception 'Réservations possibles jusqu''au % seulement.', to_char(lim, 'DD/MM/YYYY'); end if;
  if v_per is null or not (v_per = any(sa.periodes)) then raise exception 'Cette période n''est pas proposée pour cette salle.'; end if;
  if v_per = 'weekend' and extract(dow from v_date) <> 6 then raise exception 'Une location week-end commence un samedi.'; end if;
  select x into n from jsonb_array_elements(p.natures) x where x->>'code' = p_demande->>'nature';
  if n is null then raise exception 'Choisissez la nature de la demande.'; end if;
  if coalesce((n->>'precision')::boolean, false) and coalesce(btrim(p_demande->>'precision'),'') = '' then raise exception 'Précisez la nature de votre demande.'; end if;
  -- pièces : toutes les pièces exigées sont obligatoires
  if jsonb_typeof(coalesce(p_pieces,'[]'::jsonb)) <> 'array' then raise exception 'Pièces invalides.'; end if;
  p_pieces := coalesce(p_pieces, '[]'::jsonb);
  select array_agg(x) into manque from jsonb_array_elements_text(coalesce(n->'pieces','[]')) x
    where not exists (select 1 from jsonb_array_elements(p_pieces) pc2 where pc2->>'libelle' = x and coalesce(pc2->>'contenu','') <> '');
  if manque is not null then raise exception 'Pièce(s) manquante(s) : %', array_to_string(manque, ', '); end if;
  for pc in select * from jsonb_array_elements(p_pieces) loop
    if length(coalesce(pc->>'contenu','')) > 7000000 then raise exception 'Fichier trop lourd : % (5 Mo maximum).', pc->>'nom'; end if;
  end loop;
  -- demandeur
  if s.role = 'asso' then
    v_nom := s.nom; v_mail := nullif(btrim(p_demande->>'contact_mail'),''); v_tel := nullif(btrim(p_demande->>'contact_tel'),'');
    if v_mail is null or v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Indiquez un mail de contact valide.'; end if;
  else
    u := app.ft_session_usager(p_token);
    v_nom := case when s.role = 'entreprise' and coalesce(u.entreprise,'') <> '' then u.entreprise || ' (' || u.identifiant || ')' else u.identifiant end;
    v_mail := u.mail; v_tel := u.telephone;
  end if;
  -- disponibilité (verrou par salle : deux demandes simultanées ne peuvent pas prendre la même date)
  perform pg_advisory_xact_lock(91000 + sa.id);
  if exists (select 1 from app.ft_resa_slots(v_date, v_per) sl
             join app.ft_salle_occupation(sa.id, v_date, v_date + 1, s.role) o on o.d = sl.d and o.s = sl.s) then
    raise exception 'Cette date n''est plus disponible pour cette période.';
  end if;
  insert into public.ft_reservations(salle_id, profil, demandeur, demandeur_nom, contact_mail, contact_tel, date, periode, nature, nature_libelle,
    precision_nature, nb_personnes, remarque, tarif, historique)
  values (sa.id, s.role, s.nom, v_nom, v_mail, v_tel, v_date, v_per, n->>'code', n->>'libelle',
    nullif(btrim(p_demande->>'precision'),''), nullif(p_demande->>'nb_personnes','')::int, nullif(btrim(p_demande->>'remarque'),''),
    nullif(n->>'tarif','')::numeric, app.ft_resa_hist(v_nom, 'demande', null))
  returning * into r;
  insert into public.ft_resa_pieces(resa_id, libelle, nom, type, taille, contenu)
  select r.id, x->>'libelle', x->>'nom', x->>'type', length(x->>'contenu') * 3 / 4, x->>'contenu'
  from jsonb_array_elements(p_pieces) x where coalesce(x->>'contenu','') <> '';
  return jsonb_build_object('id', r.id);
end $$;

create or replace function public.ft_resa_mes_demandes(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.ft_resa_session(p_token);
begin
  perform app.ft_resa_expirer();
  return coalesce((select jsonb_agg(app.ft_resa_json(r, false) order by r.date desc, r.id desc)
    from public.ft_reservations r where r.profil = s.role and r.demandeur = s.nom), '[]'::jsonb);
end $$;

-- Ajout d'une pièce par le demandeur (demande en cours ou pièces manquantes)
create or replace function public.ft_resa_piece_ajouter(p_token text, p_resa bigint, p_libelle text, p_nom text, p_type text, p_contenu text)
returns void language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.ft_resa_session(p_token); r public.ft_reservations;
begin
  select * into r from public.ft_reservations where id = p_resa and profil = s.role and demandeur = s.nom;
  if not found then raise exception 'Demande introuvable.'; end if;
  if r.statut not in ('demande','pieces') then raise exception 'Cette demande ne peut plus être complétée.'; end if;
  if coalesce(p_contenu,'') = '' then raise exception 'Fichier vide.'; end if;
  if length(p_contenu) > 7000000 then raise exception 'Fichier trop lourd (5 Mo maximum).'; end if;
  insert into public.ft_resa_pieces(resa_id, libelle, nom, type, taille, contenu)
  values (r.id, coalesce(nullif(btrim(p_libelle),''), 'Pièce complémentaire'), p_nom, p_type, length(p_contenu) * 3 / 4, p_contenu);
  update public.ft_reservations set statut = 'demande', maj = now(),
    historique = historique || app.ft_resa_hist(r.demandeur_nom, 'piece', 'Pièce ajoutée : ' || coalesce(nullif(btrim(p_libelle),''), p_nom))
  where id = r.id;
end $$;

create or replace function public.ft_resa_piece_lire(p_token text, p_piece bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.ft_resa_session(p_token); pc public.ft_resa_pieces; r public.ft_reservations;
begin
  select * into pc from public.ft_resa_pieces where id = p_piece;
  if not found then raise exception 'Pièce introuvable.'; end if;
  select * into r from public.ft_reservations where id = pc.resa_id;
  if s.role <> 'admin' and not (r.profil = s.role and r.demandeur = s.nom) then raise exception 'Pièce introuvable.'; end if;
  return jsonb_build_object('nom', pc.nom, 'type', pc.type, 'contenu', pc.contenu);
end $$;

create or replace function public.ft_resa_annuler(p_token text, p_resa bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.ft_resa_session(p_token); r public.ft_reservations;
begin
  select * into r from public.ft_reservations where id = p_resa and profil = s.role and demandeur = s.nom;
  if not found then raise exception 'Demande introuvable.'; end if;
  if r.statut not in ('demande','pieces','option') then raise exception 'Cette demande ne peut plus être annulée en ligne : contactez le service des sports.'; end if;
  update public.ft_reservations set statut = 'annulee', maj = now(),
    historique = historique || app.ft_resa_hist(r.demandeur_nom, 'annulee_demandeur', 'Annulée par le demandeur') where id = r.id;
end $$;

-- ---------- Administration des demandes ----------
create or replace function public.ft_resa_liste(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest');
begin
  perform app.exiger(s, array['admin']);
  perform app.ft_resa_expirer();
  return coalesce((select jsonb_agg(app.ft_resa_json(r, true) order by r.date, r.id) from public.ft_reservations r), '[]'::jsonb);
end $$;

-- action : valider | pieces | refuser | payee | annuler
create or replace function public.ft_resa_decider(p_token text, p_resa bigint, p_action text, p_message text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); r public.ft_reservations; p public.ft_resa_profils;
  v_statut text; v_ech date; v_evt text; auj date := (now() at time zone 'Europe/Paris')::date;
begin
  perform app.exiger(s, array['admin']);
  select * into r from public.ft_reservations where id = p_resa for update;
  if not found then raise exception 'Demande introuvable.'; end if;
  select * into p from public.ft_resa_profils where profil = r.profil;
  if p_action = 'valider' then
    if r.statut not in ('demande','pieces') then raise exception 'Seule une demande en cours peut être validée.'; end if;
    if r.tarif is not null and r.tarif = 0 then v_statut := 'reservee'; v_evt := 'reservee';
    else v_statut := 'option'; v_ech := auj + p.delai_paiement; v_evt := 'validee'; end if;
  elsif p_action = 'pieces' then
    if r.statut not in ('demande','pieces') then raise exception 'Seule une demande en cours peut être complétée.'; end if;
    if coalesce(btrim(p_message),'') = '' then raise exception 'Indiquez les pièces à compléter.'; end if;
    v_statut := 'pieces'; v_evt := 'pieces';
  elsif p_action = 'refuser' then
    if r.statut not in ('demande','pieces','option') then raise exception 'Cette demande ne peut pas être refusée.'; end if;
    v_statut := 'refusee'; v_evt := 'refusee';
  elsif p_action = 'payee' then
    if r.statut <> 'option' then raise exception 'Seule une réservation en attente de paiement peut être marquée payée.'; end if;
    v_statut := 'reservee'; v_evt := 'reservee';
  elsif p_action = 'annuler' then
    if r.statut not in ('demande','pieces','option','reservee') then raise exception 'Cette demande est déjà close.'; end if;
    v_statut := 'annulee'; v_evt := 'annulee';
  else raise exception 'Action inconnue.'; end if;
  update public.ft_reservations set statut = v_statut, echeance = case when v_statut = 'option' then coalesce(v_ech, echeance) else echeance end,
    message = nullif(btrim(coalesce(p_message,'')),''), maj = now(),
    historique = historique || app.ft_resa_hist('Service des sports', v_evt, p_message)
  where id = r.id returning * into r;
  return jsonb_build_object('statut', r.statut, 'evt', v_evt);
end $$;

-- ---------- Blocages ----------
create or replace function public.ft_blocage_ajouter(p_token text, p_blocage jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); v_id bigint; cr text[]; pr text[];
begin
  perform app.exiger(s, array['admin']);
  select coalesce(array_agg(x), '{}') into cr from jsonb_array_elements_text(p_blocage->'creneaux') x where x in ('matin','apres_midi','soir');
  select coalesce(array_agg(x), '{}') into pr from jsonb_array_elements_text(p_blocage->'profils') x where x in ('asso','entreprise','particulier');
  if cardinality(cr) = 0 then raise exception 'Cochez au moins un moment (matin, après-midi, soir).'; end if;
  if cardinality(pr) = 0 then raise exception 'Cochez au moins un profil.'; end if;
  if nullif(p_blocage->>'date_debut','') is null or nullif(p_blocage->>'date_fin','') is null
     or (p_blocage->>'date_fin')::date < (p_blocage->>'date_debut')::date then raise exception 'Dates incorrectes.'; end if;
  if (p_blocage->>'date_fin')::date - (p_blocage->>'date_debut')::date > 400 then raise exception 'Période trop longue (400 jours maximum).'; end if;
  insert into public.ft_salle_blocages(salle_id, date_debut, date_fin, creneaux, profils, motif)
  values (nullif(p_blocage->>'salle_id','')::bigint, (p_blocage->>'date_debut')::date, (p_blocage->>'date_fin')::date, cr, pr,
    nullif(btrim(p_blocage->>'motif'),'')) returning id into v_id;
  return v_id;
end $$;

create or replace function public.ft_blocage_supprimer(p_token text, p_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest');
begin perform app.exiger(s, array['admin']); delete from public.ft_salle_blocages where id = p_id; end $$;

-- ---------- Mails (appelé uniquement par la fonction serveur fusiontest-salles-mail) ----------
-- evt : nouvelle (au service des sports, par le demandeur) ; validee | pieces | refusee | reservee | annulee (au demandeur, par l'administrateur)
create or replace function public.ft_resa_mail_preparer(p_token text, p_resa bigint, p_evt text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s app.sessions; r public.ft_reservations; dest text; lid bigint; cle text; derniere jsonb; p public.ft_resa_profils;
begin
  if not app.ft_est_serveur() then raise exception 'Réservé au serveur.'; end if;
  select * into s from app.sessions where token = p_token and site = 'fusiontest' and expire > now();
  if not found then raise exception 'Session expirée.'; end if;
  select * into r from public.ft_reservations where id = p_resa;
  if not found then raise exception 'Demande introuvable.'; end if;
  derniere := r.historique -> (jsonb_array_length(r.historique) - 1);
  if p_evt = 'nouvelle' then
    if not (r.profil = s.role and r.demandeur = s.nom) then raise exception 'Demande d''un autre compte.'; end if;
    if jsonb_array_length(r.historique) <> 1 then return jsonb_build_object('deja', true); end if;
    dest := coalesce(nullif(btrim((select valeur from public.ft_reglages where cle = 'mail_resa')),''),
                     nullif(btrim((select valeur from public.ft_reglages where cle = 'mail_dest')),''), 'sports@ville-corbas.fr');
  elsif p_evt in ('validee','pieces','refusee','reservee','annulee') then
    if s.role <> 'admin' then raise exception 'Réservé à l''administrateur.'; end if;
    if derniere->>'action' <> p_evt then raise exception 'Événement périmé.'; end if;
    dest := r.contact_mail;
  else raise exception 'Événement inconnu.'; end if;
  cle := 'salle:' || r.id || ':' || p_evt || ':' || jsonb_array_length(r.historique);
  if exists (select 1 from public.ft_mails where demande_id = cle and statut in ('envoye','en_cours')) then return jsonb_build_object('deja', true); end if;
  if dest is null then return jsonb_build_object('deja', true, 'sans_adresse', true); end if;
  insert into public.ft_mails(saison, demande_id, association, destinataire) values (null, cle, r.demandeur_nom, dest) returning id into lid;
  select * into p from public.ft_resa_profils where profil = r.profil;
  return jsonb_build_object('deja', false, 'log', lid, 'dest', dest, 'evt', p_evt,
    'resa', app.ft_resa_json(r, true) - 'historique', 'delai', p.delai_paiement);
end $$;

revoke execute on function public.ft_resa_mail_preparer(text, bigint, text) from public, anon, authenticated;
grant execute on function public.ft_resa_mail_preparer(text, bigint, text) to service_role;
grant execute on function public.ft_mail_resultat(bigint, text, text) to service_role;

-- Réglage « mail_resa » autorisé dans public.ft_reglage (adresse qui reçoit les nouvelles demandes de salle).
