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

## Étape 5 — Délibération des salles (élections 2026) (15/11/2026)

- Salles : Salle des Chênes, Salle La Clairière, Salle de réception du Complexe des Taillis, Salle de la Pagode, Salle des Fêtes.
- Cautions du règlement : Taillis et Fêtes 640 € (dégâts) / 160 € (ménage).
- Nature « Réunion électorale (liste candidate) » pour associations et particuliers : gratuite, en soirée, jours propres à chaque salle (Chênes lun/mar/jeu/ven, Clairière jeu/ven, Taillis ven, Pagode lun/ven, Fêtes jeu/ven), une demande par mois et par demandeur.
- Fiche salle (admin) : colonnes « Jours proposés » et « Créneau » par nature ; règles par profil : colonne « Max / mois / demandeur ».
- Base : `supabase/salles_v3.sql` (migration `ft_salles_v3`).

## Étape 6 — Créneaux annuels en salles municipales (15/11/2026)

- `creneaux.html?type=salles` : même outil que les créneaux des équipements (saisie, consultation, plannings, taux, bilan, ouverture), sur les salles des fiches (`ft_salles`), sans sous-espace. Créneaux rangés dans `ft_creneaux` avec `lieu = 'sm-<id>'`.
- Ouverture séparée : `ft_saisons.creneaux_salles_ouvert` (module `creneaux_salles`). Réglages propres : `cfg_taux_salles`, `cfg_bilan_salles`.
- Un créneau régulier rend « indisponible » la période correspondante (matin < 12 h, après-midi 12 h–18 h, soir > 18 h) chaque semaine de la saison (1/09 → 31/08) dans le planning des locations ponctuelles, et bloque les demandes.
- Menus : administrateur « Créneaux annuels — salles », association « Vos créneaux réguliers en salles municipales ». Planning des manifestations : plus de choix « Salle municipale ».
- Base : `supabase/creneaux_salles.sql` (migration `ft_creneaux_salles`).

## Étape 7 — Salles calibrées, réglages groupés, modification et archives (18/11/2026)

- 13 salles calibrées d'après les fiches d'information, le règlement intérieur, la procédure interne et les délibérations (2017, 2023 forfait week-end, 2024 obsèques) : adresse, capacité, profils qui voient la salle, périodes, cautions, tarifs votés (`supabase/salles_calibrage.sql`).
- Salle : « Visible par » (associations / entreprises / particuliers) ; forfaits « Week-end » Corbas / extérieur par nature.
- Admin › Salles : tableau de toutes les salles avec cases à cocher ; réglage groupé (visibilité, visible et réservable, un événement par week-end, tarifs, forfaits week-end, cautions, nature proposée, capacité) appliqué à toutes les salles cochées.
- Admin › Demandes : « Modifier » (salle, date, période, statut, profil, nature, demandeur, contacts, montants, remarque, pièces jointes ajoutées ou retirées) ; « Supprimer » avec archive (date libérée, demande gardée 1 an dans l'onglet Archives, restaurable) ou définitivement.
- Base : `supabase/salles_v4.sql` (migration `ft_salles_v4`).

## Étape 8 — Conventions de partenariat et signature en ligne (20/11/2026)

- Page `conventions.html` (menu administrateur « 📝 Conventions », carte association « Ma fiche association et ma convention »).
- Fiche association (nom officiel, SIRET, président, mail, date de la dernière AG, siège, activité, fédération, statuts) remplie par l'association, corrigeable par l'admin.
- Demande de compte association sans connexion : `conventions.html?demande=1` (lien aussi dans la fenêtre de connexion association) ; l'admin accepte (compte + fiche créés) ou refuse.
- Admin › Tableau des données (une ligne par association et par saison) : modèle, subvention « apparaît / n'apparaît pas », versements et aides (1 ou plusieurs montants), montant global, avantages en nature (année n-1 par défaut), lieux, article spécifique 3.9. Paramètres communs de la saison : maire, dates, délibération, année de la subvention, année des avantages. Import du tableau `DONNEES_AUTOMATIQUE` (.ods/.xlsx).
- Admin › Modèles : éditeur de texte avec champs automatiques, passages conditionnels, sauts de page, import .docx, plusieurs modèles et choix des associations de chaque modèle. Modèle de départ : `supabase/modele_convention_sport.html`.
- Annexe I générée à partir des créneaux annuels saisis (`ft_creneaux`).
- Envoi pour signature : texte figé + empreinte SHA-256 ; mail à l'association. Signature par l'association : lecture, nom/qualité, signature tracée, code à 6 chiffres envoyé par mail (15 min, 5 essais) ; IP, navigateur et horodatage enregistrés. Signature électronique simple (eIDAS art. 25).
- PDF (pdfmake) avec la signature de l'association et une page « Attestation de signature électronique » → dépôt dans i-parapheur par la Ville → dépôt du PDF final sur le site (l'association le télécharge). ZIP de toutes les conventions signées.
- Base : `supabase/conventions.sql` (tables `ft_conv_*`). Mails : fonction `fusiontest-conv-mail` (Brevo).
