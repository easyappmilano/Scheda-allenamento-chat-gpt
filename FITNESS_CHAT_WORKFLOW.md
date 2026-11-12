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
- Non riattivare automaticamente schede vecchie o sessioni storiche dalla coda.

 
## Regole operative e stato verificato — 12 novembre 2026

Questo aggiornamento prevale su ogni indicazione precedente in conflitto. Le aree personali e quelle di sviluppo app devono rimanere separate, ma entrambe devono essere incluse nel backup completo.

### Separazione dei domini
- **Allenamento e alimentazione personali:** diario dell'utente, progressi, parametri, allenamenti, pasti, calorie e macronutrienti.
- **Sviluppo app:** repository, codice, bug, decisioni tecniche, Supabase, esportazioni, UI, test e decisioni di prodotto.
- Non mescolare i dati del diario personale con i dati di progetto dell'app.
- ChatGPT non può leggere né esportare automaticamente la trascrizione integrale delle conversazioni. Conservare in Supabase regole, riepiloghi, decisioni, log strutturati, riferimenti ai commit e limiti; il JSON è una memoria operativa strutturata, non una trascrizione letterale.

### Regole fisse della scheda allenamento
- Non mostrare né calcolare un cronometro del tempo totale della sessione.
- Mostrare solo il **timer di recupero**, con comandi manuali **Start / Pausa / Reset**.
- Cambiare esercizio o serie può aggiornare il preset del recupero, ma non deve avviare automaticamente il timer.
- Non inferire la durata dell'allenamento dal tempo in cui l'app resta aperta. Per le nuove sessioni salvare `duration_seconds: null` finché la durata non viene misurata o inserita esplicitamente.
- Il riepilogo deve dichiarare che la durata effettiva non è misurata, quando applicabile.
- Il confronto con l'ultimo allenamento deve basarsi su esercizi effettivamente registrati, non su una durata stimata.
- Mostrare solo le serie previste inizialmente; l'utente aggiunge ulteriori serie con il controllo «Aggiungi serie».
- Per ogni esercizio mantenere il confronto carico precedente / carico della sessione, con serie, ripetizioni, RIR e recupero.
- Il selettore per saltare a un esercizio resta sotto i pulsanti Precedente / Prossimo e prima del comando fisso Termina allenamento. Nessun badge di gruppo muscolare sopra il selettore.
- La conclusione dell'allenamento e il caricamento della scheda successiva devono restare azioni esplicite dell'utente. Non avviare automaticamente la scheda successiva.

### Regole del diario personale
- Target operativo confermato: **1.900 kcal, 129 g proteine, 192 g carboidrati, 68 g grassi**. Non passare a 2.150 kcal senza richiesta esplicita.
- Per ogni pasto calcolare calorie e P/C/G; se quantità o preparazione non sono certe, usare stime realistiche e intervalli.
- Separare alimenti consumati, pianificati e non confermati.
- Aggiornare il peso con data e calcolare medie settimanali, evitando di interpretare le oscillazioni giornaliere come variazioni di grasso.
- Registrare gli allenamenti con kg, serie, ripetizioni, recupero e RIR/RPE; evidenziare il sovraccarico progressivo solo quando i dati lo dimostrano.

### Backup JSON versione 5
- Tipi: `all` (completo), `training` (allenamento), `nutrition` (alimentazione), `app` (progetto app e regole).
- Intervalli: `day`, `week`, `month`, `year`, `all`.
- Il backup app contiene contesto di progetto, regole permanenti, decisioni e cronologia strutturata degli eventi app. L'importazione di un backup app-only deve scrivere solo nella tabella `fitness_continuity_records`, senza sostituire allenamenti o pasti.
- Il backup allenamento deve conservare schede, serie, RIR, recuperi, peso e check-in; il backup alimentazione deve conservare pasti, alimenti, ricette e riepiloghi.
- Le foto alimentari devono essere scaricate solo nell'export `nutrition` o `all`; le foto dei progressi fisici solo in `training` o `all`. Un export separato non deve fallire per un'immagine appartenente all'altro dominio.
- Il backup completo deve comprendere entrambi i domini e tutti i record di continuità.
- I test mock del 12 novembre 2026 hanno verificato 4 tipi × 5 intervalli, il filtro temporale dei record app, la separazione dei download foto e l'importazione app-only (che scrive soltanto `fitness_continuity_records`). Non equivalgono a un test reale nel browser o a un ripristino in produzione.

### Identità grafica e stato codice
- Palette richiesta: viola acceso, bianco, nero; card grigio scuro sfumato e bordi grigi sottili ad alto contrasto.
- Logo viola creato e collegato nell'intestazione, come icona browser / Apple touch icon e nel manifest web app.
- Proposte grafiche A/B/C per la scheda allenamento preparate in `Proposte_grafiche_tracciamento_12-11-2026.pdf`. Non applicare il restyling definitivo finché l'utente non sceglie A, B o C.
- Repository: `easyappmilano/Scheda-allenamento-chat-gpt`.
- Supabase project: `nejhzeixeptfkyxeliuw`.
- Branch di sviluppo: `feature/recovery-timer-brand`; commit verificato prima di questo aggiornamento: `a8b57eb6c25e972807b43f0119acce10577ac6c3`.
- Le modifiche non sono pubblicate né unite a main. Non effettuare merge/deploy senza richiesta esplicita.
- Prima di consegnare il JSON finale, eseguire un test runtime in Safari/browser, verificare i download reali e il restore in ambiente controllato, poi aggiornare il commit e il record di continuità Supabase.

### Comportamento della chat
- Quando l'utente saluta o scrive «ciao», mostrare un menu breve di azioni: scheda allenamento, aggiungere un pasto, aggiornare peso/progressi, gestione app/backup.
- Le scelte possono essere presentate come pulsanti; usare i dati già noti senza chiedere nuovamente informazioni memorizzate.
- Alla ricezione di un JSON di continuità, ricostruire separatamente il percorso fisico e lo stato del progetto app, verificando versione, data e branch prima di riprendere.


## Aggiornamento 12 novembre 2026 — Restyling Compact Flow

- Scelta utente: **C — Compact Flow**.
- Commit applicato a `index.html`: `eb68a9c2fa99e3297d211c41d565bc6755180829`.
- Restyling esclusivamente CSS: palette viola acceso, bianco e nero; card grigio sfumato; bordi grigio chiaro; timer recupero compatto integrato; righe serie più leggibili; adattamento mobile.
- Non sono stati modificati markup funzionale, identificativi DOM, handler o logica JavaScript.
- Verifiche statiche: 3 script JavaScript validati; 19 identificativi essenziali presenti; timer recupero presente; timer totale assente; ordine navigazione verificato.
- Stato: branch di sviluppo `feature/recovery-timer-brand`; non pubblicato. Restano test runtime in Safari e collaudo end-to-end dei backup prima della pubblicazione.
