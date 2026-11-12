# Preview privata — Tracciamento Personale

Questa configurazione è destinata esclusivamente al branch `preview/development`.

## Avvio iniziale

1. Apri [Crea Codespace sulla branch preview/development](https://github.com/codespaces/new?repo=easyappmilano/Scheda-allenamento-chat-gpt&ref=preview/development).
2. Seleziona la macchina **2-core** per rimanere entro la quota gratuita GitHub Free.
3. Crea il Codespace e attendi il completamento dell'inizializzazione.
4. Nella scheda **Ports**, apri la porta **3000**. Deve rimanere **Private**.
5. Apri il link della porta 3000: l'app usa il database Supabase locale del Codespace.

Al primo avvio vengono scaricati i container locali Supabase, applicate le migrazioni versionate e generata una configurazione temporanea con la sola chiave anonima locale. L'utente di prova va creato nella preview: non riutilizzare credenziali di produzione.

## Sicurezza e isolamento

- Il Codespace usa solo `preview/development`.
- Supabase CLI non viene collegato a un progetto remoto.
- La migrazione che sostituisce la funzione esistente `get_training_context` resta sospesa finché non autorizzi separatamente quella modifica; le altre migrazioni locali vengono applicate.
- Lo script esegue `supabase start` e `supabase migration up --local`: non esegue `db push`, `link` o comandi remoti.
- L'app rifiuta di avviarsi in preview se manca la configurazione locale: non effettua fallback verso il database di produzione.
- Il port forwarding dell'app resta privato. Le chiamate Supabase passano attraverso il proxy Vite sulla stessa origine.
- `preview-config.js` contiene solo la chiave anonima generata localmente e viene ignorato da Git.
- Non sono copiati dati personali dal database di produzione.

## Costi

Gli account GitHub Free personali includono 120 core-hours e 15 GB-month di storage Codespaces al mese. Una macchina 2-core consuma due core-hours per ogni ora di attività: il budget equivale quindi a circa 60 ore di utilizzo mensile.

Per impedire addebiti oltre la quota inclusa, controlla in GitHub **Settings → Billing & licensing → Budgets and alerts** che il budget per Codespaces non consenta spese aggiuntive. Se la quota gratuita è esaurita e non è autorizzata spesa, GitHub blocca l'avvio fino al rinnovo della quota.

Quando hai finito i test, arresta il Codespace dal menu Codespaces. Non lasciarlo attivo inutilmente.

## Comandi manuali

- Stato stack locale: `npx supabase status`
- Log app: `tail -f /tmp/tracciamento-preview.log`
- Arresto Supabase locale: `npx supabase stop`
- Riavvio completo: riavvia il Codespace; lo script di avvio riallinea le migrazioni locali.
- Solo dopo approvazione esplicita della modifica a `get_training_context`, avvia il Codespace con `ALLOW_PREVIEW_TRAINING_CONTEXT_REPLACE=1` nell'ambiente del terminale prima di eseguire `bash scripts/start-preview.sh`.

La prima inizializzazione può richiedere diversi minuti per il download delle immagini Docker.
