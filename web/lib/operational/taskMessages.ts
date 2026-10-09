import type {Locale} from '../i18n';
const messages:Record<string,readonly [string,string]>={
 "INVALID_GEOMETRY":["Geometrija cilja ni veljavna.","Zielgeometrie ist ungültig."],
 "UNSUPPORTED_GEOMETRY":["Ta geometrija cilja ni podprta.","Diese Zielgeometrie wird nicht unterstützt."],
 "GEOMETRY_TOO_LARGE":["Geometrija cilja je prevelika.","Zielgeometrie ist zu groß."],
 "INCIDENT_TERMINAL":["Intervencija ni več odprta za ukaze.","Einsatz ist nicht mehr für Befehle offen."],
 "STALE_VERSION":["Podatki so zastareli. Ponovno jih preglej in potrdi.","Daten sind veraltet. Erneut prüfen und bestätigen."],
 "tasks": [
  "Naloge in ukazi",
  "Aufgaben und Befehle"
 ],
 "catalog": [
  "Katalog operativnih dejanj",
  "Operativer Aktionskatalog"
 ],
 "system": [
  "Sistemska predloga · samo branje",
  "Systemvorlage · schreibgeschützt"
 ],
 "custom": [
  "Organizacijsko dejanje",
  "Organisationsaktion"
 ],
 "catalogNotice": [
  "Upravljanje kataloga ne daje pravice do poveljevanja na intervenciji.",
  "Katalogverwaltung erteilt keine Befehlsbefugnis im Einsatz."
 ],
 "newAction": [
  "Novo dejanje",
  "Neue Aktion"
 ],
 "editVersion": [
  "Uredi kot novo različico",
  "Als neue Version bearbeiten"
 ],
 "version": [
  "Različica",
  "Version"
 ],
 "code": [
  "Stabilna koda",
  "Stabiler Code"
 ],
 "label_sl": [
  "Naziv (slovenščina)",
  "Bezeichnung (Slowenisch)"
 ],
 "label_de": [
  "Naziv (nemščina)",
  "Bezeichnung (Deutsch)"
 ],
 "description_sl": [
  "Opis (slovenščina)",
  "Beschreibung (Slowenisch)"
 ],
 "description_de": [
  "Opis (nemščina)",
  "Beschreibung (Deutsch)"
 ],
 "native": [
  "Izvorno vedenje",
  "Systemverhalten"
 ],
 "ack": [
  "Zahtevaj potrditev prejema",
  "Empfangsbestätigung erforderlich"
 ],
 "futureActive": [
  "Različica na voljo za nove ukaze",
  "Version für neue Befehle verfügbar"
 ],
 "active": [
  "Aktivno",
  "Aktiv"
 ],
 "inactive": [
  "Neaktivno",
  "Inaktiv"
 ],
 "recipients": [
  "Prejemniki",
  "Empfänger"
 ],
 "targets": [
  "Dovoljeni cilji",
  "Erlaubte Ziele"
 ],
 "parameters": [
  "Parametri",
  "Parameter"
 ],
 "addParameter": [
  "Dodaj parameter",
  "Parameter hinzufügen"
 ],
 "remove": [
  "Odstrani",
  "Entfernen"
 ],
 "required": [
  "Obvezno",
  "Pflichtfeld"
 ],
 "min": [
  "Minimum",
  "Minimum"
 ],
 "max": [
  "Maksimum",
  "Maximum"
 ],
 "max_length": [
  "Največ znakov",
  "Maximale Zeichenanzahl"
 ],
 "sort_order": [
  "Vrstni red",
  "Reihenfolge"
 ],
 "options": [
  "Možnosti izbire",
  "Auswahloptionen"
 ],
 "addOption": [
  "Dodaj možnost",
  "Option hinzufügen"
 ],
 "parameterType": [
  "Tip parametra",
  "Parametertyp"
 ],
 "NONE": [
  "Brez izvornega vedenja / brez cilja",
  "Kein Systemverhalten / kein Ziel"
 ],
 "MOVE_TO": [
  "Premakni se na",
  "Bewege dich zu"
 ],
 "HOLD_POSITION": [
  "Zadrži položaj",
  "Position halten"
 ],
 "WITHDRAW_TO": [
  "Umakni se na",
  "Rückzug zu"
 ],
 "REQUEST_STATUS": [
  "Sporoči stanje",
  "Status melden"
 ],
 "INCIDENT_UNIT": [
  "Intervencijska enota",
  "Einsatzeinheit"
 ],
 "INCIDENT_CREW_MEMBER": [
  "Član posadke",
  "Besatzungsmitglied"
 ],
 "HYDRANT": [
  "Hidrant",
  "Hydrant"
 ],
 "INCIDENT_MAP_OBJECT": [
  "Objekt na karti",
  "Kartenobjekt"
 ],
 "INCIDENT_SECTOR": [
  "Sektor",
  "Abschnitt"
 ],
 "COORDINATE": [
  "Koordinate",
  "Koordinaten"
 ],
 "TEXT": [
  "Besedilo",
  "Text"
 ],
 "INTEGER": [
  "Celo število",
  "Ganzzahl"
 ],
 "DECIMAL": [
  "Decimalno število",
  "Dezimalzahl"
 ],
 "BOOLEAN": [
  "Da / ne",
  "Ja / nein"
 ],
 "CHOICE": [
  "Izbira",
  "Auswahl"
 ],
 "LOW": [
  "Nizka",
  "Niedrig"
 ],
 "NORMAL": [
  "Običajna",
  "Normal"
 ],
 "HIGH": [
  "Visoka",
  "Hoch"
 ],
 "CRITICAL": [
  "Kritična",
  "Kritisch"
 ],
 "OPEN": [
  "Odprto",
  "Offen"
 ],
 "CLOSED": [
  "Zaključeno",
  "Abgeschlossen"
 ],
 "CANCELLED": [
  "Preklicano",
  "Abgebrochen"
 ],
 "SUCCESS": [
  "Uspešno",
  "Erfolgreich"
 ],
 "PARTIAL": [
  "Delno uspešno",
  "Teilweise erfolgreich"
 ],
 "FAILED": [
  "Neuspešno",
  "Fehlgeschlagen"
 ],
 "ISSUED": [
  "Izdano",
  "Erteilt"
 ],
 "ACKNOWLEDGED": [
  "Prejem potrjen",
  "Empfang bestätigt"
 ],
 "IN_PROGRESS": [
  "V izvajanju",
  "In Bearbeitung"
 ],
 "BLOCKED": [
  "Ovirano",
  "Blockiert"
 ],
 "COMPLETED": [
  "Opravljeno",
  "Erledigt"
 ],
 "UNABLE": [
  "Ni mogoče izvesti",
  "Nicht ausführbar"
 ],
 "issue_task": [
  "Izdaj nalogo",
  "Aufgabe erteilen"
 ],
 "transition_task_assignment": [
  "Potrdi spremembo izvajanja",
  "Ausführungsänderung bestätigen"
 ],
 "cancel_task": [
  "Prekliči celotno nalogo",
  "Gesamte Aufgabe abbrechen"
 ],
 "createHere": [
  "Ustvari nalogo tukaj",
  "Hier Aufgabe erstellen"
 ],
 "issueToUnit": [
  "Izdaj nalogo enoti",
  "Aufgabe an Einheit erteilen"
 ],
 "newTask": [
  "Nova naloga",
  "Neue Aufgabe"
 ],
 "openTasks": [
  "Odprte naloge",
  "Offene Aufgaben"
 ],
 "history": [
  "Zaključene naloge / zgodovina",
  "Abgeschlossene Aufgaben / Verlauf"
 ],
 "title": [
  "Kratek naslov",
  "Kurztitel"
 ],
 "notes": [
  "Opombe",
  "Hinweise"
 ],
 "priority": [
  "Prednost",
  "Priorität"
 ],
 "action": [
  "Dejanje",
  "Aktion"
 ],
 "target": [
  "Cilj",
  "Ziel"
 ],
 "entityId": [
  "UUID cilja",
  "Ziel-UUID"
 ],
 "longitude": [
  "Zemljepisna dolžina",
  "Längengrad"
 ],
 "latitude": [
  "Zemljepisna širina",
  "Breitengrad"
 ],
 "intentNotice": [
  "Ukaz je namera. Ne premakne enote in ne ustvari poti, ETA ali GPS-položaja.",
  "Ein Befehl ist eine Absicht. Er bewegt keine Einheit und erzeugt keine Route, ETA oder GPS-Position."
 ],
 "review": [
  "Preglej pred potrditvijo",
  "Vor Bestätigung prüfen"
 ],
 "confirm": [
  "Potrdi",
  "Bestätigen"
 ],
 "back": [
  "Nazaj na urejanje",
  "Zurück zur Bearbeitung"
 ],
 "dismiss": [
  "Zapri",
  "Schließen"
 ],
 "save": [
  "Shrani novo različico",
  "Neue Version speichern"
 ],
 "refresh": [
  "Osveži",
  "Aktualisieren"
 ],
 "retry": [
  "Ponovi isti zahtevek",
  "Gleiche Anfrage wiederholen"
 ],
 "pending": [
  "Izid še ni znan. Ponovitev ohrani iste identifikatorje in vsebino.",
  "Ergebnis noch unbekannt. Wiederholung behält dieselben IDs und Inhalte."
 ],
 "stale": [
  "Podatki so se spremenili. Namen je ohranjen; osveži ter izrecno ponovno uredi in potrdi.",
  "Daten wurden geändert. Absicht bleibt erhalten; aktualisieren, ausdrücklich bearbeiten und erneut bestätigen."
 ],
 "reedit": [
  "Ponovno uredi z aktualnimi podatki",
  "Mit aktuellen Daten erneut bearbeiten"
 ],
 "search": [
  "Iskanje",
  "Suche"
 ],
 "previous": [
  "Prejšnja stran",
  "Vorherige Seite"
 ],
 "next": [
  "Naslednja stran",
  "Nächste Seite"
 ],
 "empty": [
  "Ni zapisov.",
  "Keine Einträge."
 ],
 "loading": [
  "Nalaganje …",
  "Wird geladen …"
 ],
 "select": [
  "Izberi",
  "Auswählen"
 ],
 "reason": [
  "Razlog",
  "Grund"
 ],
 "yes": [
  "Da",
  "Ja"
 ],
 "no": [
  "Ne",
  "Nein"
 ],
 "issuer": [
  "Izdal",
  "Erteilt von"
 ],
 "issued": [
  "Čas izdaje",
  "Erteilt am"
 ],
 "saved": [
  "Shranjeno.",
  "Gespeichert."
 ],
 "targetMismatch": [
  "Dejanje ne dovoljuje tega cilja. Izberi združljivo dejanje ali cilj.",
  "Aktion erlaubt dieses Ziel nicht. Passende Aktion oder passendes Ziel wählen."
 ],
 "pointNotice": [
  "Za premik je obvezna izrecna točka; sektorji in poligoni se ne pretvarjajo v središča.",
  "Bewegung benötigt einen expliziten Punkt; Abschnitte und Polygone werden nicht in Mittelpunkte umgewandelt."
 ],
 "INVALID_ACTION_DEFINITION": [
  "Dejanje ni več na voljo v tej različici.",
  "Aktion ist in dieser Version nicht mehr verfügbar."
 ],
 "INVALID_ACTION_PARAMETERS": [
  "Parametri niso skladni z različico dejanja.",
  "Parameter entsprechen nicht der Aktionsversion."
 ],
 "INVALID_TASK_TARGET": [
  "Cilj ni veljaven ali ni dostopen.",
  "Ziel ist ungültig oder nicht zugänglich."
 ],
 "TASK_POINT_REQUIRED": [
  "Izberi veljaven točkovni cilj.",
  "Gültiges Punktziel auswählen."
 ],
 "INVALID_TASK_RECIPIENT": [
  "Prejemnik ni več veljaven ali ni v tvojem obsegu poveljevanja.",
  "Empfänger ist nicht mehr gültig oder außerhalb deiner Befehlsbefugnis."
 ],
 "INVALID_TASK_TRANSITION": [
  "Ta sprememba izvajanja ni dovoljena.",
  "Diese Ausführungsänderung ist nicht erlaubt."
 ],
 "TASK_NOT_FOUND": [
  "Naloga ni dostopna.",
  "Aufgabe ist nicht zugänglich."
 ],
 "TASK_LIMIT_REACHED": [
  "Dosežena je omejitev nalog ali prejemnikov.",
  "Aufgaben- oder Empfängerlimit erreicht."
 ],
 "UNRESOLVED_TASKS": [
  "Najprej razreši ali izrecno prekliči odprte naloge.",
  "Zuerst offene Aufgaben abschließen oder ausdrücklich abbrechen."
 ],
 "NOT_AUTHORIZED": [
  "Dostop ni dovoljen.",
  "Zugriff nicht erlaubt."
 ],
 "EXPIRED": [
  "Seja je potekla.",
  "Sitzung abgelaufen."
 ],
 "SERVER": [
  "Zahteve ni bilo mogoče potrditi.",
  "Anfrage konnte nicht bestätigt werden."
 ],
 "VALIDATION_FAILED": [
  "Preveri vnesene podatke.",
  "Eingaben prüfen."
 ],
 "OPERATION_REUSED": [
  "Identifikator operacije je že uporabljen za drugo vsebino.",
  "Operations-ID wurde bereits für andere Inhalte verwendet."
 ],
 "TASK_ISSUED": [
  "Naloga izdana",
  "Aufgabe erteilt"
 ],
 "TASK_CANCELLED": [
  "Naloga preklicana",
  "Aufgabe abgebrochen"
 ],
 "TASK_CLOSED": [
  "Naloga zaključena",
  "Aufgabe abgeschlossen"
 ],
 "TASK_ASSIGNMENT_ACKNOWLEDGED": [
  "Prejem naloge potrjen",
  "Aufgabenempfang bestätigt"
 ],
 "TASK_ASSIGNMENT_STARTED": [
  "Izvajanje naloge začeto",
  "Aufgabenausführung gestartet"
 ],
 "TASK_ASSIGNMENT_BLOCKED": [
  "Izvajanje naloge ovirano",
  "Aufgabenausführung blockiert"
 ],
 "TASK_ASSIGNMENT_COMPLETED": [
  "Prejemnik opravil nalogo",
  "Empfänger hat Aufgabe erledigt"
 ],
 "TASK_ASSIGNMENT_UNABLE": [
  "Prejemnik ne more izvesti naloge",
  "Empfänger kann Aufgabe nicht ausführen"
 ],
 "TASK_ASSIGNMENT_CANCELLED": [
  "Dodelitev naloge preklicana",
  "Aufgabenzuweisung abgebrochen"
 ]
};
export function taskText(locale:Locale){return (key:string)=>messages[key]?.[locale==='de'?1:0]??key;}
