-- Étape 7 — Salles : visibilité par profil, réglages groupés, modification / suppression / archive des demandes (18/11/2026)

alter table public.ft_salles add column if not exists profils text[] not null default '{asso,entreprise,particulier}';
alter table public.ft_reservations add column if not exists archive boolean not null default false;
alter table public.ft_reservations add column if not exists archive_le timestamptz;

-- Patch des fonctions existantes (remplacement ciblé dans leur définition actuelle)
create or replace function app.ft_patch(p_fn regprocedure, p_old text, p_new text) returns void
language plpgsql set search_path to '' as $$
declare d text := pg_get_functiondef(p_fn); n text;
begin
  if position(p_old in d) = 0 then raise exception 'Patch introuvable dans % : %', p_fn, left(p_old, 80); end if;
  n := replace(d, p_old, p_new);
  execute n;
end $$;

-- 1. Liste des salles : visibilité par profil + champ profils
select app.ft_patch('public.ft_salles_liste(text)',
  $o$'actif', x.actif, 'ordre', x.ordre,$o$, $n$'actif', x.actif, 'ordre', x.ordre, 'profils', x.profils,$n$);
select app.ft_patch('public.ft_salles_liste(text)',
  $o$where not x.supprime and (s.role = 'admin' or x.actif))$o$,
  $n$where not x.supprime and (s.role = 'admin' or (x.actif and s.role = any(x.profils))))$n$);

-- 2. Enregistrement d'une salle : profils visibles
select app.ft_patch('public.ft_salle_sauver(text,jsonb)',
  $o$dispo, tarifs, un_par_weekend, ordre, actif)$o$, $n$dispo, tarifs, un_par_weekend, ordre, actif, profils)$n$);
select app.ft_patch('public.ft_salle_sauver(text,jsonb)',
  $o$coalesce((select max(ordre) + 1 from public.ft_salles), 1), coalesce((p_salle->>'actif')::boolean, true))$o$,
  $n$coalesce((select max(ordre) + 1 from public.ft_salles), 1), coalesce((p_salle->>'actif')::boolean, true),
      coalesce((select array_agg(x) from jsonb_array_elements_text(p_salle->'profils') x where x in ('asso','entreprise','particulier')), '{asso,entreprise,particulier}'))$n$);
select app.ft_patch('public.ft_salle_sauver(text,jsonb)',
  $o$actif = coalesce((p_salle->>'actif')::boolean, actif), maj = now()$o$,
  $n$actif = coalesce((p_salle->>'actif')::boolean, actif),
      profils = case when jsonb_typeof(p_salle->'profils') = 'array'
        then coalesce((select array_agg(x) from jsonb_array_elements_text(p_salle->'profils') x where x in ('asso','entreprise','particulier')), '{}')
        else profils end, maj = now()$n$);

-- 3. Demande en ligne : salle visible pour le profil + forfait week-end
select app.ft_patch('public.ft_resa_demander(text,jsonb,jsonb)',
  $o$and actif and not supprime;
  if not found then raise exception 'Salle introuvable.'; end if;$o$,
  $n$and actif and not supprime and s.role = any(profils);
  if not found then raise exception 'Salle introuvable.'; end if;$n$);
select app.ft_patch('public.ft_resa_demander(text,jsonb,jsonb)',
  $o$t := app.ft_resa_tarif(sa, s.role, n, v_corbas);$o$,
  $n$t := app.ft_resa_tarif(sa, s.role, n, v_corbas);
  if v_per = 'weekend' and nullif(sa.tarifs -> s.role -> (n->>'code') ->> (case when v_corbas then 'corbas_we' else 'ext_we' end), '') is not null then
    t := t || jsonb_build_object('location', (sa.tarifs -> s.role -> (n->>'code') ->> (case when v_corbas then 'corbas_we' else 'ext_we' end))::numeric);
  end if;$n$);
select app.ft_patch('public.ft_resa_admin_creer(text,jsonb)',
  $o$t := app.ft_resa_tarif(sa, v_prof, n, v_corbas);$o$,
  $n$t := app.ft_resa_tarif(sa, v_prof, n, v_corbas);
  if v_per = 'weekend' and nullif(sa.tarifs -> v_prof -> (n->>'code') ->> (case when v_corbas then 'corbas_we' else 'ext_we' end), '') is not null then
    t := t || jsonb_build_object('location', (sa.tarifs -> v_prof -> (n->>'code') ->> (case when v_corbas then 'corbas_we' else 'ext_we' end))::numeric);
  end if;$n$);

-- 4. Les demandes archivées ne bloquent plus le planning et sortent des listes usager / compteurs
select app.ft_patch('app.ft_salle_occupation(bigint,date,date,text)',
  $o$where r.salle_id = p_salle and r.statut in ('demande','pieces','option','reservee')$o$,
  $n$where r.salle_id = p_salle and r.statut in ('demande','pieces','option','reservee') and not r.archive$n$);
