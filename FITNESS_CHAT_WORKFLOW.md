# Flusso operativo Fitness Diary + ChatGPT

## Principi
- L'app resta una companion manuale: nessuna chiamata a OpenAI o ad altre AI, nessun costo API ricorrente.
- ChatGPT gestisce ragionamento, pianificazione, diario alimentare e analisi.
- Supabase conserva profilo, check-in, misurazioni, allenamenti, piani e dati nutrizionali.
- L'app continua ad avere solo tre sezioni: Allenamento, Alimentazione, File JSON.
- Non cambiare i target nutrizionali senza approvazione esplicita: 1.900 kcal, 129 g proteine, 192 g carboidrati, 68 g grassi.

## Aggiornamento forma fisica
Trigger: l'utente scrive "Aggiornamento forma fisica".
1. Leggere profilo e ultimo check-in; chiedere solo i campi mancanti o non più attuali.
2. Raccogliere data, peso standardizzato, circonferenze se disponibili, BF solo se misurata/indicata con fonte e metodo, foto facoltative, recupero, sonno, aderenza nutrizionale e allenamento.
3. Distinguere sempre valori misurati, auto-riferiti, stimati e non disponibili.
4. Analizzare variazioni usando lo storico; non interpretare una singola pesata come variazione di tessuto.
5. Salvare il check-in completo con una sola chiamata a `public.save_fitness_checkin`; non richiedere conferma per il salvataggio del check-in già completato.
6. Qualunque variazione dei target kcal o macro richiede approvazione esplicita.

## Creazione scheda
Trigger: "Scheda allenamento".
1. Leggere una sola volta `public.get_training_context(user_id)`.
2. Usare gruppi muscolari degli ultimi 7 giorni per le combinazioni e recupero; usare gli ultimi 42 giorni per carichi, ripetizioni, RIR e progressioni. Considerare solo serie effettivamente completate.
3. Escludere dalle raccomandazioni sedute anomale o non attendibili segnalate da `data_quality_flags`; non cancellare i record.
4. Chiedere il tempo disponibile solo se non è già noto.
5. Proporre 2–3 combinazioni sensate; dopo la scelta, generare esercizi, serie, carichi di riferimento, ripetizioni, RIR target, recuperi e note.
6. Richiedere approvazione esplicita prima dell'inserimento nella coda.

## Inserimento scheda approvata
Dopo l'approvazione, chiamare una sola volta `public.enqueue_workout_plan(user_id, source_id, plan_data)`.
- Usare un `source_id` univoco e stabile per quella scheda.
- La funzione è idempotente: non crea una seconda scheda se lo stesso source_id è già presente e non resetta lo stato di una scheda esistente.
- Non inserire o riattivare automaticamente duplicati già presenti in coda.

## Diario alimentare
- Calcolare per ogni pasto kcal e P/C/G; usare range quando pesi o ingredienti sono incerti.
- A fine giornata salvare i pasti e il riepilogo in Supabase.
- Mantenere separati pasti pianificati e pasti effettivamente consumati.

## Backup
- Versione 4 include profilo, check-in, misurazioni e foto progressi oltre ai dati allenamento/nutrizione precedenti.
- Mantenere compatibilità di importazione con i backup v3 e con i vecchi backup MyFit.
- I backup di intervallo includono i dati globali del profilo e i check-in del periodo selezionato; il backup completo è quello da usare per la migrazione integrale.
