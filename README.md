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

## Étape 4 — Orientation, tarifs et paiement en ligne (13/11/2026)

- Usager : questionnaire avant le planning (nature, nombre de personnes, Corbas ou extérieur) → seules les salles qui conviennent, avec le bon tarif ; planning visible à partir de J+30 et jusqu'à 6 mois (12 mois pour un mariage) ; message « traitée sous 15 jours à 1 mois » au dépôt.
- Couleurs : jaune = demande déposée, orange = validée (lien de paiement envoyé, à payer sous 7 jours), rouge = payée / réservée.
- Salle (admin) : capacité maximale, disponibilité par jour, tarifs Corbas / extérieur et cautions par profil et par nature, « un seul événement par week-end ».
- Admin : montants modifiables avant validation, réservation exceptionnelle à moins d'un mois, paiement au guichet ou en ligne.
- Paiement : `paiement.html` + fonction `fusiontest-paiement`. Sans clé Stripe : paiement de démonstration (aucun argent). Avec `STRIPE_SECRET_KEY` (sk_test_…) et `STRIPE_WEBHOOK_SECRET` : vrai parcours Stripe en mode test. Après paiement : mail au demandeur et au service, réservation confirmée.
- Base : `supabase/salles_v2.sql` (migration `ft_salles_v2`).
