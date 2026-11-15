-- =====================================================================
-- SITE TEST — Salles municipales, version 3 (15/11/2026)
-- Délibération VILLE_2025DL069 du 26/06/2025 (prêt de salles, élections
-- municipales et métropolitaines 2026) :
--   * 5 salles : Chênes, La Clairière, réception des Taillis, Pagode, Fêtes
--   * cautions du règlement : Taillis et Fêtes 640 € (dégâts) / 160 € (ménage)
--   * nature « Réunion électorale » gratuite, en soirée, jours propres à chaque
--     salle, une fois par mois et par liste
-- Nouveautés génériques :
--   * tarifs[profil][nature].jours (0 = dimanche … 6) et .periodes : la nature
--     n'est proposée que ces jours-là / sur ces créneaux dans cette salle
--   * natures[].max_par_mois : nombre maximum de demandes par mois et par demandeur
-- Appliqué dans Supabase par la migration ft_salles_v3.
-- =====================================================================

create or replace function public.ft_resa_demander(p_token text, p_demande jsonb, p_pieces jsonb)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
declare s app.sessions := app.ft_resa_session(p_token); p public.ft_resa_profils; sa public.ft_salles; u app.ft_usagers;
  v_date date := nullif(p_demande->>'date','')::date; v_per text := p_demande->>'periode'; n jsonb; fin date; auj date;
  manque text[]; pc jsonb; r public.ft_reservations; v_nom text; v_mail text; v_tel text; t jsonb; x jsonb; v_max int;
  v_nb int := nullif(p_demande->>'nb_personnes','')::int; v_corbas boolean := (nullif(p_demande->>'corbassien',''))::boolean;
begin
  if s.role not in ('asso','entreprise','particulier') then raise exception 'Réservé aux associations, entreprises et particuliers.'; end if;
  select * into p from public.ft_resa_profils where profil = s.role;
  if not p.ouvert then raise exception 'Les réservations sont fermées pour le moment.'; end if;
  select * into sa from public.ft_salles where id = nullif(p_demande->>'salle_id','')::bigint and actif and not supprime;
  if not found then raise exception 'Salle introuvable.'; end if;
  select y into n from jsonb_array_elements(p.natures) y where y->>'code' = p_demande->>'nature';
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
  -- Jours et créneaux propres à cette nature dans cette salle
  x := coalesce(sa.tarifs -> s.role -> (n->>'code'), '{}'::jsonb);
  if jsonb_typeof(x->'jours') = 'array' and not (x->'jours') @> to_jsonb(extract(dow from v_date)::int) then
    raise exception 'Pour « % », cette salle n''est proposée que certains jours de la semaine.', n->>'libelle';
  end if;
  if jsonb_typeof(x->'periodes') = 'array' and not (x->'periodes') ? v_per then
    raise exception 'Pour « % », cette période n''est pas proposée dans cette salle.', n->>'libelle';
  end if;
  if coalesce((n->>'precision')::boolean, false) and coalesce(btrim(p_demande->>'precision'),'') = '' then raise exception 'Précisez la nature de votre demande.'; end if;
  if jsonb_typeof(coalesce(p_pieces,'[]'::jsonb)) <> 'array' then raise exception 'Pièces invalides.'; end if;
  p_pieces := coalesce(p_pieces, '[]'::jsonb);
  select array_agg(y) into manque from jsonb_array_elements_text(coalesce(n->'pieces','[]'::jsonb)) y
    where not exists (select 1 from jsonb_array_elements(p_pieces) pc2 where pc2->>'libelle' = y and coalesce(pc2->>'contenu','') <> '');
  if manque is not null then raise exception 'Pièce(s) manquante(s) : %', array_to_string(manque, ', '); end if;
  for pc in select * from jsonb_array_elements(p_pieces) loop
    if length(coalesce(pc->>'contenu','')) > 7000000 then raise exception 'Fichier trop lourd : % (5 Mo maximum).', pc->>'nom'; end if;
  end loop;
  -- Nombre maximum de demandes par mois pour cette nature (ex. une réunion électorale par mois et par liste)
  v_max := nullif(n->>'max_par_mois','')::int;
  if v_max is not null and (select count(*) from public.ft_reservations
      where profil = s.role and demandeur = s.nom and nature = n->>'code' and statut in ('demande','pieces','option','reservee')
        and date_trunc('month', date) = date_trunc('month', v_date)) >= v_max then
    raise exception 'Pour « % », % demande(s) par mois au maximum : vous en avez déjà pour ce mois-ci.', n->>'libelle', v_max;
  end if;
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
  select r.id, y->>'libelle', y->>'nom', y->>'type', length(y->>'contenu') * 3 / 4, y->>'contenu'
  from jsonb_array_elements(p_pieces) y where coalesce(y->>'contenu','') <> '';
  return jsonb_build_object('id', r.id);
