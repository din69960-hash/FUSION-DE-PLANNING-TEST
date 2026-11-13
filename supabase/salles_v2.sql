-- =====================================================================
-- SITE TEST — Réservation des salles municipales, version 2 (13/11/2026)
-- Questionnaire d'orientation, tarifs et cautions par salle (profil × nature ×
-- Corbassien / extérieur), disponibilités par jour, horizon de réservation
-- (6 mois, 1 an pour un mariage), délai minimum d'un mois, un seul événement
-- par week-end, réservation exceptionnelle par l'administrateur,
-- paiement en ligne (démonstration ou Stripe en mode test), veille ouvrée
-- pour la remise des chèques de caution.
-- Appliqué dans Supabase par la migration ft_salles_v2.
-- =====================================================================

-- ---------- Colonnes ----------
alter table public.ft_salles add column if not exists capacite_max int;
alter table public.ft_salles add column if not exists dispo jsonb not null default '{}'::jsonb;       -- {"1":["matin","soir"],...} (0 = dimanche) ; jour absent = toutes les périodes
alter table public.ft_salles add column if not exists tarifs jsonb not null default '{}'::jsonb;      -- {"particulier":{"mariage":{"ouvert":true,"corbas":200,"ext":400,"menage":150,"reparation":800}}}
alter table public.ft_salles add column if not exists un_par_weekend boolean not null default true;

alter table public.ft_resa_profils add column if not exists horizon_mois int not null default 6;
alter table public.ft_resa_profils add column if not exists delai_min_jours int not null default 30;

alter table public.ft_reservations add column if not exists corbassien boolean;
alter table public.ft_reservations add column if not exists caution_menage numeric;
alter table public.ft_reservations add column if not exists caution_reparation numeric;
alter table public.ft_reservations add column if not exists pay_jeton text;
alter table public.ft_reservations add column if not exists paye_le timestamptz;
alter table public.ft_reservations add column if not exists paye_mode text;
alter table public.ft_reservations add column if not exists paye_ref text;
alter table public.ft_reservations add column if not exists par_admin boolean not null default false;

-- ---------- Jours fériés et veille ouvrée ----------
create or replace function app.ft_paques(y int)
returns date language plpgsql immutable set search_path = '' as $$
declare a int := y % 19; b int := y / 100; c int := y % 100; d int := b / 4; e int := b % 4; f int := (b + 8) / 25;
  g int := (b - f + 1) / 3; h int := (19 * a + b - d - g + 15) % 30; i int := c / 4; k int := c % 4;
  l int := (32 + 2 * e + 2 * i - h - k) % 7; m int := (a + 11 * h + 22 * l) / 451;
