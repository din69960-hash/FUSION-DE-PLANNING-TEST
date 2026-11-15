-- =====================================================================
-- SITE TEST — Créneaux annuels en salles municipales (15/11/2026)
-- * Les créneaux réguliers des associations en salle municipale sont rangés
--   dans ft_creneaux avec lieu = 'sm-<id de ft_salles>' (pas de sous-espace :
--   espace = 'Salle entière').
-- * Ouverture de la saisie séparée : ft_saisons.creneaux_salles_ouvert.
-- * Un créneau régulier rend la période correspondante « indisponible » dans le
--   planning des locations ponctuelles (salles.html), chaque semaine de la saison
--   (1er septembre → 31 août) :
--     matin = avant 12 h, après-midi = 12 h → 18 h, soir = après 18 h.
-- Appliqué dans Supabase par la migration ft_creneaux_salles.
-- =====================================================================

alter table public.ft_saisons add column if not exists creneaux_salles_ouvert boolean not null default false;

create or replace function public.ft_saison_ouvrir(p_token text, p_annee integer, p_module text, p_ouvert boolean)
 returns void language plpgsql security definer set search_path to '' as $function$
declare s app.sessions := app.session(p_token, 'fusiontest');
begin
  perform app.exiger(s, array['admin']);
  if p_module = 'creneaux' then
    update public.ft_saisons set creneaux_ouvert = coalesce(p_ouvert,false), maj = now() where annee = p_annee and not supprime;
  elsif p_module = 'creneaux_salles' then
    update public.ft_saisons set creneaux_salles_ouvert = coalesce(p_ouvert,false), maj = now() where annee = p_annee and not supprime;
  elsif p_module = 'manif' then
    update public.ft_saisons set manif_ouvert = coalesce(p_ouvert,false), maj = now() where annee = p_annee and not supprime;
  else raise exception 'Module inconnu.'; end if;
  if not found then raise exception 'Saison inconnue.'; end if;
end $function$;

create or replace function public.ft_cr_enregistrer(p_token text, p_saison integer, p_association text, p_lieu text, p_lignes jsonb)
 returns integer language plpgsql security definer set search_path to '' as $function$
declare s app.sessions := app.session(p_token, 'fusiontest'); n int; ouvert boolean; salle boolean := p_lieu like 'sm-%';
begin
  select case when salle then creneaux_salles_ouvert else creneaux_ouvert end into ouvert
    from public.ft_saisons where annee = p_saison and not supprime;
  if not found then raise exception 'Saison inconnue.'; end if;
  if salle and not exists (select 1 from public.ft_salles where 'sm-' || id = p_lieu and not supprime) then
    raise exception 'Salle municipale inconnue.';
  end if;
  if s.role = 'asso' then
    if app.norm(p_association) <> app.norm(s.nom) then raise exception 'Vous ne pouvez enregistrer que les créneaux de votre association.'; end if;
    if not ouvert then raise exception 'La saisie des créneaux % est fermée pour cette saison.', case when salle then 'en salles municipales' else 'à l''année' end; end if;
  else perform app.exiger(s, array['admin']); end if;
  -- les anciens créneaux de l'association sur ce lieu sont remplacés
  update public.ft_creneaux set supprime = true
   where saison = p_saison and not supprime and app.norm(association) = app.norm(p_association) and lieu = p_lieu;
  insert into public.ft_creneaux(saison, association, lieu, lieu_label, creneau, jour, espace, heure_debut, heure_fin, created_at)
  select p_saison, p_association, p_lieu, r->>'lieu_label', (r->>'creneau')::int, r->>'jour', r->>'espace',
         r->>'heure_debut', r->>'heure_fin', now()
    from jsonb_array_elements(coalesce(p_lignes,'[]')) r;
  get diagnostics n = row_count;
  return n;
end $function$;

-- Périodes de location (matin, après-midi, soir) touchées par un horaire « HH:MM » → « HH:MM »
create or replace function app.ft_periodes_heures(p_deb text, p_fin text)
returns text[] language sql immutable set search_path = '' as $$
  select coalesce(array_agg(v.p order by v.o), '{}')
  from (values (1, 'matin', time '00:00', time '12:00'), (2, 'apres_midi', time '12:00', time '18:00'), (3, 'soir', time '18:00', time '24:00')) v(o, p, a, b)
  where p_deb ~ '^\d{1,2}:\d{2}$' and p_fin ~ '^\d{1,2}:\d{2}$' and p_deb::time < p_fin::time
    and p_deb::time < v.b and p_fin::time > v.a;
$$;

create or replace function app.ft_salle_occupation(p_salle bigint, p_debut date, p_fin date, p_profil text)
 returns table(d date, s text, e text, resa_id bigint, profil text, demandeur text, nom text, motif text, prio integer)
 language sql stable set search_path to '' as $function$
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
  -- créneaux réguliers des associations (créneaux annuels en salle municipale), chaque semaine de la saison
  select g::date, pp, 'bloque', null::bigint, 'asso', c.association, c.association,
         'Créneau régulier ' || c.heure_debut || '–' || c.heure_fin, 2
  from public.ft_creneaux c
  join public.ft_saisons sa on sa.annee = c.saison and not sa.supprime
  cross join lateral generate_series(greatest(make_date(c.saison, 9, 1), p_debut), least(make_date(c.saison + 1, 8, 31), p_fin), interval '1 day') g
  cross join lateral unnest(app.ft_periodes_heures(c.heure_debut, c.heure_fin)) pp
  where c.lieu = 'sm-' || p_salle and not c.supprime
    and extract(dow from g)::int = array_position(array['Dimanche','Lundi','Mardi','Mercredi','Jeudi','Vendredi','Samedi'], c.jour) - 1
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
  select distinct g::date, c, 'bloque', o.id, o.profil, o.demandeur, o.demandeur_nom, 'Un seul événement par week-end', 3
  from occ o, regle
  cross join lateral generate_series(o.d - ((extract(dow from o.d)::int + 2) % 7), o.d - ((extract(dow from o.d)::int + 2) % 7) + 2, interval '1 day') g
  cross join lateral unnest(array['matin','apres_midi','soir']) c
  where regle.un_par_weekend and extract(dow from o.d) in (5, 6, 0) and g::date between p_debut and p_fin;
$function$;
