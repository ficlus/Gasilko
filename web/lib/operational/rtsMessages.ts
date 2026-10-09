import type {Locale} from '../i18n';
const messages:Record<string,readonly [string,string]>={
 "rtsTitle": [
  "Izbira prejemnikov",
  "Empfängerauswahl"
 ],
 "selected": [
  "Izbrani prejemniki",
  "Ausgewählte Empfänger"
 ],
 "chooseAction": [
  "Izberi dejanje",
  "Aktion wählen"
 ],
 "clear": [
  "Počisti izbiro",
  "Auswahl leeren"
 ],
 "remove": [
  "Odstrani iz izbire",
  "Aus Auswahl entfernen"
 ],
 "box": [
  "Pravokotna izbira",
  "Rechteckauswahl"
 ],
 "lasso": [
  "Prostoročna izbira",
  "Freihandauswahl"
 ],
 "normal": [
  "Običajni način karte",
  "Normaler Kartenmodus"
 ],
 "cancelMode": [
  "Prekliči način izbire",
  "Auswahlmodus beenden"
 ],
 "noPositions": [
  "Enote nimajo avtoritativnih podatkov o dejanskem položaju. Izberi jih na seznamu; pravokotnik in lasso ne izbirata sektorjev ali hidrantov.",
  "Für Einheiten liegen keine autoritativen tatsächlichen Positionen vor. In der Liste auswählen; Rechteck und Lasso wählen keine Abschnitte oder Hydranten."
 ],
 "noMatches": [
  "Na tem območju ni prikazanih prejemnikov z dejanskim položajem.",
  "In diesem Bereich sind keine Empfänger mit tatsächlicher Position dargestellt."
 ],
 "selectionLimit": [
  "Največ 100 prejemnikov. Obstoječa izbira je ohranjena; zmanjšaj izbor.",
  "Maximal 100 Empfänger. Die bisherige Auswahl bleibt erhalten; Auswahl verkleinern."
 ],
 "merge": [
  "Dodaj območje k izbiri",
  "Bereich zur Auswahl hinzufügen"
 ],
 "multiTouch": [
  "Večkratna izbira z dotikom",
  "Mehrfachauswahl per Berührung"
 ],
 "visible": [
  "Izberi prikazane upravičene prejemnike",
  "Sichtbare berechtigte Empfänger auswählen"
 ],
 "eligible": [
  "Trenutno na voljo za ukaz",
  "Derzeit für Befehl verfügbar"
 ],
 "unknown": [
  "Upravičenost še ni potrjena",
  "Berechtigung noch nicht bestätigt"
 ],
 "unavailable": [
  "Prejemnik trenutno ni na voljo za ta ukaz",
  "Empfänger ist für diesen Befehl derzeit nicht verfügbar"
 ],
 "unsupported": [
  "Različica dejanja ne podpira tega tipa prejemnika",
  "Aktionsversion unterstützt diesen Empfängertyp nicht"
 ],
 "eligibleCount": [
  "Združljivi in trenutno na voljo",
  "Kompatibel und derzeit verfügbar"
 ],
 "invalidCount": [
  "Nerazpoložljivi / nezdružljivi",
  "Nicht verfügbar / inkompatibel"
 ],
 "unknownCount": [
  "Nepotrjeni",
  "Nicht bestätigt"
 ],
 "eligibilityNotice": [
  "Vidnost in izbira ne dajeta pravice do ukaza. Strežnik ob potrditvi ponovno preveri vse prejemnike.",
  "Sichtbarkeit und Auswahl erteilen keine Befehlsbefugnis. Der Server prüft bei Bestätigung alle Empfänger erneut."
 ],
 "resolveRecipients": [
  "Pred potrditvijo odstrani ali ponovno preveri neveljavne prejemnike.",
  "Vor Bestätigung ungültige Empfänger entfernen oder erneut prüfen."
 ],
 "checkRecipients": [
  "Ponovno preveri izbrane prejemnike",
  "Ausgewählte Empfänger erneut prüfen"
 ],
 "checking": [
  "Preverjanje izbire …",
  "Auswahl wird geprüft …"
 ],
 "palette": [
  "Izberi konfigurirano dejanje",
  "Konfigurierte Aktion wählen"
 ],
 "paletteHelp": [
  "Izbira dejanja ne izda ukaza. Sledita cilj in izrecna potrditev.",
  "Aktionswahl erteilt keinen Befehl. Zielwahl und ausdrückliche Bestätigung folgen."
 ],
 "targetOnMap": [
  "Izberi cilj na karti",
  "Ziel auf Karte wählen"
 ],
 "mapTargetKind": [
  "Vrsta cilja za klik na karti",
  "Zieltyp für Kartenklick"
 ],
 "targetMode": [
  "Izbira cilja: klik samo predizpolni obrazec",
  "Zielwahl: Klick füllt nur das Formular aus"
 ],
 "wrongTarget": [
  "Klikni dovoljen cilj izbrane vrste. Geometrija ne daje pooblastil.",
  "Erlaubtes Ziel des gewählten Typs anklicken. Geometrie erteilt keine Befugnisse."
 ],
 "pointRequired": [
  "To dejanje zahteva dejansko točko; poligon ali črta nista cilj premika.",
  "Diese Aktion benötigt einen tatsächlichen Punkt; Polygon oder Linie sind kein Bewegungsziel."
 ],
 "draftTarget": [
  "Predogled cilja · ukaz še ni izdan",
  "Zielvorschau · Befehl noch nicht erteilt"
 ],
 "issuedTarget": [
  "Cilj izdanega ukaza · namera, ne gibanje",
  "Ziel des erteilten Befehls · Absicht, keine Bewegung"
 ],
 "historyTarget": [
  "Zgodovinski posnetek cilja",
  "Historischer Zielschnappschuss"
 ],
 "selectedTarget": [
  "Izbrani cilj",
  "Ausgewähltes Ziel"
 ],
 "drawingBusy": [
  "Najprej zaključi ali prekliči urejanje objekta na karti.",
  "Zuerst Kartenobjektbearbeitung abschließen oder abbrechen."
 ],
 "shortcuts": [
  "B: pravokotnik · L: lasso · Ctrl/⌘ K: dejanja · Esc: preklic načina/obrazca. Bližnjice ne veljajo med tipkanjem.",
  "B: Rechteck · L: Lasso · Strg/⌘ K: Aktionen · Esc: Modus/Formular schließen. Keine Tastenkürzel während der Texteingabe."
 ],
 "listHints": [
  "Klik: en prejemnik · Ctrl/⌘: preklop · Shift: obseg te strani. Ctrl/⌘ A velja samo v tem seznamu.",
  "Klick: ein Empfänger · Strg/⌘: umschalten · Umschalt: Bereich dieser Seite. Strg/⌘ A gilt nur in dieser Liste."
 ],
 "gestureHelp": [
  "Povleci po karti. Za običajno premikanje karte prekliči orodje; zoom ostane na voljo.",
  "Über die Karte ziehen. Zum normalen Verschieben Werkzeug beenden; Zoom bleibt verfügbar."
 ],
 "authorityLost": [
  "Dostop do intervencije ni več na voljo. Izbira in podatki so odstranjeni.",
  "Einsatzzugriff ist nicht mehr verfügbar. Auswahl und Daten wurden entfernt."
 ],
 "readUnavailable": [
  "Podatkov za izdajo ni mogoče potrditi. Osveži pred nadaljevanjem.",
  "Daten zur Befehlserteilung können nicht bestätigt werden. Vor dem Fortfahren aktualisieren."
 ],
 "incident": [
  "Intervencija",
  "Einsatz"
 ],
 "actingOrg": [
  "Organizacija izdajatelja",
  "Handelnde Organisation"
 ],
 "recipientCount": [
  "Število prejemnikov",
  "Empfängeranzahl"
 ],
 "sector": [
  "Sektor",
  "Abschnitt"
 ],
 "state": [
  "Stanje",
  "Status"
 ],
 "closePalette": [
  "Zapri obrazec brez izdaje",
  "Formular ohne Erteilung schließen"
 ],
 "targetResolvedLater": [
  "Strežnik ob izdaji ponovno preveri kanonični cilj; predogled ni dokaz pooblastila.",
  "Server prüft das kanonische Ziel bei Erteilung erneut; Vorschau ist kein Berechtigungsnachweis."
 ],
 "actionChanged": [
  "Izbrana različica ni več na voljo. Namen je ohranjen; izrecno ponovno izberi dejanje in preveri parametre.",
  "Gewählte Version ist nicht mehr verfügbar. Absicht bleibt erhalten; Aktion ausdrücklich erneut auswählen und Parameter prüfen."
 ]
};
export const rtsText=(locale:Locale)=>(key:string)=>messages[key]?.[locale==='de'?1:0]??key;