begin
  return make_date(y, (h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1);
end $$;

create or replace function app.ft_ferie(p_d date)
returns boolean language sql immutable set search_path = '' as $$
  select to_char(p_d, 'MM-DD') in ('01-01','05-01','05-08','07-14','08-15','11-01','11-11','12-25')
      or p_d in (app.ft_paques(extract(year from p_d)::int) + 1, app.ft_paques(extract(year from p_d)::int) + 39,
                 app.ft_paques(extract(year from p_d)::int) + 50);
$$;

-- Dernier jour ouvré (lundi → vendredi, hors fériés) avant l'événement
create or replace function app.ft_veille_ouvree(p_d date)
returns date language plpgsql immutable set search_path = '' as $$
declare x date := p_d - 1;
begin
  while extract(dow from x) in (0, 6) or app.ft_ferie(x) loop x := x - 1; end loop;
  return x;
end $$;

-- ---------- Règles ----------
-- Fin de la fenêtre de réservation pour une nature : date limite du profil et horizon (mois)
create or replace function app.ft_resa_fin(p public.ft_resa_profils, n jsonb)
returns date language sql stable set search_path = '' as $$
  select least(app.ft_resa_limite(p),
    ((now() at time zone 'Europe/Paris')::date + make_interval(months => coalesce(nullif(n->>'horizon_mois','')::int, p.horizon_mois)))::date);
$$;

-- Période proposée ce jour-là pour cette salle
create or replace function app.ft_salle_periode_ok(sa public.ft_salles, p_date date, p_periode text)
returns boolean language sql stable set search_path = '' as $$
  select p_periode = any(sa.periodes) and (
    not (sa.dispo ? (extract(dow from p_date)::int)::text)
    or (sa.dispo -> (extract(dow from p_date)::int)::text) ? p_periode);
$$;

-- Tarif et cautions d'une salle pour un profil, une nature et un demandeur corbassien ou extérieur
create or replace function app.ft_resa_tarif(sa public.ft_salles, p_profil text, n jsonb, p_corbas boolean)
returns jsonb language sql stable set search_path = '' as $$
  with t as (select coalesce(sa.tarifs -> p_profil -> (n->>'code'), '{}'::jsonb) x)
  select jsonb_build_object(
    'ouvert', coalesce((t.x->>'ouvert')::boolean, true),
    'location', coalesce(nullif(t.x->>(case when coalesce(p_corbas, true) then 'corbas' else 'ext' end), '')::numeric, nullif(n->>'tarif','')::numeric),
    'menage', nullif(t.x->>'menage','')::numeric,
    'reparation', nullif(t.x->>'reparation','')::numeric)
  from t;
$$;

-- ---------- Occupation : + un seul événement par week-end ----------
create or replace function app.ft_salle_occupation(p_salle bigint, p_debut date, p_fin date, p_profil text)
returns table(d date, s text, e text, resa_id bigint, profil text, demandeur text, nom text, motif text, prio int)
language sql stable set search_path = '' as $$
  with occ as (
    select sl.d, sl.s, r.id, r.statut, r.profil, r.demandeur, r.demandeur_nom, r.nature_libelle
    from public.ft_reservations r cross join lateral app.ft_resa_slots(r.date, r.periode) sl
    where r.salle_id = p_salle and r.statut in ('demande','pieces','option','reservee')
      and r.date between p_debut - 3 and p_fin + 3
  ), regle as (select enchainement, un_par_weekend from public.ft_salles where id = p_salle)
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
  select distinct o.d, 'soir', 'bloque', o.id, o.profil, o.demandeur, o.demandeur_nom, 'Règle d''enchaînement', 3
  from occ o, regle
  where o.s in ('matin','apres_midi') and o.d between p_debut and p_fin
    and coalesce((regle.enchainement -> (extract(dow from o.d)::int)::text ->> 'soir')::boolean, false)
  union all
  select distinct o.d + 1, 'matin', 'bloque', o.id, o.profil, o.demandeur, o.demandeur_nom, 'Règle d''enchaînement', 3
  from occ o, regle
  where o.s = 'soir' and o.d + 1 between p_debut and p_fin
    and coalesce((regle.enchainement -> (extract(dow from o.d)::int)::text ->> 'lendemain')::boolean, false)
  union all
  -- une demande du vendredi, du samedi ou du dimanche ferme tout le week-end (vendredi → dimanche)
  select distinct g::date, c, 'bloque', o.id, o.profil, o.demandeur, o.demandeur_nom, 'Un seul événement par week-end', 3
  from occ o, regle
  cross join lateral generate_series(o.d - ((extract(dow from o.d)::int + 2) % 7), o.d - ((extract(dow from o.d)::int + 2) % 7) + 2, interval '1 day') g
  cross join lateral unnest(array['matin','apres_midi','soir']) c
  where regle.un_par_weekend and extract(dow from o.d) in (5, 6, 0) and g::date between p_debut and p_fin;
$$;

-- ---------- JSON d'une demande ----------
create or replace function app.ft_resa_json(r public.ft_reservations, p_admin boolean)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('id', r.id, 'salle_id', r.salle_id,
    'salle', (select nom from public.ft_salles where id = r.salle_id),
    'adresse', (select adresse from public.ft_salles where id = r.salle_id),
    'profil', r.profil, 'demandeur_nom', r.demandeur_nom, 'contact_mail', r.contact_mail, 'contact_tel', r.contact_tel,
    'date', r.date, 'periode', r.periode, 'nature', r.nature, 'nature_libelle', r.nature_libelle,
    'precision', r.precision_nature, 'nb_personnes', r.nb_personnes, 'remarque', r.remarque, 'tarif', r.tarif,
    'corbassien', r.corbassien, 'caution_menage', r.caution_menage, 'caution_reparation', r.caution_reparation,
    'veille', app.ft_veille_ouvree(r.date), 'par_admin', r.par_admin,
    'pay_jeton', case when r.statut = 'option' then r.pay_jeton end,
    'paye_le', r.paye_le, 'paye_mode', r.paye_mode, 'paye_ref', case when p_admin then r.paye_ref end,
    'statut', r.statut, 'message', r.message, 'echeance', r.echeance,
    'cree', r.cree, 'maj', r.maj, 'historique', r.historique,
    'pieces', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'libelle', p.libelle, 'nom', p.nom, 'taille', p.taille, 'cree', p.cree) order by p.id)
                        from public.ft_resa_pieces p where p.resa_id = r.id), '[]'::jsonb));
$$;

