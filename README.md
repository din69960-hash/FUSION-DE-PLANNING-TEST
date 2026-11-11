# FUSION-DE-PLANNING — SITE TEST

Copie de test du site FUSION-DE-PLANNING, pour développer la réservation des salles municipales
(associations, entreprises, particuliers) sans toucher au site en service.

- Données : tables Supabase `ft_*` (copie des tables `fu_*` du site réel au 11/11/2026), sessions `fusiontest`.
- Mail : fonction Supabase `fusiontest-mail` (objet préfixé « [TEST] »).
- Si le test ne convient pas : supprimer ce dépôt et les tables/fonctions `ft_*` ; le site réel n'est pas concerné.

## Étape 3 — Salles municipales (`salles.html`)

- Usagers (association, entreprise, particulier) : visite des salles, planning mois par mois, demande de réservation avec pièces, suivi « Mes demandes ».
- Administrateur : demandes (valider, pièces manquantes, refuser, paiement reçu, annuler), planning avec les noms, dates bloquées, fiches des salles, règles par profil.
- Base : `supabase/salles.sql` (tables `ft_salles`, `ft_resa_*`, `ft_reservations`, `ft_salle_blocages`). Mails : fonction `fusiontest-salles-mail`.
