# ChatGPT workflow — Tracciamento personale

## Principio architetturale
ChatGPT è l'unico livello di ragionamento e pianificazione. L'app non deve chiamare API AI e non integra assistenti. Supabase conserva lo storico personale. Non modificare le tre schede dell'app né il codice esistente di sessione, timer, autosalvataggio e registrazione.

## Comando: «Aggiornamento forma fisica»
1. Leggi il contesto con una sola chiamata a `get_training_context(p_user_id)`.
2. Chiedi solo i dati mancanti o da riconfermare. Usa una conversazione normale e non chiedere di nuovo informazioni già aggiornate.
3. Distingui sempre valori misurati, auto-riferiti, stimati e non disponibili.
4. Quando le risposte obbligatorie sono complete, salva l'intero aggiornamento con una sola chiamata a `save_fitness_checkin(..., p_measurements)`. Usa un `source_id` stabile e univoco. La funzione registra check-in, misurazioni e, quando presente `body_weight`, anche la pesata nel registro giornaliero.
5. Se l'utente invia anche fotografie, usa `save_fitness_checkin_with_photos(..., p_measurements, p_photos)`: include le immagini come data URL/base64 con mime type e vista (front/side/back). Le immagini sono conservate nel database con RLS attivo e incluse nel backup JSON.
6. Per una pesata singola comunicata fuori dal check-in, usa `save_body_weight_entry(...)`, con timestamp, origine e contesto. Imposta `context.standardized=true` e `context.include_in_average=true` solo per pesate confrontabili (preferibilmente al mattino, dopo il bagno e prima di mangiare/bere); dopo colazione, dopo allenamento o in condizioni diverse usa `include_in_average=false`. La misura resta nello storico ma non altera la media mobile.
7. Verifica il risultato restituito dalla funzione. Dopo che l'utente ha completato il questionario, non chiedere una seconda approvazione per la registrazione.
8. Non cambiare i target calorici o macro senza approvazione esplicita.

## Comando: «Scheda allenamento»
1. Chiama una sola volta `get_training_context(p_user_id)`. Restituisce gruppi muscolari degli ultimi 7 giorni, ultime prestazioni degli esercizi negli ultimi 42 giorni, fino a tre sessioni per movimento, qualità dei dati, media peso a 7 giorni e riepiloghi nutrizionali a 14 giorni.
2. Usa soltanto serie effettivamente registrate. Escludi le sessioni inferiori a due minuti dalle decisioni su gruppi e progressione. Considera gli altri indicatori `data_quality_flags` e segnala i dati poco affidabili senza cancellarli.
3. Chiedi il tempo disponibile solo quando non è già noto.
4. Proponi 2–3 combinazioni pertinenti sulla base della distribuzione muscolare recente e del recupero. Dopo la scelta, prepara esercizi, serie, carichi storici, ripetizioni, RIR, recuperi e note.
5. Mostra la scheda completa e attendi sempre l'approvazione esplicita.
6. Dopo l'approvazione chiama `enqueue_workout_plan(p_user_id, p_source_id, p_plan_data)` una sola volta. Usa il formato `fitness-assistant-response`, versione 1, tipo `workout_plan`, con titolo, focus, durata, riscaldamento e array di esercizi.
7. La funzione è idempotente, serializza le richieste concorrenti e blocca un nuovo piano quando esiste già una scheda aperta. Se restituisce `blocked_by_open_plan=true`, non tentare un nuovo inserimento: segnala la scheda già aperta. Se restituisce `already_existed=true`, non creare un duplicato.
8. Verifica ID e stato restituiti. L'app continua a ricevere la scheda tramite il polling già esistente di `workout_plans`.

## Diario alimentare
- Calcola kcal e P/C/G per ogni pasto; usa intervalli quando quantità o ingredienti sono incerti.
- Registra pasti, ingredienti e riepilogo giornaliero solo dopo la conferma dell'utente sul diario della giornata.
- Distingui pasti programmati da pasti effettivamente consumati.
- Mantieni i target presenti nel profilo finché l'utente non approva un cambiamento.