-- ---------- Infos des profils ----------
create or replace function public.ft_resa_infos(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.ft_resa_session(p_token); res jsonb := '{}'::jsonb; p public.ft_resa_profils;
  auj date := (now() at time zone 'Europe/Paris')::date;
begin
  for p in select * from public.ft_resa_profils where s.role = 'admin' or profil = s.role loop
    res := res || jsonb_build_object(p.profil, jsonb_build_object(
      'ouvert', p.ouvert, 'limite_mode', p.limite_mode, 'limite_date', p.limite_date, 'limite_jours', p.limite_jours,
      'limite', app.ft_resa_limite(p), 'delai_paiement', p.delai_paiement,
      'horizon_mois', p.horizon_mois, 'delai_min_jours', p.delai_min_jours, 'debut', auj + p.delai_min_jours,
      'natures', coalesce((select jsonb_agg(n || jsonb_build_object('fin', app.ft_resa_fin(p, n), 'convention',
          (select jsonb_build_object('nom', d.nom, 'taille', d.taille) from public.ft_resa_docs d where d.cle = p.profil || '|' || (n->>'code'))))
        from jsonb_array_elements(p.natures) n), '[]'::jsonb)));
  end loop;
  return jsonb_build_object('role', s.role, 'aujourdhui', auj, 'profils', res);
end $$;

create or replace function public.ft_resa_profil_sauver(p_token text, p_profil text, p_reglages jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); n jsonb; codes text[] := '{}'; nat jsonb := '[]'::jsonb;
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
    if coalesce(nullif(n->>'horizon_mois','')::int, 1) < 1 then raise exception 'Horizon incorrect pour %', n->>'libelle'; end if;
    codes := codes || (n->>'code');
    nat := nat || jsonb_build_array((n - 'fin' - 'convention'));
  end loop;
  update public.ft_resa_profils set ouvert = coalesce((p_reglages->>'ouvert')::boolean, false),
    limite_mode = p_reglages->>'limite_mode', limite_date = nullif(p_reglages->>'limite_date','')::date,
    limite_jours = nullif(p_reglages->>'limite_jours','')::int,
    delai_paiement = greatest(1, coalesce(nullif(p_reglages->>'delai_paiement','')::int, 7)),
    horizon_mois = greatest(1, coalesce(nullif(p_reglages->>'horizon_mois','')::int, 6)),
    delai_min_jours = greatest(1, coalesce(nullif(p_reglages->>'delai_min_jours','')::int, 30)),
    natures = nat, maj = now()
  where profil = p_profil;
end $$;

-- ---------- Salles ----------
create or replace function public.ft_salles_liste(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.ft_resa_session(p_token);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'nom', x.nom, 'adresse', x.adresse, 'capacite', x.capacite,
      'capacite_max', x.capacite_max, 'descriptif', x.descriptif, 'youtube', x.youtube, 'photo', x.photo, 'periodes', x.periodes,
      'actif', x.actif, 'ordre', x.ordre, 'dispo', x.dispo, 'un_par_weekend', x.un_par_weekend,
      'enchainement', case when s.role = 'admin' then x.enchainement else null end,
      'tarifs', case when s.role = 'admin' then x.tarifs else coalesce(x.tarifs -> s.role, '{}'::jsonb) end,
      'conditions', case when s.role = 'admin' then x.conditions else coalesce(x.conditions -> s.role, '{}'::jsonb) end)
    order by x.ordre, x.nom)
    from public.ft_salles x where not x.supprime and (s.role = 'admin' or x.actif)), '[]'::jsonb);
end $$;

create or replace function public.ft_salle_sauver(p_token text, p_salle jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); v_id bigint := nullif(p_salle->>'id','')::bigint; per text[];
  v_cap int := nullif(p_salle->>'capacite_max','')::int;
begin
  perform app.exiger(s, array['admin']);
  if coalesce(btrim(p_salle->>'nom'),'') = '' then raise exception 'Indiquez le nom de la salle.'; end if;
  if length(coalesce(p_salle->>'photo','')) > 3000000 then raise exception 'Photo trop lourde.'; end if;
  if v_cap is not null and v_cap < 1 then raise exception 'Capacité maximale incorrecte.'; end if;
  select coalesce(array_agg(x), '{}') into per from jsonb_array_elements_text(coalesce(p_salle->'periodes','[]')) x
    where x in ('matin','apres_midi','soir','journee','weekend');
  if cardinality(per) = 0 then raise exception 'Cochez au moins une période réservable.'; end if;
  if v_id is null then
    insert into public.ft_salles(nom, adresse, capacite, capacite_max, descriptif, youtube, photo, periodes, enchainement, conditions,
      dispo, tarifs, un_par_weekend, ordre, actif)
    values (btrim(p_salle->>'nom'), p_salle->>'adresse', p_salle->>'capacite', v_cap, p_salle->>'descriptif', p_salle->>'youtube',
      nullif(p_salle->>'photo',''), per, coalesce(p_salle->'enchainement','{}'), coalesce(p_salle->'conditions','{}'),
      coalesce(p_salle->'dispo','{}'), coalesce(p_salle->'tarifs','{}'), coalesce((p_salle->>'un_par_weekend')::boolean, true),
      coalesce((select max(ordre) + 1 from public.ft_salles), 1), coalesce((p_salle->>'actif')::boolean, true))
    returning id into v_id;
  else
    update public.ft_salles set nom = btrim(p_salle->>'nom'), adresse = p_salle->>'adresse', capacite = p_salle->>'capacite',
      capacite_max = v_cap, descriptif = p_salle->>'descriptif', youtube = p_salle->>'youtube',
      photo = case when p_salle ? 'photo' then nullif(p_salle->>'photo','') else photo end,
      periodes = per, enchainement = coalesce(p_salle->'enchainement', enchainement), conditions = coalesce(p_salle->'conditions', conditions),
      dispo = coalesce(p_salle->'dispo', dispo), tarifs = coalesce(p_salle->'tarifs', tarifs),
      un_par_weekend = coalesce((p_salle->>'un_par_weekend')::boolean, un_par_weekend),
      actif = coalesce((p_salle->>'actif')::boolean, actif), maj = now()
    where id = v_id and not supprime;
    if not found then raise exception 'Salle introuvable.'; end if;
  end if;
  return v_id;
