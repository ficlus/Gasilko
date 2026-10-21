import type {Locale} from '../i18n';
const messages:Record<string,[string,string]>={
 "IDLE": [
  "Pripravljeno",
  "Bereit"
 ],
 "SENDING": [
  "Shranjevanje …",
  "Wird gespeichert …"
 ],
 "CONFIRMED": [
  "Strežnik je potrdil zapis",
  "Server hat die Änderung bestätigt"
 ],
 "DEFINITIVELY_REJECTED": [
  "Zapis je zavrnjen. Popravite podatke.",
  "Änderung abgelehnt. Daten korrigieren."
 ],
 "OUTCOME_UNKNOWN": [
  "Izid ni znan. Izvirna operacija je shranjena; knjižnico lahko pregledujete.",
  "Ergebnis unbekannt. Originalaktion gespeichert; Bibliothek bleibt lesbar."
 ],
 "RECOVERING": [
  "Preverjanje potrdila …",
  "Bestätigung wird geprüft …"
 ],
 "reconcile": [
  "Preveri izid",
  "Ergebnis prüfen"
 ],
 "storage": [
  "Osnutka ali operacije ni mogoče varno shraniti v brskalnik. Ne zaprite urejevalnika.",
  "Entwurf oder Aktion kann nicht sicher im Browser gespeichert werden. Editor nicht schließen."
 ],
 "SCHEMA_MISMATCH": [
  "Različici aplikacije in strežnika nista usklajeni. Preverite namestitev SQL.",
  "App und Server sind nicht kompatibel. SQL-Bereitstellung prüfen."
 ],
 "INVALID_TEMPLATE": [
  "Neveljavna definicija scenarija. Preglejte osnovne podatke in položaje.",
  "Ungültige Szenariodefinition. Grunddaten und Positionen prüfen."
 ],
 "INVALID_EVENT_PLAN": [
  "Neveljaven načrt dogodkov. Preverite cilje, čas in omejitve.",
  "Ungültiger Ereignisplan. Ziele, Zeit und Grenzen prüfen."
 ],
 "INVALID_HAZARD_PLAN": [
  "Neveljaven načrt nevarnosti. Preverite območja, vžige in reference.",
  "Ungültiger Gefahrenplan. Bereiche, Zündpunkte und Verweise prüfen."
 ],
 "REQUEST_TOO_LARGE": [
  "Scenarij presega dovoljeno velikost zapisa.",
  "Szenario überschreitet die zulässige Größe."
 ],
 "SERVER": [
  "Strežnik ni na voljo; izid zapisa je lahko neznan.",
  "Server nicht verfügbar; Ergebnis möglicherweise unbekannt."
 ],
 "recovery": [
  "Na voljo je lokalni osnutek",
  "Lokaler Entwurf verfügbar"
 ],
 "compare": [
  "Primerjaj lokalni in strežniški osnutek",
  "Lokalen Entwurf mit Server vergleichen"
 ],
 "restore": [
  "Uporabi pregledani lokalni osnutek",
  "Geprüften lokalen Entwurf verwenden"
 ],
 "discardLocal": [
  "Zavrzi samo lokalni osnutek",
  "Nur lokalen Entwurf verwerfen"
 ],
 "local": [
  "Lokalno",
  "Lokal"
 ],
 "server": [
  "Strežnik",
  "Server"
 ],
 "revisionWarning": [
  "Strežniška revizija je spremenjena. Pred obnovo primerjajte vse razdelke.",
  "Serverrevision geändert. Vor Wiederherstellung alle Abschnitte vergleichen."
 ],
 "home": [
  "SIM — Usposabljanje",
  "SIM — Ausbildung"
 ],
 "quick": [
  "Nova hitra vaja",
  "Neue Schnellübung"
 ],
 "quickHelp": [
  "Štiri obstoječe predloge s semenom in območjem. Brez samodejno dodanega načrta požara ali dima.",
  "Vier bestehende Vorgaben mit Startwert und Gebiet. Kein automatisch ergänzter Feuer- oder Rauchplan."
 ],
 "scenarioHelp": [
  "Različice scenarijev z enotami, objekti, dogodki, požarom in dimom.",
  "Versionierte Szenarien mit Einheiten, Objekten, Ereignissen, Feuer und Rauch."
 ],
 "activeExercises": [
  "Aktivne vaje",
  "Aktive Übungen"
 ],
 "finishedExercises": [
  "Zaključene vaje",
  "Abgeschlossene Übungen"
 ],
 "overview": [
  "Osnovni podatki",
  "Grunddaten"
 ],
 "area": [
  "Zemljevid in položaji",
  "Karte und Positionen"
 ],
 "units": [
  "Virtualne enote",
  "Virtuelle Einheiten"
 ],
 "objects": [
  "Objekti",
  "Objekte"
 ],
 "hazards": [
  "Požar, dim in nevarnosti",
  "Feuer, Rauch und Gefahren"
 ],
 "events": [
  "Dinamični dogodki",
  "Dynamische Ereignisse"
 ],
 "settings": [
  "Nastavitve simulacije",
  "Simulationseinstellungen"
 ],
 "review": [
  "Pregled pripravljenosti",
  "Bereitschaft prüfen"
 ],
 "ready": [
  "Pripravljeno za strežniško preverjanje",
  "Bereit zur Serverprüfung"
 ],
 "referenceWarning": [
  "Odstranitev lahko prekine reference dogodkov ali nevarnosti. Pred shranjevanjem jih preglejte.",
  "Entfernen kann Ereignis- oder Gefahrenverweise unterbrechen. Vor dem Speichern prüfen."
 ],
 "layerHelp": [
  "Prikaz sloja ne ustvari požara ali dima. Potreben je omogočen model z vžigom oziroma razkritjem.",
  "Ein sichtbarer Layer erzeugt weder Feuer noch Rauch. Ein aktiviertes Modell mit Zündung bzw. Freigabe ist erforderlich."
 ],
 "source": [
  "Izvorna različica",
  "Quellversion"
 ],
 "lifecycle": [
  "Priprava in zaključek vaje",
  "Vorbereitung und Abschluss"
 ],
 "commandStep": [
  "1. Dodelite in potrdite poveljevanje",
  "1. Führung zuweisen und bestätigen"
 ],
 "activateStep": [
  "2. Aktivirajte učno intervencijo",
  "2. Übungseinsatz aktivieren"
 ],
 "initializeStep": [
  "3. Pripravite scenarij",
  "3. Szenario vorbereiten"
 ],
 "startStep": [
  "4. Zaženite simulacijo",
  "4. Simulation starten"
 ],
 "closeStep": [
  "Po zaključku simulacije zaprite učno intervencijo po običajnem postopku. Najprej razrešite aktivne vire in zahtevana soglasja.",
  "Nach Simulationsende den Übungseinsatz regulär schließen. Zuerst aktive Ressourcen freigeben und erforderliche Zustimmungen klären."
 ],
 "finishWarning": [
  "Zaključek ustavi simulacijo. Ne zaključi nalog ali intervencije in ne potrdi opravljenih dejavnosti.",
  "Beenden stoppt die Simulation. Aufgaben und Einsatz werden nicht abgeschlossen und Aktivitäten nicht bestätigt."
 ],
 "history": [
  "Zgodovinski pregled",
  "Historische Ansicht"
 ],
 "simStatus": [
  "Stanje simulacije",
  "Simulationsstatus"
 ],
 "incidentStatus": [
  "Stanje intervencije",
  "Einsatzstatus"
 ],
 "initializationStatus": [
  "Priprava scenarija",
  "Szenariovorbereitung"
 ],
 "emptyLayers": [
  "Prikaz uporablja le dovoljene razkrite podatke. Prazen sloj ne pomeni, da so skriti modeli razkriti.",
  "Die Anzeige verwendet nur freigegebene Daten. Ein leerer Layer gibt verborgene Modelle nicht preis."
 ],
 "historyEntry": [
  "Sprememba modela",
  "Modelländerung"
 ],
 "next": [
  "Naslednji korak",
  "Nächster Schritt"
 ],
 "updated": [
  "Posodobljeno",
  "Aktualisiert"
 ],
 "noFire": [
  "Ni vidnega aktivnega požarnega modela.",
  "Kein sichtbares aktives Feuermodell."
 ],
 "noSmoke": [
  "Ni vidnega aktivnega modela dima.",
  "Kein sichtbares aktives Rauchmodell."
 ]
};
export const workflowText=(locale:Locale)=>(key:string)=>messages[key]?.[locale==='de'?1:0]??key;