select app.ft_patch('public.ft_resa_mes_demandes(text)',
  $o$where r.profil = s.role and r.demandeur = s.nom)$o$, $n$where r.profil = s.role and r.demandeur = s.nom and not r.archive)$n$);
select app.ft_patch('public.ft_resa_a_traiter(text)',
  $o$where statut = 'demande'),$o$, $n$where statut = 'demande' and not archive),$n$);
select app.ft_patch('public.ft_resa_a_traiter(text)',
  $o$where statut = 'pieces'),$o$, $n$where statut = 'pieces' and not archive),$n$);
select app.ft_patch('public.ft_resa_a_traiter(text)',
  $o$where statut = 'option'),$o$, $n$where statut = 'option' and not archive),$n$);
select app.ft_patch('app.ft_resa_json(public.ft_reservations,boolean)',
  $o$'statut', r.statut,$o$, $n$'statut', r.statut, 'archive', r.archive, 'archive_le', r.archive_le,$n$);
-- Purge automatique des archives de plus d'un an
select app.ft_patch('public.ft_resa_liste(text)',
  $o$perform app.ft_resa_expirer();$o$,
  $n$perform app.ft_resa_expirer();
  delete from public.ft_resa_pieces where resa_id in (select id from public.ft_reservations where archive and archive_le < now() - interval '1 year');
  delete from public.ft_reservations where archive and archive_le < now() - interval '1 year';$n$);

drop function app.ft_patch(regprocedure, text, text);

-- 5. Suppression définitive, archive, restauration
create or replace function public.ft_resa_supprimer(p_token text, p_resa bigint, p_mode text)
returns void language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); r public.ft_reservations;
begin
  perform app.exiger(s, array['admin']);
  select * into r from public.ft_reservations where id = p_resa;
  if not found then raise exception 'Demande introuvable.'; end if;
  if p_mode = 'definitif' then
    delete from public.ft_resa_pieces where resa_id = r.id;
    delete from public.ft_reservations where id = r.id;
  elsif p_mode = 'archive' then
    update public.ft_reservations set archive = true, archive_le = now(), maj = now(),
      historique = historique || app.ft_resa_hist('Service des sports', 'archivee', 'Supprimée avec archive (conservée 1 an)')
    where id = r.id;
  elsif p_mode = 'restaurer' then
    if not r.archive then return; end if;
    if r.statut in ('demande','pieces','option','reservee') and exists (
        select 1 from app.ft_resa_slots(r.date, r.periode) sl
        join app.ft_salle_occupation(r.salle_id, r.date, r.date + 1, null) o on o.d = sl.d and o.s = sl.s) then
      raise exception 'Le créneau a été repris entre-temps : restauration impossible.';
    end if;
    update public.ft_reservations set archive = false, archive_le = null, maj = now(),
      historique = historique || app.ft_resa_hist('Service des sports', 'restauree', 'Restaurée depuis les archives')
    where id = r.id;
  else raise exception 'Action inconnue.';
  end if;
end $$;

-- 6. Modification complète d'une demande par l'administrateur
create or replace function public.ft_resa_modifier(p_token text, p_resa bigint, p_data jsonb)
returns void language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); r public.ft_reservations; sa public.ft_salles; p public.ft_resa_profils;
  n jsonb; v_salle bigint; v_date date; v_per text; v_prof text; v_nat text; v_mail text; chg text[] := '{}';
