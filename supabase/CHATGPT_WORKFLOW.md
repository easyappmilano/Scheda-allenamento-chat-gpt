# ChatGPT workflow — Tracciamento personale

## Principio architetturale
ChatGPT è l'unico livello di ragionamento e pianificazione. L'app non deve chiamare API AI e non integra assistenti. Supabase conserva lo storico personale. Non modificare le tre schede dell'app né il codice esistente di sessione, timer, autosalvataggio e registrazione.

## Comando: «Aggiornamento forma fisica»
1. Leggi il contesto con una sola chiamata a `get_training_context(p_user_id)`.
2. Chiedi solo i dati mancanti o da riconfermare. Usa una conversazione normale e non chiedere di nuovo informazioni già aggiornate.
3. Distingui sempre valori misurati, auto-riferiti, stimati e non disponibili.
4. Quando le risposte obbligatorie sono complete, salva l'intero aggiornamento con una sola chiamata a `save_fitness_checkin(..., p_measurements)`. Usa un `source_id` stabile e univoco. La funzione registra il check-in, le misurazioni e, quando presente `body_weight`, anche la pesata nel registro giornaliero.
5. Per una pesata singola comunicata fuori dal check-in, usa `save_body_weight_entry(...)`, con timestamp, origine e contesto (ad esempio digiuno/dopo pasto).
6. Se vengono fornite fotografie, caricale nel bucket privato `fitness-progress-photos` sotto `<user-id>/<checkin-id>/...` e salva il riferimento in `fitness_progress_photos`.
7. Verifica il risultato restituito dalla funzione. Dopo che l'utente ha completato il questionario, non chiedere una seconda approvazione per la registrazione.
8. Non cambiare i target calorici o macro senza approvazione esplicita.

## Comando: «Scheda allenamento»
1. Chiama una sola volta `get_training_context(p_user_id)`. Restituisce gruppi muscolari degli ultimi 7 giorni, ultime prestazioni degli esercizi negli ultimi 42 giorni, fino a tre sessioni per movimento, qualità dei dati, media peso a 7 giorni e riepiloghi nutrizionali a 14 giorni.
2. Usa soltanto serie effettivamente registrate. Escludi le sessioni inferiori a due minuti dalle decisioni su gruppi e progressione. Considera gli altri indicatori `data_quality_flags` e segnala i dati poco affidabili senza cancellarli.
3. Chiedi il tempo disponibile solo quando non è già noto.
4. Proponi 2–3 combinazioni pertinenti sulla base della distribuzione muscolare recente e del recupero. Dopo la scelta, prepara esercizi, serie, carichi storici, ripetizioni, RIR, recuperi e note.
5. Mostra la scheda completa e attendi sempre l'approvazione esplicita.
6. Dopo l'approvazione chiama `enqueue_workout_plan(p_user_id, p_source_id, p_plan_data)` una sola volta. Usa il formato `fitness-assistant-response`, versione 1, tipo `workout_plan`, con titolo, focus, durata, riscaldamento e array di esercizi.
7. La funzione è idempotente e serializza le richieste concorrenti. Se restituisce `blocked_by_open_plan=true`, non tentare un nuovo inserimento: segnala la scheda già aperta. Se restituisce `already_existed=true`, non creare un duplicato.
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
- Non riattivare automaticamente schede vecchie o sessioni storiche dalla coda.
