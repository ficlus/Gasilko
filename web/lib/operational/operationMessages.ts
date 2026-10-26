import type {Locale} from '../i18n';
const labels:Record<string,[string,string]>={
 "AWAITING_ACK":["Pripravljeno; čaka na potrditev naloge","Vorbereitet; wartet auf Aufgabenbestätigung"],
 "FLOW_BELOW_PRECISION":["Pretok je prenizek za merljiv korak porabe","Durchfluss zu niedrig für einen messbaren Verbrauchsschritt"],
 "RUNNING":["Vaja poteka","Übung läuft"],
 "PAUSED":["Vaja je zaustavljena; poraba miruje","Übung pausiert; kein Verbrauch"],
 "FINISHED":["Vaja je zaključena; prikazana je zgodovina","Übung beendet; Verlauf wird angezeigt"],
 "DRAFT":["Vaja še ni zagnana","Übung noch nicht gestartet"],
 "observed":["Podatki osveženi","Datenstand"],
 "reconnect":["Odklopite in ponovno povežite oskrbo, nato izrecno pripravite učinek","Versorgung trennen und neu verbinden, danach Wirkung ausdrücklich vorbereiten"],
 "confirmedCleanup":["Strežnik je potrdil operacijo, lokalni zapis ponovitve pa še ni odstranjen. Ponovitev ostane varna.","Server hat die Aktion bestätigt; lokaler Wiederholungseintrag noch vorhanden. Wiederholung bleibt sicher."],
 "resetHelp":["RESET ponastavi položaje in model požara ter ustavi učinke; porabljena voda, ura, naloge in zgodovina ostanejo. Za novo vajo iz začetnih pogojev ustvarite nov primerek scenarija.","RESET setzt Positionen und Feuermodell zurück und stoppt Wirkungen; Wasserverbrauch, Uhr, Aufgaben und Verlauf bleiben erhalten. Für Anfangsbedingungen eine neue Szenarioinstanz erstellen."],
 "ACK_TIMEOUT":["Čakanje na potrditev je poteklo","Warten auf Bestätigung abgelaufen"],
 "RESUME_ACTIVITY":["Ponovno pripravi blokirani učinek","Blockierte Wirkung erneut vorbereiten"],
 "RESUMED":["Izvedba ponovno pripravljena","Ausführung erneut vorbereitet"],
 "HISTORY_LIMIT":["Dosežena omejitev zgodovine vaje","Verlaufslimit der Übung erreicht"],
 "title": [
  "SIM · Voda in učinki",
  "SIM · Wasser und Wirkungen"
 ],
 "disclaimer": [
  "Učni parametri, ne dejanske meritve ali certificiran izračun gašenja.",
  "Übungsparameter, keine realen Messwerte oder zertifizierte Löschberechnung."
 ],
 "resources": [
  "Zmogljivosti učnih enot",
  "Fähigkeiten der Übungseinheiten"
 ],
 "configure": [
  "Nastavi zmogljivost",
  "Fähigkeit konfigurieren"
 ],
 "remove": [
  "Odstrani",
  "Entfernen"
 ],
 "capacity_l": [
  "Prostornina (L)",
  "Kapazität (L)"
 ],
 "initial_l": [
  "Začetna zaloga (L)",
  "Anfangsvorrat (L)"
 ],
 "pump_lpm": [
  "Črpalka (L/min)",
  "Pumpe (L/min)"
 ],
 "range_m": [
  "Doseg (m)",
  "Reichweite (m)"
 ],
 "efficiency": [
  "Učni koeficient zmanjšanja intenzivnosti/L",
  "Übungskoeffizient Intensitätsreduktion/L"
 ],
 "bindings": [
  "Izrecne povezave različic nalog",
  "Explizite Bindungen der Aufgabenversionen"
 ],
 "bindingHelp": [
  "Samo dejanja brez premikalnega vedenja. Izdaja ali potrditev naloge ne sproži gašenja; inštruktor mora izrecno pripraviti izvedbo.",
  "Nur Aktionen ohne Bewegungsverhalten. Ausgabe oder Bestätigung einer Aufgabe löst kein Löschen aus; Ausführung ausdrücklich vorbereiten."
 ],
 "action": [
  "Različica dejanja",
  "Aktionsversion"
 ],
 "add": [
  "Dodaj",
  "Hinzufügen"
 ],
 "flow_lpm": [
  "Pretok (L/min)",
  "Durchfluss (L/min)"
 ],
 "duration_seconds": [
  "Trajanje (s, večkratnik 5)",
  "Dauer (s, Vielfaches von 5)"
 ],
 "remaining": [
  "Preostala voda",
  "Verbleibendes Wasser"
 ],
 "supply": [
  "Vir oskrbe",
  "Versorgungsquelle"
 ],
 "tank": [
  "Lastni rezervoar",
  "Eigener Tank"
 ],
 "assignment": [
  "Naloga",
  "Aufgabe"
 ],
 "instructor": [
  "Izrecno dejanje inštruktorja",
  "Explizite Ausbilderaktion"
 ],
 "model": [
  "Razkrit model požara",
  "Freigegebenes Feuermodell"
 ],
 "longitude": [
  "Zemljepisna dolžina",
  "Längengrad"
 ],
 "latitude": [
  "Zemljepisna širina",
  "Breitengrad"
 ],
 "APPLY_WATER": [
  "Pripravi uporabo vode",
  "Wasserabgabe vorbereiten"
 ],
 "STOP_ACTIVITY": [
  "Ustavi učinek",
  "Wirkung stoppen"
 ],
 "REFILL": [
  "Dodaj učno zalogo",
  "Übungsvorrat ergänzen"
 ],
 "CONNECT_SUPPLY": [
  "Poveži oskrbo",
  "Versorgung verbinden"
 ],
 "DISCONNECT_SUPPLY": [
  "Odklopi oskrbo",
  "Versorgung trennen"
 ],
 "liters": [
  "Količina (L)",
  "Menge (L)"
 ],
 "reason": [
  "Obvezni razlog",
  "Erforderliche Begründung"
 ],
 "confirm": [
  "Potrdi učno dejanje",
  "Übungsaktion bestätigen"
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
  "Ponovi isto operacijo",
  "Dieselbe Aktion wiederholen"
 ],
 "pending": [
  "Izid ni potrjen. Ponovitev uporabi isti UUID in podatke.",
  "Ergebnis nicht bestätigt. Wiederholung verwendet dieselbe UUID und dieselben Daten."
 ],
 "empty": [
  "Ni nastavljenih učnih zalog. Dodajte jih v novo različico scenarija pred pripravo.",
  "Keine Übungsvorräte konfiguriert. Vor Vorbereitung in einer neuen Szenarioversion ergänzen."
 ],
 "history": [
  "Zgodovina učinkov",
  "Wirkungsverlauf"
 ],
 "older": [
  "Starejši zapisi",
  "Ältere Einträge"
 ],
 "latest": [
  "Najnovejši zapisi",
  "Neueste Einträge"
 ],
 "delivered": [
  "Dejansko oddana učna voda",
  "Tatsächlich abgegebenes Übungswasser"
 ],
 "progress": [
  "Izvedba",
  "Ausführung"
 ],
 "loading": [
  "Nalaganje …",
  "Wird geladen …"
 ],
 "stale": [
  "Podatki niso osveženi. Ne sklepajte o uspehu dejanja.",
  "Daten nicht aktuell. Daraus keinen Aktionserfolg ableiten."
 ],
 "PENDING": [
  "Čaka na izvedbo/potrditev naloge",
  "Wartet auf Ausführung/Aufgabenbestätigung"
 ],
 "ACTIVE": [
  "Izvajanje",
  "Aktiv"
 ],
 "BLOCKED": [
  "Blokirano",
  "Blockiert"
 ],
 "COMPLETED": [
  "Učinek zaključen; naloga ostane ločena",
  "Wirkung beendet; Aufgabe bleibt getrennt"
 ],
 "CANCELLED": [
  "Učinek preklican",
  "Wirkung abgebrochen"
 ],
 "ARMED": [
  "Izvedba pripravljena",
  "Ausführung vorbereitet"
 ],
 "STARTED": [
  "Učinek začet",
  "Wirkung gestartet"
 ],
 "STOPPED": [
  "Učinek ustavljen",
  "Wirkung gestoppt"
 ],
 "REFILLED": [
  "Učna zaloga dodana",
  "Übungsvorrat ergänzt"
 ],
 "CONNECTED": [
  "Oskrba povezana",
  "Versorgung verbunden"
 ],
 "DISCONNECTED": [
  "Oskrba odklopljena",
  "Versorgung getrennt"
 ],
 "DELIVERY": [
  "Poraba vode",
  "Wasserverbrauch"
 ],
 "WATER_DEPLETED": [
  "Voda porabljena",
  "Wasser erschöpft"
 ],
 "SUPPLY_DISCONNECTED": [
  "Oskrba odklopljena",
  "Versorgung getrennt"
 ],
 "SUPPLY_UNAVAILABLE": [
  "Oskrba ni na voljo",
  "Versorgung nicht verfügbar"
 ],
 "RESOURCE_UNAVAILABLE": [
  "Enota ni na voljo ali se je premaknila",
  "Einheit nicht verfügbar oder bewegt"
 ],
 "TARGET_UNAVAILABLE": [
  "Cilj ni na voljo",
  "Ziel nicht verfügbar"
 ],
 "TASK_UNAVAILABLE": [
  "Naloga ni več veljavna",
  "Aufgabe nicht mehr gültig"
 ],
 "OUT_OF_RANGE": [
  "Izven dosega",
  "Außer Reichweite"
 ],
 "NO_ACTIVE_CELLS": [
  "Ni aktivnih celic v območju",
  "Keine aktiven Zellen im Bereich"
 ],
 "DURATION": [
  "Trajanje zaključeno",
  "Dauer erreicht"
 ],
 "SIMULATION_RESET": [
  "Simulacija ponastavljena",
  "Simulation zurückgesetzt"
 ],
 "SIMULATION_FINISHED": [
  "Simulacija zaključena",
  "Simulation beendet"
 ],
 "OP_RESOURCE_UNAVAILABLE": [
  "Enota mora biti na voljo in mirovati.",
  "Einheit muss verfügbar sein und stillstehen."
 ],
 "OP_CATCHUP_REQUIRED": [
  "Počakajte na obdelavo požarnih korakov ali ustavite aktivni učinek.",
  "Auf Verarbeitung der Feuerschritte warten oder aktive Wirkung stoppen."
 ],
 "OP_CAPABILITY_REQUIRED": [
  "Manjka ustrezna učna zmogljivost.",
  "Geeignete Übungsfähigkeit fehlt."
 ],
 "OP_RESOURCE_BUSY": [
  "Vir je že zaseden; ustavite učinek ali odklopite oskrbo.",
  "Ressource bereits belegt; Wirkung stoppen oder Versorgung trennen."
 ],
 "OP_TARGET_UNAVAILABLE": [
  "Izberite razkrit aktivni model in veljaven cilj.",
  "Freigegebenes aktives Modell und gültiges Ziel wählen."
 ],
 "OP_TASK_UNAVAILABLE": [
  "Naloga ali njena izrecna povezava ni veljavna.",
  "Aufgabe oder explizite Bindung ist ungültig."
 ],
 "OP_OUT_OF_RANGE": [
  "Cilj ali vir je predaleč.",
  "Ziel oder Quelle ist zu weit entfernt."
 ],
 "INVALID_TEMPLATE": [
  "Preverite učno konfiguracijo.",
  "Übungskonfiguration prüfen."
 ],
 "unknown": [
  "Podatki niso na voljo",
  "Daten nicht verfügbar"
 ]
};
export const operationText=(locale:Locale)=>(key:string)=>labels[key]?.[locale==='de'?1:0]??labels.unknown[locale==='de'?1:0];
