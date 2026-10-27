# Ordina Cartelle

App per macOS (SwiftUI) che ordina i file di una cartella in sottocartelle per data e tipo
(di default `Anno/Mese/Tipo`). Anteprima prima di spostare, annullamento dell'ultima operazione,
struttura e regole configurabili dalle Impostazioni.

## Compilare
Servono i Command Line Tools di Xcode.

    ./build.sh

Crea `OrdinaCartelle.app` nella cartella del progetto.

## Rilasciare un aggiornamento
1. Modifica il numero in `VERSION` (es. `1.1.0`), fai commit e push.
2. `./release.sh "Cosa è cambiato"` compila, crea lo zip e la release su GitHub.

L'app controlla all'avvio l'ultima release (tramite `gh`, già autenticato) e propone di scaricarla.