begin
  perform app.exiger(s, array['admin']);
  select * into r from public.ft_reservations where id = p_resa;
  if not found then raise exception 'Demande introuvable.'; end if;
  v_salle := coalesce(nullif(p_data->>'salle_id','')::bigint, r.salle_id);
  v_date := coalesce(nullif(p_data->>'date','')::date, r.date);
  v_per := coalesce(nullif(p_data->>'periode',''), r.periode);
  v_prof := coalesce(nullif(p_data->>'profil',''), r.profil);
  v_nat := coalesce(nullif(p_data->>'nature',''), r.nature);
  select * into sa from public.ft_salles where id = v_salle and not supprime;
  if not found then raise exception 'Salle introuvable.'; end if;
  if not (v_per = any(sa.periodes)) then raise exception 'Période non proposée pour cette salle.'; end if;
  if v_per = 'weekend' and extract(dow from v_date) <> 6 then raise exception 'Une location week-end commence un samedi.'; end if;
  select * into p from public.ft_resa_profils where profil = v_prof;
  if not found then raise exception 'Profil inconnu.'; end if;
  select x into n from jsonb_array_elements(p.natures) x where x->>'code' = v_nat;
  if n is null then raise exception 'Nature inconnue pour ce profil.'; end if;
  v_mail := nullif(btrim(coalesce(p_data->>'contact_mail', r.contact_mail)),'');
  if v_mail is not null and v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Mail de contact invalide.'; end if;
  if coalesce(btrim(coalesce(p_data->>'demandeur_nom', r.demandeur_nom)),'') = '' then raise exception 'Indiquez le nom du demandeur.'; end if;
  if (v_salle, v_date, v_per) is distinct from (r.salle_id, r.date, r.periode) and not r.archive
     and r.statut in ('demande','pieces','option','reservee') then
    perform pg_advisory_xact_lock(91000 + v_salle);
    if exists (select 1 from app.ft_resa_slots(v_date, v_per) sl
               join app.ft_salle_occupation(v_salle, v_date, v_date + 1, null) o on o.d = sl.d and o.s = sl.s
               where o.resa_id is distinct from r.id) then
      raise exception 'Le nouveau créneau est déjà occupé ou bloqué.';
    end if;
  end if;
  if v_salle <> r.salle_id then chg := chg || 'salle'; end if;
  if v_date <> r.date then chg := chg || ('date ' || to_char(r.date,'DD/MM/YYYY') || ' → ' || to_char(v_date,'DD/MM/YYYY')); end if;
  if v_per <> r.periode then chg := chg || 'période'; end if;
  update public.ft_reservations set
    salle_id = v_salle, date = v_date, periode = v_per, profil = v_prof, nature = v_nat, nature_libelle = n->>'libelle',
    demandeur_nom = btrim(coalesce(p_data->>'demandeur_nom', demandeur_nom)), contact_mail = v_mail,
    contact_tel = nullif(btrim(coalesce(p_data->>'contact_tel', contact_tel)),''),
    precision_nature = case when p_data ? 'precision' then nullif(btrim(p_data->>'precision'),'') else precision_nature end,
    nb_personnes = case when p_data ? 'nb_personnes' then nullif(p_data->>'nb_personnes','')::int else nb_personnes end,
    remarque = case when p_data ? 'remarque' then nullif(btrim(p_data->>'remarque'),'') else remarque end,
    corbassien = case when p_data ? 'corbassien' then (nullif(p_data->>'corbassien',''))::boolean else corbassien end,
    tarif = case when p_data ? 'tarif' then nullif(p_data->>'tarif','')::numeric else tarif end,
    caution_menage = case when p_data ? 'caution_menage' then nullif(p_data->>'caution_menage','')::numeric else caution_menage end,
    caution_reparation = case when p_data ? 'caution_reparation' then nullif(p_data->>'caution_reparation','')::numeric else caution_reparation end,
    statut = coalesce(nullif(p_data->>'statut',''), statut),
    maj = now(),
    historique = historique || app.ft_resa_hist('Service des sports', 'modifiee',
      'Modifiée par le service' || case when cardinality(chg) > 0 then ' (' || array_to_string(chg, ', ') || ')' else '' end)
  where id = r.id;
end $$;

-- 7. Pièces jointes gérées par l'administrateur
create or replace function public.ft_resa_piece_admin_ajouter(p_token text, p_resa bigint, p_libelle text, p_nom text, p_type text, p_contenu text)
returns void language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest');
begin
  perform app.exiger(s, array['admin']);
  if not exists (select 1 from public.ft_reservations where id = p_resa) then raise exception 'Demande introuvable.'; end if;
  if coalesce(p_contenu,'') = '' then raise exception 'Fichier vide.'; end if;
  if length(p_contenu) > 7000000 then raise exception 'Fichier trop lourd (5 Mo maximum).'; end if;
  insert into public.ft_resa_pieces(resa_id, libelle, nom, type, taille, contenu)
  values (p_resa, coalesce(nullif(btrim(p_libelle),''), 'Pièce ajoutée par le service'), p_nom, p_type, length(p_contenu) * 3 / 4, p_contenu);
  update public.ft_reservations set maj = now(),
    historique = historique || app.ft_resa_hist('Service des sports', 'piece', 'Pièce ajoutée par le service : ' || coalesce(nullif(btrim(p_libelle),''), p_nom))
  where id = p_resa;
end $$;

create or replace function public.ft_resa_piece_supprimer(p_token text, p_piece bigint)
returns void language plpgsql security definer set search_path to '' as $$
declare s app.sessions := app.session(p_token, 'fusiontest'); pc public.ft_resa_pieces;
begin
  perform app.exiger(s, array['admin']);
  delete from public.ft_resa_pieces where id = p_piece returning * into pc;
  if not found then raise exception 'Pièce introuvable.'; end if;
  update public.ft_reservations set maj = now(),
    historique = historique || app.ft_resa_hist('Service des sports', 'piece_supprimee', 'Pièce supprimée : ' || coalesce(pc.libelle, pc.nom))
  where id = pc.resa_id;
end $$;
