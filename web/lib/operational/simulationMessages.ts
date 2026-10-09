import type {Locale} from '../i18n';
const messages:Record<string,readonly [string,string]>={
 "banner": [
  "SIMULACIJA — NI RESNIČNA INTERVENCIJA",
  "SIMULATION — KEIN REALER EINSATZ"
 ],
 "title": [
  "Usposabljanje / simulacija",
  "Ausbildung / Simulation"
 ],
 "new": [
  "Nova učna intervencija",
  "Neuer Übungseinsatz"
 ],
 "enable": [
  "Ustvari kot učno intervencijo",
  "Als Übungseinsatz erstellen"
 ],
 "setup": [
  "Najprej imenuj poveljnika, pridobi njegovo soglasje in aktiviraj intervencijo z obstoječimi kontrolami. Nato dodaj učne enote. Simulacijska pravica ne podeli poveljevanja.",
  "Zuerst Einsatzleiter benennen, dessen Zustimmung einholen und den Einsatz mit den bestehenden Bedienelementen aktivieren. Danach Übungseinheiten hinzufügen. Simulationsrechte erteilen keine Befehlsbefugnis."
 ],
 "environment": [
  "Samo ločeno, izrecno omogočeno učno okolje; brez dejanske aktivacije služb.",
  "Nur für eine separate, ausdrücklich freigegebene Trainingsumgebung; keine reale Alarmierung."
 ],
 "template": [
  "Predloga scenarija",
  "Szenariovorlage"
 ],
 "seed": [
  "Seme postavitve",
  "Startwert der Anordnung"
 ],
 "radius": [
  "Polmer začetne postavitve (m)",
  "Radius der Startanordnung (m)"
 ],
 "STRUCTURE_FIRE": [
  "Požar objekta",
  "Gebäudebrand"
 ],
 "WILDFIRE": [
  "Požar v naravi",
  "Vegetationsbrand"
 ],
 "TRAFFIC_ACCIDENT": [
  "Prometna nesreča",
  "Verkehrsunfall"
 ],
 "SANDBOX": [
  "Prazen poligon",
  "Leere Übungsumgebung"
 ],
 "center": [
  "Izberi središče na karti",
  "Mittelpunkt auf Karte wählen"
 ],
 "centerHelp": [
  "Klik na karto samo določi učne začetne koordinate. Ne ustvari intervencije.",
  "Kartenklick setzt nur die Trainingsstartkoordinaten. Er erstellt keinen Einsatz."
 ],
 "preview": [
  "Predogled začetnih položajev — niso GPS ali cestne točke",
  "Vorschau der Startpositionen — keine GPS- oder Straßenpunkte"
 ],
 "PROVISION": [
  "Ustvari in razporedi SIM enote",
  "SIM-Einheiten erstellen und zuweisen"
 ],
 "ATTACH": [
  "Dodaj izbrane razporejene enote",
  "Ausgewählte zugewiesene Einheiten hinzufügen"
 ],
 "small": [
  "Majhna sestava · 3",
  "Kleine Gruppe · 3"
 ],
 "structure": [
  "Sestava za objekt · 5",
  "Gebäudegruppe · 5"
 ],
 "large": [
  "Velika sestava · 10",
  "Große Gruppe · 10"
 ],
 "stress": [
  "Obsežna postavitev · 30",
  "Große Anordnung · 30"
 ],
 "fixtures": [
  "Ustvari ločene enote brez vozil ali zalog; vsi običajni pogoji upravljanja in razporejanja ostanejo obvezni. Celoten paket je atomaren.",
  "Erstellt separate Einheiten ohne Fahrzeuge oder Bestände; alle normalen Verwaltungs- und Zuweisungsregeln bleiben verbindlich. Das gesamte Paket ist atomar."
 ],
 "candidates": [
  "Obstoječe učne razporeditve (največ 100)",
  "Bestehende Übungszuweisungen (maximal 100)"
 ],
 "noUnits": [
  "Ni simuliranih enot. Po aktivaciji intervencije ustvari paket ali dodaj obstoječe razporeditve.",
  "Keine simulierten Einheiten. Nach Einsatzaktivierung ein Paket erstellen oder bestehende Zuweisungen hinzufügen."
 ],
 "positions": [
  "Simulirani položaji",
  "Simulierte Positionen"
 ],
 "SET_POSITION": [
  "Nastavi simulirani položaj",
  "Simulierte Position setzen"
 ],
 "move": [
  "Premakni na karti",
  "Auf Karte versetzen"
 ],
 "moveHelp": [
  "SIM premik: klik predlaga položaj, nato ga izrecno potrdi. To ni ukaz MOVE_TO.",
  "SIM-Versetzung: Klick schlägt Position vor, anschließend ausdrücklich bestätigen. Dies ist kein MOVE_TO-Befehl."
 ],
 "RESET_POSITION": [
  "Ponastavi na začetni položaj",
  "Auf Startposition zurücksetzen"
 ],
 "REMOVE": [
  "Odstrani iz scenarija",
  "Aus Szenario entfernen"
 ],
 "START": [
  "Začni",
  "Starten"
 ],
 "PAUSE": [
  "Začasno ustavi",
  "Pausieren"
 ],
 "RESUME": [
  "Nadaljuj",
  "Fortsetzen"
 ],
 "RESET": [
  "Ponastavi položaje",
  "Positionen zurücksetzen"
 ],
 "FINISH": [
  "Zaključi simulacijo",
  "Simulation beenden"
 ],
 "DRAFT": [
  "Priprava",
  "Vorbereitung"
 ],
 "RUNNING": [
  "Poteka",
  "Läuft"
 ],
 "PAUSED": [
  "Začasno ustavljeno",
  "Pausiert"
 ],
 "FINISHED": [
  "Zaključeno",
  "Beendet"
 ],
 "resetWarning": [
  "Ponastavitev ohrani zgodovino nalog in dogodkov. Za prazno zgodovino ustvari novo učno intervencijo.",
  "Zurücksetzen bewahrt Aufgaben und Ereignisse. Für leere Historie einen neuen Übungseinsatz erstellen."
 ],
 "ack": [
  "Ukazi ne premikajo enot in ne ustvarijo potrditve ACK. Za ročno izvrševanje uporabi pravi učni račun z ustrezno vlogo; samodejni odzivi pridejo v M14.5E.",
  "Befehle versetzen keine Einheiten und erzeugen keine ACK-Bestätigung. Manuelle Ausführung benötigt ein echtes Trainingskonto mit passender Rolle; automatische Reaktionen folgen in M14.5E."
 ],
 "roster": [
  "Posadke ostajajo pravi učni računi v obstoječem pregledu enote. Navideznih uporabnikov ne ustvarjamo.",
  "Besatzungen bleiben echte Trainingskonten in der bestehenden Einheitenansicht. Es werden keine fiktiven Benutzer erstellt."
 ],
 "timestamp": [
  "Čas simuliranega položaja",
  "Zeit der simulierten Position"
 ],
 "older": [
  "Starejši SIM položaj",
  "Ältere SIM-Position"
 ],
 "current": [
  "SIM položaj",
  "SIM-Position"
 ],
 "heading": [
  "Simulirana smer (°)",
  "Simulierte Richtung (°)"
 ],
 "speed": [
  "Simulirana hitrost (m/s; brez samodejnega premika)",
  "Simulierte Geschwindigkeit (m/s; keine automatische Bewegung)"
 ],
 "longitude": [
  "Zemljepisna dolžina",
  "Längengrad"
 ],
 "latitude": [
  "Zemljepisna širina",
  "Breitengrad"
 ],
 "confirm": [
  "Potrdi simulacijsko spremembo",
  "Simulationsänderung bestätigen"
 ],
 "cancel": [
  "Prekliči",
  "Abbrechen"
 ],
 "refresh": [
  "Osveži",
  "Aktualisieren"
 ],
 "retry": [
  "Ponovi isto zahtevo",
  "Identische Anfrage wiederholen"
 ],
 "review": [
  "Preglej spremembo",
  "Änderung prüfen"
 ],
 "pending": [
  "Odgovor ni potrjen. Ohranjen je isti ID in zahteva za varen ponovni poskus.",
  "Antwort unbestätigt. Dieselbe ID und Anfrage bleiben für einen sicheren Wiederholungsversuch erhalten."
 ],
 "saved": [
  "Simulacijska sprememba shranjena.",
  "Simulationsänderung gespeichert."
 ],
 "history": [
  "Zgodovina simulacije",
  "Simulationsverlauf"
 ],
 "olderEvents": [
  "Starejši dogodki",
  "Ältere Ereignisse"
 ],
 "first": [
  "Najnovejši",
  "Neueste"
 ],
 "open": [
  "Odpri simulacijo",
  "Simulation öffnen"
 ],
 "more": [
  "Naslednja stran",
  "Nächste Seite"
 ],
 "count": [
  "Enote",
  "Einheiten"
 ],
 "createdBy": [
  "Ustvaril",
  "Erstellt von"
 ],
 "updated": [
  "Zadnja sprememba",
  "Letzte Änderung"
 ],
 "loading": [
  "Nalaganje simulacije …",
  "Simulation wird geladen …"
 ],
 "none": [
  "Ni scenarijev.",
  "Keine Szenarien."
 ],
 "SIMULATION_DISABLED": [
  "Simulacija je na strežniku izklopljena.",
  "Simulation ist serverseitig deaktiviert."
 ],
 "INVALID_SIMULATION_STATE": [
  "To dejanje ni dovoljeno v trenutnem stanju scenarija/intervencije. Med premorom so dovoljene priprava in ponastavitve.",
  "Aktion ist im aktuellen Szenario-/Einsatzstatus nicht erlaubt. Während einer Pause sind Vorbereitung und Zurücksetzen erlaubt."
 ],
 "INVALID_SIMULATION_UNIT": [
  "Enota ni veljavna za ta scenarij ali trenutno poveljevanje.",
  "Einheit ist für dieses Szenario oder die aktuelle Befehlsbefugnis nicht gültig."
 ],
 "INVALID_SIMULATION_POSITION": [
  "Neveljavni simulacijski podatki ali koordinate.",
  "Ungültige Simulationsdaten oder Koordinaten."
 ],
 "SIMULATION_LIMIT": [
  "Največ 30 novih enot na paket in 100 položajev na scenarij, skupaj z odstranjenimi.",
  "Maximal 30 neue Einheiten pro Paket und 100 Positionen pro Szenario einschließlich entfernter Einheiten."
 ],
 "SIMULATION_RESOURCE_DISABLED": [
  "Učna intervencija ne sme razporejati ali porabljati dejanskih zalog.",
  "Übungseinsätze dürfen keine tatsächlichen Bestände zuweisen oder verbrauchen."
 ],
 "NOT_AUTHORIZED": [
  "Nimaš več dovoljenja za to simulacijsko dejanje.",
  "Keine Berechtigung für diese Simulationsaktion."
 ],
 "EXPIRED": [
  "Prijava je potekla.",
  "Anmeldung abgelaufen."
 ],
 "STALE_VERSION": [
  "Stanje je bilo spremenjeno drugje. Osveži in izrecno ponovno preglej predlog; nič ni samodejno prepisano.",
  "Zustand wurde anderweitig geändert. Aktualisieren und Vorschlag ausdrücklich erneut prüfen; nichts wird automatisch überschrieben."
 ],
 "VALIDATION_FAILED": [
  "Preveri podatke priprave scenarija.",
  "Szenarioangaben prüfen."
 ],
 "OPERATION_REUSED": [
  "ID zahteve je že uporabljen za drugo spremembo.",
  "Anfrage-ID wurde bereits für eine andere Änderung verwendet."
 ],
 "SERVER": [
  "Simulacijskih podatkov ni mogoče potrditi. Poskusi ponovno.",
  "Simulationsdaten können nicht bestätigt werden. Erneut versuchen."
 ],
 "SCENARIO_CREATED": [
  "Scenarij ustvarjen",
  "Szenario erstellt"
 ],
 "UNITS_ADDED": [
  "Enote dodane",
  "Einheiten hinzugefügt"
 ],
 "POSITION_SET": [
  "Položaj nastavljen",
  "Position gesetzt"
 ],
 "POSITION_RESET": [
  "Položaj ponastavljen",
  "Position zurückgesetzt"
 ],
 "UNIT_REMOVED": [
  "Enota odstranjena",
  "Einheit entfernt"
 ],
 "SIMULATION_STARTED": [
  "Simulacija začeta",
  "Simulation gestartet"
 ],
 "SIMULATION_PAUSED": [
  "Simulacija začasno ustavljena",
  "Simulation pausiert"
 ],
 "SIMULATION_RESUMED": [
  "Simulacija nadaljevana",
  "Simulation fortgesetzt"
 ],
 "SIMULATION_RESET": [
  "Položaji ponastavljeni",
  "Positionen zurückgesetzt"
 ],
 "SIMULATION_FINISHED": [
  "Simulacija zaključena",
  "Simulation beendet"
 ],
 "modeBusy": [
  "Najprej zaključi trenutni način karte ali urejanje.",
  "Zuerst aktuellen Kartenmodus oder Bearbeitung beenden."
 ]
};
export const simulationText=(locale:Locale)=>(key:string)=>messages[key]?.[locale==='de'?1:0]??key;