end $function$;

-- ---------- Nature « Réunion électorale » (associations et particuliers) ----------
update public.ft_resa_profils
set natures = natures || jsonb_build_array(jsonb_build_object(
      'code', 'election', 'tarif', 0, 'precision', false, 'max_par_mois', 1,
      'libelle', 'Réunion électorale (liste candidate aux municipales / métropolitaines)',
      'pieces', jsonb_build_array('Attestation d''assurance', 'Justificatif de la liste candidate (tête de liste ou mandataire)'))),
    maj = now()
where profil in ('asso','particulier')
  and not exists (select 1 from jsonb_array_elements(natures) y where y->>'code' = 'election');

-- ---------- Salles de la délibération ----------
do $$
declare
  base jsonb; tpl public.ft_salles;
  -- nom, jours de la réunion électorale (1 = lundi … 5 = vendredi), caution réparation, caution ménage, ordre
  def jsonb := '[
    {"nom":"Salle des Chênes",                             "jours":[1,2,4,5], "rep":null, "men":null, "ordre":1},
    {"nom":"Salle La Clairière",                           "jours":[4,5],     "rep":null, "men":null, "ordre":2},
    {"nom":"Salle de réception du Complexe des Taillis",   "jours":[5],       "rep":640,  "men":160,  "ordre":3},
    {"nom":"Salle de la Pagode",                           "jours":[1,5],     "rep":null, "men":null, "ordre":4},
    {"nom":"Salle des Fêtes",                              "jours":[4,5],     "rep":640,  "men":160,  "ordre":5}]';
  d jsonb; prof text; nat text; tar jsonb; v_id bigint;
begin
  select * into tpl from public.ft_salles where id = 1;          -- Salle des Fêtes existante = modèle
  base := tpl.tarifs;
  for d in select * from jsonb_array_elements(def) loop
    tar := '{}'::jsonb;
    for prof in select jsonb_object_keys(base) loop
      tar := jsonb_set(tar, array[prof], '{}'::jsonb);
      for nat in select jsonb_object_keys(base -> prof) loop
        tar := jsonb_set(tar, array[prof, nat],
          ((base -> prof -> nat) - 'menage' - 'reparation') || jsonb_strip_nulls(jsonb_build_object('menage', d->'men', 'reparation', d->'rep')));
      end loop;
    end loop;
    foreach prof in array array['asso','particulier'] loop
      tar := jsonb_set(tar, array[prof, 'election'], jsonb_strip_nulls(jsonb_build_object(
        'ouvert', true, 'corbas', 0, 'ext', 0, 'menage', d->'men', 'reparation', d->'rep',
        'jours', d->'jours', 'periodes', '["soir"]'::jsonb)));
    end loop;

    if d->>'nom' = 'Salle des Fêtes' then
      update public.ft_salles set nom = d->>'nom', tarifs = tar, ordre = (d->>'ordre')::int, maj = now() where id = 1;
    else
      select id into v_id from public.ft_salles where nom = d->>'nom' and not supprime;
      if v_id is null then
        insert into public.ft_salles(nom, periodes, enchainement, conditions, dispo, tarifs, un_par_weekend, ordre, actif)
        values (d->>'nom', tpl.periodes, tpl.enchainement, '{}'::jsonb, '{}'::jsonb, tar, true, (d->>'ordre')::int, true);
      else
        update public.ft_salles set tarifs = tar, ordre = (d->>'ordre')::int, maj = now() where id = v_id;
      end if;
    end if;
  end loop;
end $$;