## Backup e continuità
- Formato: `fitness-diary-backup`, versione 4; mantenere importazione compatibile con v3 e con i vecchi backup MyFit.
- Il backup comprende allenamenti, serie, pasti, ingredienti, alimenti, ricette, foto, riepiloghi, profilo, check-in, misurazioni, foto progressi, registro pesate e `continuity_data`.
- Le immagini vengono incorporate nel JSON per non dipendere dai percorsi Storage del vecchio account.
- In ripristino, rimappa gli ID dei check-in prima di ripristinare misure e foto.
- Esporta anche la coda `workout_plans` e l'archivio storico `fitness_workout_plan_archive`.
- Durante un ripristino inserisci le schede storiche solo in `fitness_workout_plan_archive`; non inserirle mai in `workout_plans` e non riattivare schede precedenti.


## Aggiornamento 12 novembre 2026 — Proposte compatte e schemi avanzati

- Quando viene richiesta una nuova scheda, eseguire l'analisi di storico, carichi, progressione, volume e recupero senza trascriverla nella risposta.
- La risposta in chat contiene soltanto almeno tre proposte compatte. Ogni esercizio deve indicare nome, tipologia (multiarticolare, monoarticolare, unilaterale, ecc.), schema delle serie, ripetizioni/tempo, RIR, recupero e carico precedente quando disponibile.
- Evitare la ripetizione meccanica delle stesse combinazioni; variare, quando appropriato, esercizi e schemi (top set/back-off, drop set, rest-pause, cluster, myo-reps, tempo, isometrie, AMRAP controllato). Le tecniche avanzate non vanno considerate automaticamente superiori alle serie tradizionali: usarle con dose limitata e criterio.
- In assenza di richiesta esplicita di circuito, non proporre circuiti.
- Includere nella risposta un'azione per rigenerare almeno tre alternative, restando coerenti con gruppi muscolari pertinenti e recupero.
- Non accodare una scheda finché l'utente non seleziona una proposta. Dopo la selezione, chiamare una volta `enqueue_workout_plan` con `fitness-assistant-response`, versione 1, tipo `workout_plan`.
- `plan.session_type`: `standard` o `circuit`. In modalità standard, ogni esercizio può includere `exercise_type`, `execution_mode`, `planned_sets`, `rep_range`, `rest_seconds`, `previous_reference`, `target_rir` e `set_scheme`.
- Gli elementi di `set_scheme` sono oggetti JSON. Campi supportati dall'interfaccia: `kind` (straight, warmup, top_set, backoff, drop_set, rest_pause, cluster, myo_reps, tempo, isometric, amrap), `label`, `rep_range`, `target_rir`, `tempo_eccentric_seconds`, `pause_seconds`, `concentric_seconds`, `rest_pause_seconds`, `cluster_reps`, `cluster_pause_seconds`, `segments` con `label`, `load_kg`, `reps` o `rep_range`.
- Per i drop set usare `segments` in ordine decrescente, e l'app consente di registrare carico e ripetizioni reali per ciascun segmento. Rest-pause e cluster espongono la prescrizione, mentre carico/ripetizioni/RIR effettivi restano compilabili.
- Per un circuito su richiesta: `session_type: "circuit"`, oggetto `circuit` con `rounds`, `work_seconds`, `transition_rest_seconds`, `round_rest_seconds`; esercizi con `execution_mode: "circuit"`, `circuit_id`, `circuit_order`, `planned_sets` pari ai giri, `work_duration_seconds`, `transition_rest_seconds`, `round_rest_seconds`, `circuit_rounds`. Il timer gestisce lavoro per stazione, transizione e recupero a fine giro. Il circuito parte solo quando l'utente avvia il timer.
- La registrazione salva modalità d'esecuzione, struttura della prescrizione, dati effettivi dei segmenti, tempi e parametri del circuito. I record classici esistenti mantengono i valori predefiniti compatibili.
- La UI durante l'allenamento mantiene il timer manuale e l'azione esplicita dell'utente; le serie precompilate sono soltanto quelle programmate.
