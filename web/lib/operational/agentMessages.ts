import type {Locale} from '../i18n';
const labels:Record<string,readonly [string,string]>={
 "title": [
  "Avtonomna simulacija",
  "Autonome Simulation"
 ],
 "notice": [
  "Samo vaja. Virtualni odzivi ne potrjujejo dejanskih nalog, prihoda ali varnosti.",
  "Nur Übung. Virtuelle Antworten bestätigen keine realen Aufträge, Ankünfte oder Sicherheit."
 ],
 "clock": [
  "Simulacijska ura",
  "Simulationsuhr"
 ],
 "runner": [
  "Izvajalnik simulacije",
  "Simulationsrunner"
 ],
 "active": [
  "Aktiven",
  "Aktiv"
 ],
 "manual": [
  "Način ročnega koraka",
  "Manueller Schrittmodus"
 ],
 "unavailable": [
  "Izvajalnik ni na voljo",
  "Runner nicht verfügbar"
 ],
 "latest": [
  "Zadnji uspešni korak",
  "Letzter erfolgreicher Schritt"
 ],
 "behind": [
  "Zakasnitev izvajalnika; časovni preskok je omejen.",
  "Runner verzögert; Zeitsprung ist begrenzt."
 ],
 "scale": [
  "Hitrost časa",
  "Zeitskalierung"
 ],
 "STEP": [
  "Napreduj za en korak",
  "Einen Schritt ausführen"
 ],
 "STOP_ALL": [
  "Ustavi vse agente",
  "Alle Agenten stoppen"
 ],
 "SCALE": [
  "Spremeni hitrost časa",
  "Zeitskalierung ändern"
 ],
 "START": [
  "Začni avtonomno izvajanje",
  "Autonome Ausführung starten"
 ],
 "PAUSE": [
  "Začasno ustavi enoto",
  "Einheit pausieren"
 ],
 "RESUME": [
  "Nadaljuj enoto",
  "Einheit fortsetzen"
 ],
 "STOP": [
  "Ustavi enoto",
  "Einheit stoppen"
 ],
 "CLEAR": [
  "Odstrani motnjo",
  "Störung aufheben"
 ],
 "INJECT": [
  "Dodaj dogodek",
  "Ereignis hinzufügen"
 ],
 "refresh": [
  "Osveži",
  "Aktualisieren"
 ],
 "confirm": [
  "Potrdi simulacijsko dejanje",
  "Simulationsaktion bestätigen"
 ],
 "cancel": [
  "Prekliči",
  "Abbrechen"
 ],
 "retry": [
  "Ponovi isti zahtevek",
  "Dieselbe Anfrage wiederholen"
 ],
 "pending": [
  "Izid ni potrjen. Ponovitev ohrani isti UUID in podatke.",
  "Ergebnis unbestätigt. Wiederholung behält UUID und Daten."
 ],
 "select": [
  "Izberi nalogo izbrane enote",
  "Auftrag der ausgewählten Einheit wählen"
 ],
 "all": [
  "Vse SIM enote",
  "Alle SIM-Einheiten"
 ],
 "profile": [
  "Odzivni profil",
  "Antwortprofil"
 ],
 "ack": [
  "Zamik virtualne potrditve (s)",
  "Verzögerung der virtuellen Bestätigung (s)"
 ],
 "start": [
  "Zamik izvajanja (s)",
  "Ausführungsverzögerung (s)"
 ],
 "completion": [
  "Zamik zaključka (s)",
  "Abschlussverzögerung (s)"
 ],
 "factor": [
  "Faktor simulirane hitrosti",
  "Simulierter Geschwindigkeitsfaktor"
 ],
 "fault": [
  "Delež poti za motnjo (0–1)",
  "Störungsposition auf Route (0–1)"
 ],
 "duration": [
  "Trajanje izgube zveze (s)",
  "Dauer des Signalverlusts (s)"
 ],
 "NORMAL": [
  "Običajen odziv",
  "Normale Antwort"
 ],
 "SLOW_RESPONSE": [
  "Počasen odziv",
  "Langsame Antwort"
 ],
 "NO_RESPONSE": [
  "Brez odziva",
  "Keine Antwort"
 ],
 "BREAKDOWN": [
  "Okvara vozila",
  "Fahrzeugausfall"
 ],
 "COMMUNICATION_LOSS": [
  "Izguba zveze",
  "Signalverlust"
 ],
 "ROUTE_BLOCKED": [
  "Zaprta cesta",
  "Straßensperre"
 ],
 "operational": [
  "Dejansko stanje naloge",
  "Operativer Auftragsstatus"
 ],
 "navigation": [
  "Stanje navigacijske seje",
  "Navigationsstatus"
 ],
 "simulation": [
  "Simulirano izvajanje",
  "Simulierte Ausführung"
 ],
 "progress": [
  "Napredek po cesti",
  "Straßenfortschritt"
 ],
 "speed": [
  "Simulirana hitrost",
  "Simulierte Geschwindigkeit"
 ],
 "remaining": [
  "Simulirani preostali čas vožnje",
  "Simulierte verbleibende Fahrzeit"
 ],
 "route": [
  "Prikaži/pripravi cestno pot",
  "Straßenroute anzeigen/vorbereiten"
 ],
 "show": [
  "Prikaži pot in dostopno točko",
  "Route und Zugangspunkt anzeigen"
 ],
 "access": [
  "Nastavi SIM položaj na cestno dostopno točko",
  "SIM-Position auf Straßenzugang setzen"
 ],
 "recalculate": [
  "Nato izrecno preračunaj pot v navigacijskem panelu.",
  "Anschließend Route im Navigationsbereich ausdrücklich neu berechnen."
 ],
 "gap": [
  "Oddaljenost od cestnega dostopa (m)",
  "Abstand zum Straßenzugang (m)"
 ],
 "roadOnly": [
  "Prihod pomeni le simulirani cestni konec poti.",
  "Ankunft bedeutet nur das simulierte Straßenende."
 ],
 "moving": [
  "V premiku",
  "In Bewegung"
 ],
 "waiting": [
  "Čaka na virtualno potrditev",
  "Wartet auf virtuelle Bestätigung"
 ],
 "blocked": [
  "Motnja/premor",
  "Störung/Pause"
 ],
 "total": [
  "Izvajanja",
  "Ausführungen"
 ],
 "stale": [
  "Zastareli položaji",
  "Veraltete Positionen"
 ],
 "WAITING_TO_ACK": [
  "Čaka na virtualno potrditev",
  "Wartet auf virtuelle Bestätigung"
 ],
 "SIM_ACKNOWLEDGED": [
  "Virtualno potrjeno",
  "Virtuell bestätigt"
 ],
 "SIM_IN_PROGRESS": [
  "Sledi cestni poti / izvaja nalogo",
  "Folgt Straßenroute / führt Auftrag aus"
 ],
 "SIM_ARRIVED": [
  "Simulirani prihod",
  "Simulierte Ankunft"
 ],
 "SIM_COMPLETED": [
  "Simulirani zaključek",
  "Simulierter Abschluss"
 ],
 "SIM_BLOCKED": [
  "Simulirana ovira",
  "Simulierte Blockierung"
 ],
 "SIM_UNABLE": [
  "Simulirano ni mogoče",
  "Simuliert nicht möglich"
 ],
 "SIM_PAUSED": [
  "Simulirani premor",
  "Simulierte Pause"
 ],
 "SIM_SIGNAL_LOST": [
  "SIM · zveza izgubljena",
  "SIM · Signal verloren"
 ],
 "SIM_CANCELLED": [
  "Simulirano ustavljeno",
  "Simulation gestoppt"
 ],
 "SIM_BREAKDOWN": [
  "Okvara vozila",
  "Fahrzeugausfall"
 ],
 "SIM_ROAD_BLOCKED": [
  "Cesta zaprta",
  "Straße gesperrt"
 ],
 "SIM_SIGNAL_LOSS": [
  "Izguba zveze",
  "Signalverlust"
 ],
 "SIM_NO_RESPONSE": [
  "Brez virtualne potrditve",
  "Keine virtuelle Bestätigung"
 ],
 "SIM_HOLD": [
  "Zadrži položaj",
  "Position halten"
 ],
 "SIM_RESUME": [
  "Nadaljuj simulacijo",
  "Simulation fortsetzen"
 ],
 "TIME": [
  "Ob simulacijskem času (s)",
  "Zur Simulationszeit (s)"
 ],
 "AFTER_ACK": [
  "Sekund po virtualni potrditvi",
  "Sekunden nach virtueller Bestätigung"
 ],
 "PROGRESS": [
  "Delež cestne poti (0–1)",
  "Routenanteil (0–1)"
 ],
 "EXECUTION_START": [
  "Ob začetku izvajanja",
  "Bei Ausführungsbeginn"
 ],
 "trigger": [
  "Sprožilec",
  "Auslöser"
 ],
 "value": [
  "Vrednost sprožilca",
  "Auslösewert"
 ],
 "event": [
  "Vrsta dogodka",
  "Ereignistyp"
 ],
 "history": [
  "Zgodovina simulacije",
  "Simulationshistorie"
 ],
 "older": [
  "Starejši",
  "Ältere"
 ],
 "newest": [
  "Najnovejši",
  "Neueste"
 ],
 "next": [
  "Naslednja stran",
  "Nächste Seite"
 ],
 "previous": [
  "Prejšnja stran",
  "Vorherige Seite"
 ],
 "scheduled": [
  "Načrtovani dogodki",
  "Geplante Ereignisse"
 ],
 "fired": [
  "Sprožen ob",
  "Ausgelöst um"
 ],
 "notFired": [
  "Še ni sprožen",
  "Noch nicht ausgelöst"
 ],
 "SIMULATION_ENGINE": [
  "Simulacijski mehanizem",
  "Simulationsengine"
 ],
 "HUMAN_CONTROLLER": [
  "Upravljavec vaje",
  "Übungsleiter"
 ],
 "SIM_RUN_CREATED": [
  "Izvajanje ustvarjeno",
  "Ausführung erstellt"
 ],
 "SIM_EVENT_SCHEDULED": [
  "Dogodek načrtovan",
  "Ereignis geplant"
 ],
 "SIM_STATUS_REPORT": [
  "Simulirano poročilo stanja",
  "Simulierter Statusbericht"
 ],
 "SIM_PROGRESS": [
  "Simulirani napredek",
  "Simulierter Fortschritt"
 ],
 "SIM_INVALIDATED": [
  "Izvajanje ni več veljavno",
  "Ausführung nicht mehr gültig"
 ],
 "SIM_SCENARIO_PAUSED": [
  "Scenarij začasno ustavljen",
  "Szenario pausiert"
 ],
 "SIM_SCENARIO_RUNNING": [
  "Scenarij nadaljevan",
  "Szenario fortgesetzt"
 ],
 "SIM_SCENARIO_FINISHED": [
  "Scenarij zaključen",
  "Szenario beendet"
 ],
 "current": [
  "SIM · svež vzorec",
  "SIM · aktueller Messpunkt"
 ],
 "stalePosition": [
  "SIM · zastarel vzorec",
  "SIM · veralteter Messpunkt"
 ],
 "unknown": [
  "SIM · položaj neznan",
  "SIM · Position unbekannt"
 ],
 "SIM_LIMIT": [
  "Dosežena omejitev vaje; za novo ponovitev ustvari nov scenarij.",
  "Übungslimit erreicht; für Wiederholung neues Szenario erstellen."
 ],
 "SIM_RATE_LIMIT": [
  "Kontrole so prehitre. Počakaj in znova preglej dejanje.",
  "Steuerung zu häufig. Warten und Aktion erneut prüfen."
 ],
 "SIM_RUN_EXISTS": [
  "Enota ali naloga že ima nezdružljivo izvajanje. Najprej ga ustavi.",
  "Einheit oder Auftrag hat bereits eine inkompatible Ausführung. Zuerst stoppen."
 ],
 "SIM_ROUTE_REQUIRED": [
  "Pot manjka ali ni več veljavna. Izrecno pripravi novo pot.",
  "Route fehlt oder ist ungültig. Neue Route ausdrücklich vorbereiten."
 ],
 "SIM_ACCESS_GAP": [
  "SIM enota ni na cestni dostopni točki. Prikaži dostop, potrdi premik in preračunaj pot.",
  "SIM-Einheit liegt nicht am Straßenzugang. Zugang anzeigen, Verschiebung bestätigen und Route neu berechnen."
 ],
 "SIM_STOP_BEFORE_EDIT": [
  "Pred ročno spremembo položaja ali ponastavitvijo ustavi avtonomno izvajanje.",
  "Vor manueller Positionsänderung oder Zurücksetzen autonome Ausführung stoppen."
 ],
 "SIM_RUNNER_ERROR": [
  "Napaka izvajalnika; shranjeni napredek je ohranjen.",
  "Runnerfehler; gespeicherter Fortschritt bleibt erhalten."
 ],
 "SERVER": [
  "Povezava ni uspela. Shranjeno stanje ni potrjeno.",
  "Verbindung fehlgeschlagen. Gespeicherter Zustand unbestätigt."
 ],
 "NOT_AUTHORIZED": [
  "Dostop ni dovoljen.",
  "Zugriff verweigert."
 ],
 "EXPIRED": [
  "Seja je potekla.",
  "Sitzung abgelaufen."
 ],
 "STALE_VERSION": [
  "Stanje se je spremenilo. Zapri in znova preglej dejanje.",
  "Zustand geändert. Schließen und Aktion erneut prüfen."
 ],
 "VALIDATION_FAILED": [
  "Preveri vnesene vrednosti.",
  "Eingaben prüfen."
 ],
 "OPERATION_REUSED": [
  "Identifikator zahtevka je že uporabljen.",
  "Anfragekennung bereits verwendet."
 ],
 "SIMULATION_DISABLED": [
  "Simulacija je onemogočena.",
  "Simulation deaktiviert."
 ],
 "INVALID_SIMULATION_STATE": [
  "Neveljavno stanje simulacije.",
  "Ungültiger Simulationszustand."
 ],
 "INVALID_SIMULATION_UNIT": [
  "Enota ni na voljo za simulacijo.",
  "Einheit für Simulation nicht verfügbar."
 ]
};
export const agentText=(locale:Locale)=>(key:string):string=>key.startsWith('SIM_CONTROL_')?agentText(locale)(key.slice(12)):(labels[key]?.[locale==='de'?1:0]??key);