end $$;

-- ---------- Calendrier : l'usager ne voit rien avant le délai minimum ----------
create or replace function public.ft_salle_calendrier(p_token text, p_salle bigint, p_debut date, p_fin date)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare ss app.sessions := app.ft_resa_session(p_token); adm boolean := ss.role = 'admin'; res jsonb; v_min date;
begin
  if p_fin < p_debut or p_fin - p_debut > 62 then raise exception 'Période trop longue.'; end if;
  perform app.ft_resa_expirer();
  if not adm then
    select (now() at time zone 'Europe/Paris')::date + delai_min_jours into v_min from public.ft_resa_profils where profil = ss.role;
  end if;
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
    where adm or o.d >= v_min or (o.profil = ss.role and o.demandeur = ss.nom and o.prio = 1)
  ) t;
  return jsonb_build_object('cases', res);
end $$;

-- ---------- Demande de réservation (usagers) ----------
create or replace function public.ft_resa_demander(p_token text, p_demande jsonb, p_pieces jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.ft_resa_session(p_token); p public.ft_resa_profils; sa public.ft_salles; u app.ft_usagers;
  v_date date := nullif(p_demande->>'date','')::date; v_per text := p_demande->>'periode'; n jsonb; fin date; auj date;
  manque text[]; pc jsonb; r public.ft_reservations; v_nom text; v_mail text; v_tel text; t jsonb;
  v_nb int := nullif(p_demande->>'nb_personnes','')::int; v_corbas boolean := (nullif(p_demande->>'corbassien',''))::boolean;
begin
  if s.role not in ('asso','entreprise','particulier') then raise exception 'Réservé aux associations, entreprises et particuliers.'; end if;
  select * into p from public.ft_resa_profils where profil = s.role;
  if not p.ouvert then raise exception 'Les réservations sont fermées pour le moment.'; end if;
  select * into sa from public.ft_salles where id = nullif(p_demande->>'salle_id','')::bigint and actif and not supprime;
  if not found then raise exception 'Salle introuvable.'; end if;
  select x into n from jsonb_array_elements(p.natures) x where x->>'code' = p_demande->>'nature';
  if n is null then raise exception 'Choisissez la nature de la demande.'; end if;
  if v_corbas is null then raise exception 'Indiquez si vous êtes de Corbas ou de l''extérieur.'; end if;
  if v_nb is null or v_nb < 1 then raise exception 'Indiquez le nombre de personnes.'; end if;
  if sa.capacite_max is not null and v_nb > sa.capacite_max then raise exception 'Cette salle accueille % personnes au maximum.', sa.capacite_max; end if;
  t := app.ft_resa_tarif(sa, s.role, n, v_corbas);
  if not (t->>'ouvert')::boolean then raise exception 'Cette salle n''est pas proposée pour : %.', n->>'libelle'; end if;
  auj := (now() at time zone 'Europe/Paris')::date;
  if v_date is null or v_date < auj + p.delai_min_jours then
    raise exception 'Les réservations se font au moins % jours à l''avance (à partir du %).', p.delai_min_jours, to_char(auj + p.delai_min_jours, 'DD/MM/YYYY');
  end if;
  fin := app.ft_resa_fin(p, n);
  if v_date > fin then raise exception 'Pour « % », réservations possibles jusqu''au % seulement.', n->>'libelle', to_char(fin, 'DD/MM/YYYY'); end if;
  if v_per is null or not app.ft_salle_periode_ok(sa, v_date, v_per) then raise exception 'Cette période n''est pas proposée ce jour-là pour cette salle.'; end if;
  if v_per = 'weekend' and extract(dow from v_date) <> 6 then raise exception 'Une location week-end commence un samedi.'; end if;
  if coalesce((n->>'precision')::boolean, false) and coalesce(btrim(p_demande->>'precision'),'') = '' then raise exception 'Précisez la nature de votre demande.'; end if;
  if jsonb_typeof(coalesce(p_pieces,'[]'::jsonb)) <> 'array' then raise exception 'Pièces invalides.'; end if;
  p_pieces := coalesce(p_pieces, '[]'::jsonb);
  select array_agg(x) into manque from jsonb_array_elements_text(coalesce(n->'pieces','[]'::jsonb)) x
    where not exists (select 1 from jsonb_array_elements(p_pieces) pc2 where pc2->>'libelle' = x and coalesce(pc2->>'contenu','') <> '');
  if manque is not null then raise exception 'Pièce(s) manquante(s) : %', array_to_string(manque, ', '); end if;
  for pc in select * from jsonb_array_elements(p_pieces) loop
    if length(coalesce(pc->>'contenu','')) > 7000000 then raise exception 'Fichier trop lourd : % (5 Mo maximum).', pc->>'nom'; end if;
  end loop;
  if s.role = 'asso' then
    v_nom := s.nom; v_mail := nullif(btrim(p_demande->>'contact_mail'),''); v_tel := nullif(btrim(p_demande->>'contact_tel'),'');
    if v_mail is null or v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Indiquez un mail de contact valide.'; end if;
  else
    u := app.ft_session_usager(p_token);
    v_nom := case when s.role = 'entreprise' and coalesce(u.entreprise,'') <> '' then u.entreprise || ' (' || u.identifiant || ')' else u.identifiant end;
    v_mail := u.mail; v_tel := u.telephone;
  end if;
  perform pg_advisory_xact_lock(91000 + sa.id);
  if exists (select 1 from app.ft_resa_slots(v_date, v_per) sl
             join app.ft_salle_occupation(sa.id, v_date, v_date + 1, s.role) o on o.d = sl.d and o.s = sl.s) then
    raise exception 'Cette date n''est plus disponible pour cette période.';
  end if;
  insert into public.ft_reservations(salle_id, profil, demandeur, demandeur_nom, contact_mail, contact_tel, date, periode, nature, nature_libelle,
    precision_nature, nb_personnes, remarque, tarif, corbassien, caution_menage, caution_reparation, historique)
  values (sa.id, s.role, s.nom, v_nom, v_mail, v_tel, v_date, v_per, n->>'code', n->>'libelle',
    nullif(btrim(p_demande->>'precision'),''), v_nb, nullif(btrim(p_demande->>'remarque'),''),
    (t->>'location')::numeric, v_corbas, (t->>'menage')::numeric, (t->>'reparation')::numeric, app.ft_resa_hist(v_nom, 'demande', null))
  returning * into r;
  insert into public.ft_resa_pieces(resa_id, libelle, nom, type, taille, contenu)
  select r.id, x->>'libelle', x->>'nom', x->>'type', length(x->>'contenu') * 3 / 4, x->>'contenu'
  from jsonb_array_elements(p_pieces) x where coalesce(x->>'contenu','') <> '';
  return jsonb_build_object('id', r.id);
end $$;

-- ---------- Décisions de l'administrateur ----------
create or replace function app.ft_jeton()
returns text language sql volatile set search_path = '' as $$
  select replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
$$;

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
    if r.tarif is null then raise exception 'Indiquez d''abord le montant de la location (0 si gratuit).'; end if;
    if r.tarif = 0 then v_statut := 'reservee'; v_evt := 'reservee';
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
    pay_jeton = case when v_statut = 'option' then coalesce(pay_jeton, app.ft_jeton()) else pay_jeton end,
    paye_le = case when p_action = 'payee' then now() else paye_le end,
    paye_mode = case when p_action = 'payee' then 'guichet' else paye_mode end,
    message = nullif(btrim(coalesce(p_message,'')),''), maj = now(),
    historique = historique || app.ft_resa_hist('Service des sports', v_evt,
      case when p_action = 'payee' then coalesce(nullif(btrim(coalesce(p_message,'')),''), 'Paiement reçu au service des sports') else p_message end)
  where id = r.id returning * into r;
  return jsonb_build_object('statut', r.statut, 'evt', v_evt);
end $$;

-- Montants (location, cautions) modifiables par l'administrateur avant le paiement
create or replace function public.ft_resa_montants(p_token text, p_resa bigint, p_montants jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); r public.ft_reservations;
  v_t numeric := nullif(p_montants->>'tarif','')::numeric; v_m numeric := nullif(p_montants->>'caution_menage','')::numeric;
  v_r numeric := nullif(p_montants->>'caution_reparation','')::numeric;
begin
  perform app.exiger(s, array['admin']);
  select * into r from public.ft_reservations where id = p_resa for update;
  if not found then raise exception 'Demande introuvable.'; end if;
  if r.statut not in ('demande','pieces','option') then raise exception 'Les montants ne sont plus modifiables.'; end if;
  if coalesce(v_t, 0) < 0 or coalesce(v_m, 0) < 0 or coalesce(v_r, 0) < 0 then raise exception 'Montant incorrect.'; end if;
  if r.statut = 'option' and coalesce(v_t, 0) = 0 then raise exception 'Une réservation en attente de paiement doit avoir un montant.'; end if;
  if r.tarif is not distinct from v_t and r.caution_menage is not distinct from v_m and r.caution_reparation is not distinct from v_r then return; end if;
  update public.ft_reservations set tarif = v_t, caution_menage = v_m, caution_reparation = v_r, maj = now(),
    historique = historique || app.ft_resa_hist('Service des sports', 'montants',
      'Location : ' || coalesce(v_t::text || ' €', '—') || ' · caution ménage : ' || coalesce(v_m::text || ' €', '—')
      || ' · caution réparation : ' || coalesce(v_r::text || ' €', '—'))
  where id = r.id;
end $$;

-- Réservation exceptionnelle par l'administrateur (sans délai minimum ni horizon)
create or replace function public.ft_resa_admin_creer(p_token text, p_demande jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); sa public.ft_salles; p public.ft_resa_profils; n jsonb; t jsonb;
  v_date date := nullif(p_demande->>'date','')::date; v_per text := p_demande->>'periode'; v_prof text := p_demande->>'profil';
  v_corbas boolean := coalesce((nullif(p_demande->>'corbassien',''))::boolean, true); r public.ft_reservations;
  v_tarif numeric; v_statut text; v_evt text; auj date := (now() at time zone 'Europe/Paris')::date; v_mail text;
begin
  perform app.exiger(s, array['admin']);
  select * into p from public.ft_resa_profils where profil = v_prof;
  if not found then raise exception 'Choisissez le profil du demandeur.'; end if;
  select * into sa from public.ft_salles where id = nullif(p_demande->>'salle_id','')::bigint and not supprime;
  if not found then raise exception 'Salle introuvable.'; end if;
  select x into n from jsonb_array_elements(p.natures) x where x->>'code' = p_demande->>'nature';
  if n is null then raise exception 'Choisissez la nature.'; end if;
  if coalesce(btrim(p_demande->>'demandeur_nom'),'') = '' then raise exception 'Indiquez le nom du demandeur.'; end if;
  v_mail := nullif(btrim(p_demande->>'contact_mail'),'');
  if v_mail is not null and v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Mail de contact invalide.'; end if;
  if v_date is null then raise exception 'Choisissez la date.'; end if;
  if v_date < auj then raise exception 'Date passée.'; end if;
  if v_per is null or not (v_per = any(sa.periodes)) then raise exception 'Période non proposée pour cette salle.'; end if;
  if v_per = 'weekend' and extract(dow from v_date) <> 6 then raise exception 'Une location week-end commence un samedi.'; end if;
  t := app.ft_resa_tarif(sa, v_prof, n, v_corbas);
  v_tarif := coalesce(nullif(p_demande->>'tarif','')::numeric, (t->>'location')::numeric);
  perform pg_advisory_xact_lock(91000 + sa.id);
  if exists (select 1 from app.ft_resa_slots(v_date, v_per) sl
             join app.ft_salle_occupation(sa.id, v_date, v_date + 1, null) o on o.d = sl.d and o.s = sl.s) then
    raise exception 'Créneau déjà occupé ou bloqué : libérez-le d''abord (planning ou dates bloquées).';
  end if;
  if coalesce(p_demande->>'etat','') = 'valider' then
    if v_tarif is null then raise exception 'Indiquez le montant de la location (0 si gratuit).'; end if;
    if v_tarif = 0 then v_statut := 'reservee'; v_evt := 'reservee'; else v_statut := 'option'; v_evt := 'validee'; end if;
  else v_statut := 'demande'; v_evt := null; end if;
  insert into public.ft_reservations(salle_id, profil, demandeur, demandeur_nom, contact_mail, contact_tel, date, periode, nature, nature_libelle,
    precision_nature, nb_personnes, remarque, tarif, corbassien, caution_menage, caution_reparation, par_admin, statut, echeance, pay_jeton, historique)
  values (sa.id, v_prof, 'admin', btrim(p_demande->>'demandeur_nom'), v_mail, nullif(btrim(p_demande->>'contact_tel'),''), v_date, v_per,
    n->>'code', n->>'libelle', nullif(btrim(p_demande->>'precision'),''), nullif(p_demande->>'nb_personnes','')::int,
    nullif(btrim(p_demande->>'remarque'),''), v_tarif, v_corbas,
    coalesce(nullif(p_demande->>'caution_menage','')::numeric, (t->>'menage')::numeric),
    coalesce(nullif(p_demande->>'caution_reparation','')::numeric, (t->>'reparation')::numeric), true, v_statut,
    case when v_statut = 'option' then auj + p.delai_paiement end, case when v_statut = 'option' then app.ft_jeton() end,
    app.ft_resa_hist('Service des sports', 'demande', 'Réservation saisie par le service des sports'
      || case when v_date < auj + p.delai_min_jours then ' (exceptionnelle : moins de ' || p.delai_min_jours || ' jours)' else '' end)
    || case when v_evt is not null then app.ft_resa_hist('Service des sports', v_evt, null) else '[]'::jsonb end)
  returning * into r;
  return jsonb_build_object('id', r.id, 'evt', v_evt);
end $$;

-- ---------- Mails : le service est aussi prévenu des paiements ----------
create or replace function public.ft_resa_mail_preparer(p_token text, p_resa bigint, p_evt text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s app.sessions; r public.ft_reservations; dest text; lid bigint; v_cle text; derniere jsonb; p public.ft_resa_profils;
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
    if coalesce((select g.valeur from public.ft_reglages g where g.cle = 'cfg_mail_resa'), '1') = '0' then
      return jsonb_build_object('deja', true, 'coupe', true);
    end if;
    dest := app.ft_mail_service();
  elsif p_evt in ('validee','pieces','refusee','reservee','annulee') then
    if s.role <> 'admin' then raise exception 'Réservé à l''administrateur.'; end if;
    if derniere->>'action' <> p_evt then raise exception 'Événement périmé.'; end if;
    dest := r.contact_mail;
  else raise exception 'Événement inconnu.'; end if;
  v_cle := 'salle:' || r.id || ':' || p_evt || ':' || jsonb_array_length(r.historique);
  if exists (select 1 from public.ft_mails m where m.demande_id = v_cle and m.statut in ('envoye','en_cours')) then return jsonb_build_object('deja', true); end if;
  if dest is null then return jsonb_build_object('deja', true, 'sans_adresse', true); end if;
  insert into public.ft_mails(saison, demande_id, association, destinataire) values (null, v_cle, r.demandeur_nom, dest) returning id into lid;
  select * into p from public.ft_resa_profils where profil = r.profil;
  return jsonb_build_object('deja', false, 'log', lid, 'dest', dest, 'evt', p_evt,
    'resa', app.ft_resa_json(r, true) - 'historique', 'delai', p.delai_paiement);
end $$;

create or replace function app.ft_mail_service()
returns text language sql stable set search_path = '' as $$
  select coalesce(nullif(btrim((select g.valeur from public.ft_reglages g where g.cle = 'mail_resa')),''),
                  nullif(btrim((select g.valeur from public.ft_reglages g where g.cle = 'mail_dest')),''), 'sports@ville-corbas.fr');
$$;

-- ---------- Paiement en ligne (appelé uniquement par la fonction serveur fusiontest-paiement) ----------
-- Lien de paiement : paiement.html?r=<id>&k=<jeton> (le jeton remplace la connexion)
create or replace function public.ft_paiement_infos(p_resa bigint, p_jeton text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.ft_reservations;
begin
  if not app.ft_est_serveur() then raise exception 'Réservé au serveur.'; end if;
  perform app.ft_resa_expirer();
  select * into r from public.ft_reservations where id = p_resa and pay_jeton is not null and pay_jeton = p_jeton;
  if not found then raise exception 'Lien de paiement invalide.'; end if;
  return jsonb_build_object('id', r.id, 'salle', (select nom from public.ft_salles where id = r.salle_id),
    'adresse', (select adresse from public.ft_salles where id = r.salle_id),
    'demandeur_nom', r.demandeur_nom, 'contact_mail', r.contact_mail, 'date', r.date, 'periode', r.periode,
    'nature_libelle', r.nature_libelle, 'tarif', r.tarif, 'caution_menage', r.caution_menage, 'caution_reparation', r.caution_reparation,
    'echeance', r.echeance, 'veille', app.ft_veille_ouvree(r.date), 'statut', r.statut, 'paye_le', r.paye_le, 'paye_mode', r.paye_mode);
end $$;

-- Paiement confirmé : réservation confirmée, deux mails à préparer (demandeur + service des sports)
create or replace function public.ft_paiement_confirmer(p_resa bigint, p_jeton text, p_mode text, p_ref text, p_montant numeric)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.ft_reservations; l1 bigint; l2 bigint; d_serv text;
begin
  if not app.ft_est_serveur() then raise exception 'Réservé au serveur.'; end if;
  perform app.ft_resa_expirer();
  select * into r from public.ft_reservations where id = p_resa and pay_jeton is not null and pay_jeton = p_jeton for update;
  if not found then raise exception 'Lien de paiement invalide.'; end if;
  if r.statut = 'reservee' and r.paye_le is not null then return jsonb_build_object('deja', true); end if;
  if r.statut <> 'option' then raise exception 'Cette réservation n''attend pas de paiement (délai dépassé ou annulée).'; end if;
  if p_montant is not null and p_montant <> r.tarif then raise exception 'Montant payé différent du montant dû.'; end if;
  update public.ft_reservations set statut = 'reservee', paye_le = now(), paye_mode = p_mode, paye_ref = p_ref, maj = now(),
    historique = historique || app.ft_resa_hist(r.demandeur_nom, 'payee_en_ligne',
      'Paiement en ligne de ' || r.tarif || ' €' || case when p_mode = 'simulation' then ' (démonstration, aucun prélèvement)' else ' (Stripe ' || coalesce(p_ref,'') || ')' end)
  where id = r.id returning * into r;
  d_serv := app.ft_mail_service();
  insert into public.ft_mails(saison, demande_id, association, destinataire) values (null, 'salle:' || r.id || ':payee_service', r.demandeur_nom, d_serv) returning id into l1;
  if r.contact_mail is not null then
    insert into public.ft_mails(saison, demande_id, association, destinataire) values (null, 'salle:' || r.id || ':payee', r.demandeur_nom, r.contact_mail) returning id into l2;
  end if;
  return jsonb_build_object('deja', false, 'resa', app.ft_resa_json(r, true) - 'historique', 'dest_service', d_serv, 'log_service', l1,
    'dest_usager', r.contact_mail, 'log_usager', l2);
end $$;

revoke execute on function public.ft_resa_mail_preparer(text, bigint, text) from public, anon, authenticated;
revoke execute on function public.ft_paiement_infos(bigint, text) from public, anon, authenticated;
revoke execute on function public.ft_paiement_confirmer(bigint, text, text, text, numeric) from public, anon, authenticated;
grant execute on function public.ft_resa_mail_preparer(text, bigint, text) to service_role;
grant execute on function public.ft_paiement_infos(bigint, text) to service_role;
grant execute on function public.ft_paiement_confirmer(bigint, text, text, text, numeric) to service_role;

-- ---------- Accueil administrateur : paiements reçus en ligne (7 derniers jours) ----------
create or replace function public.ft_resa_a_traiter(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest');
begin
  perform app.exiger(s, array['admin']);
  perform app.ft_resa_expirer();
  return jsonb_build_object(
    'nouvelles', (select count(*) from public.ft_reservations where statut = 'demande'),
    'pieces', (select count(*) from public.ft_reservations where statut = 'pieces'),
    'paiement', (select count(*) from public.ft_reservations where statut = 'option'),
    'payees', (select count(*) from public.ft_reservations where paye_mode in ('simulation','stripe') and paye_le > now() - interval '7 days'),
    'mail_actif', coalesce((select g.valeur from public.ft_reglages g where g.cle = 'cfg_mail_resa'), '1') <> '0');
end $$;

-- ---------- Réglages par défaut (règles du service, 13/11/2026) ----------
update public.ft_resa_profils set delai_paiement = 7, horizon_mois = 6, delai_min_jours = 30;
update public.ft_resa_profils set natures = (
  select jsonb_agg(case when x->>'code' = 'mariage' then x || '{"horizon_mois":12}'::jsonb else x end) from jsonb_array_elements(natures) x)
where profil = 'particulier';
update public.ft_resa_profils set natures = (
  select jsonb_agg(case x->>'code'
    when 'festif' then x || '{"libelle":"Manifestation sans activité lucrative (buvette possible)","tarif":0}'::jsonb
    when 'vente' then x || '{"libelle":"Manifestation avec activité lucrative (loto, vente…)","tarif":200}'::jsonb
    else x || '{"tarif":0}'::jsonb end) from jsonb_array_elements(natures) x)
where profil = 'asso';
update public.ft_resa_profils set natures = (select jsonb_agg(x || '{"tarif":200}'::jsonb) from jsonb_array_elements(natures) x) where profil = 'particulier';
update public.ft_resa_profils set natures = (select jsonb_agg(x || '{"tarif":400}'::jsonb) from jsonb_array_elements(natures) x) where profil = 'entreprise';

-- Salle existante : tarifs Corbas / extérieur, cautions, capacité
update public.ft_salles x set capacite_max = coalesce(x.capacite_max, nullif(regexp_replace(coalesce(x.capacite,''), '\D.*$', ''), '')::int),
  tarifs = (select jsonb_object_agg(p.profil, (select jsonb_object_agg(n->>'code', jsonb_build_object('ouvert', true,
      'corbas', case p.profil when 'particulier' then 200 when 'entreprise' then 400 else (n->>'tarif')::numeric end,
      'ext',    case p.profil when 'particulier' then 400 when 'entreprise' then 600 else (n->>'tarif')::numeric end,
      'menage', 150, 'reparation', 800)) from jsonb_array_elements(p.natures) n))
    from public.ft_resa_profils p)
where not x.supprime and x.tarifs = '{}'::jsonb;

-- Associations : PV de la dernière assemblée générale obligatoire pour toutes les natures
update public.ft_resa_profils set natures = (
  select jsonb_agg(case when coalesce(x->'pieces','[]'::jsonb) ? 'PV de la dernière assemblée générale' then x
    else x || jsonb_build_object('pieces', coalesce(x->'pieces','[]'::jsonb) || '["PV de la dernière assemblée générale"]'::jsonb) end)
  from jsonb_array_elements(natures) x)
where profil = 'asso';
