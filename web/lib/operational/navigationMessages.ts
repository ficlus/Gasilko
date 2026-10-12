import type {Locale} from '../i18n';
const messages:Record<string,readonly [string,string]>={
 "title": [
  "Navigacija",
  "Navigation"
 ],
 "prepare": [
  "Pripravi cestno pot",
  "Straßenroute vorbereiten"
 ],
 "manual": [
  "Izberi ročno izhodišče na karti",
  "Manuellen Startpunkt auf der Karte wählen"
 ],
 "SIMULATED_POSITION": [
  "SIM položaj",
  "SIM-Position"
 ],
 "ACTUAL_POSITION": [
  "Dejanski položaj",
  "Tatsächliche Position"
 ],
 "MANUAL_PLANNING_POINT": [
  "Ročno izhodišče — samo načrtovanje",
  "Manueller Startpunkt — nur Planung"
 ],
 "unavailable": [
  "Trenutni položaj ni na voljo. Izberite ročno izhodišče.",
  "Aktuelle Position nicht verfügbar. Manuellen Startpunkt wählen."
 ],
 "originHelp": [
  "Kliknite izhodišče na karti in ga nato izrecno potrdite. To ni GPS položaj in ne premakne enote.",
  "Startpunkt auf der Karte wählen und ausdrücklich bestätigen. Dies ist keine GPS-Position und bewegt die Einheit nicht."
 ],
 "confirm": [
  "Potrdi",
  "Bestätigen"
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
  "Ponovi prejšnjo operacijo",
  "Vorherigen Vorgang wiederholen"
 ],
 "pending": [
  "Izid še ni potrjen. Ponovitev ohrani isti zahtevek in UUID.",
  "Ergebnis noch unbestätigt. Wiederholung behält Anfrage und UUID bei."
 ],
 "loading": [
  "Nalaganje …",
  "Wird geladen …"
 ],
 "empty": [
  "Ni primernih dodelitev MOVE_TO/WITHDRAW_TO v tem obsegu.",
  "Keine geeigneten MOVE_TO/WITHDRAW_TO-Zuweisungen in diesem Bereich."
 ],
 "open": [
  "Odpri navigacijo",
  "Navigation öffnen"
 ],
 "show": [
  "Prikaži pot na karti",
  "Route auf Karte zeigen"
 ],
 "recalculate": [
  "Preračunaj pot",
  "Route neu berechnen"
 ],
 "distance": [
  "Cestna razdalja",
  "Straßenentfernung"
 ],
 "duration": [
  "Načrtovani čas vožnje",
  "Geplante Fahrzeit"
 ],
 "provider": [
  "Ponudnik",
  "Anbieter"
 ],
 "calculated": [
  "Izračunano",
  "Berechnet"
 ],
 "stale": [
  "Pot je zastarela glede na SIM položaj. Preračun zahteva vašo odločitev.",
  "Route gegenüber SIM-Position veraltet. Neuberechnung erfordert Ihre Entscheidung."
 ],
 "older": [
  "Starejši položaj",
  "Ältere Position"
 ],
 "planningNotice": [
  "Pot ni dokaz premikanja, potrditve naloge ali prihoda. Čas vožnje ni živa ETA.",
  "Die Route belegt weder Bewegung, Aufgabenbestätigung noch Ankunft. Fahrzeit ist keine Live-ETA."
 ],
 "snap": [
  "Cestni dostop je od izvirnega izhodišča/cilja oddaljen (m)",
  "Straßenzugang vom ursprünglichen Start/Ziel entfernt (m)"
 ],
 "snapWarning": [
  "Preverite cestni dostop: izvirni položaj lahko leži daleč od izračunane ceste.",
  "Straßenzugang prüfen: Die ursprüngliche Position kann weit von der berechneten Straße liegen."
 ],
 "history": [
  "Zgodovina poti",
  "Routenverlauf"
 ],
 "events": [
  "Dogodki navigacije",
  "Navigationsereignisse"
 ],
 "previous": [
  "Prejšnja stran",
  "Vorherige Seite"
 ],
 "next": [
  "Naslednja stran",
  "Nächste Seite"
 ],
 "current": [
  "Trenutna pot",
  "Aktuelle Route"
 ],
 "historical": [
  "Zgodovinska pot — samo ogled",
  "Historische Route — nur Ansicht"
 ],
 "olderRoutes": [
  "Starejše različice",
  "Ältere Revisionen"
 ],
 "newSession": [
  "Pripravi nov načrt",
  "Neuen Plan vorbereiten"
 ],
 "START": [
  "Začni navigacijo",
  "Navigation starten"
 ],
 "PAUSE": [
  "Začasno ustavi",
  "Pausieren"
 ],
 "RESUME": [
  "Nadaljuj",
  "Fortsetzen"
 ],
 "STOP": [
  "Ustavi navigacijo",
  "Navigation stoppen"
 ],
 "CANCEL": [
  "Prekliči navigacijo",
  "Navigation abbrechen"
 ],
 "ARRIVE": [
  "Prijavi prihod",
  "Ankunft melden"
 ],
 "SUPERSEDE": [
  "Nadomesti s pripravljenim načrtom",
  "Durch vorbereiteten Plan ersetzen"
 ],
 "replacement": [
  "UUID nadomestnega pripravljenega načrta",
  "UUID des vorbereiteten Ersatzplans"
 ],
 "PLANNED": [
  "Načrtovano",
  "Geplant"
 ],
 "ACTIVE": [
  "Navigacija aktivna",
  "Navigation aktiv"
 ],
 "PAUSED": [
  "Začasno ustavljeno",
  "Pausiert"
 ],
 "STOPPED": [
  "Ustavljeno",
  "Gestoppt"
 ],
 "CANCELLED": [
  "Preklicano",
  "Abgebrochen"
 ],
 "SUPERSEDED": [
  "Nadomeščeno",
  "Ersetzt"
 ],
 "ARRIVED_REPORTED": [
  "Prihod prijavljen",
  "Ankunft gemeldet"
 ],
 "executorNotice": [
  "Zagon/prihod zahteva veljavnega vodjo enote in ustrezno potrditev naloge.",
  "Start/Ankunft erfordert eine berechtigte Einheitsleitung und die erforderliche Aufgabenbestätigung."
 ],
 "NOT_AUTHORIZED": [
  "Nimate več potrebnih pooblastil.",
  "Die erforderliche Berechtigung fehlt."
 ],
 "EXPIRED": [
  "Prijava je potekla.",
  "Anmeldung abgelaufen."
 ],
 "SERVER": [
  "Odgovor ni potrjen. Ohranjen je izvirni zahtevek za ponovitev.",
  "Antwort unbestätigt. Ursprüngliche Anfrage zur Wiederholung gespeichert."
 ],
 "STALE_VERSION": [
  "Podatki so se spremenili. Osvežite in ponovno preglejte pripravo.",
  "Daten wurden geändert. Aktualisieren und Vorbereitung erneut prüfen."
 ],
 "OPERATION_REUSED": [
  "Ta UUID že pripada drugemu zahtevku.",
  "Diese UUID gehört bereits zu einer anderen Anfrage."
 ],
 "VALIDATION_FAILED": [
  "Neveljavni podatki navigacije.",
  "Ungültige Navigationsdaten."
 ],
 "SIMULATION_DISABLED": [
  "Simulacija je izklopljena ali začasno ustavljena.",
  "Simulation ist deaktiviert oder pausiert."
 ],
 "NAV_INVALID_ASSIGNMENT": [
  "Dodelitev ne podpira cestne navigacije.",
  "Zuweisung unterstützt keine Straßennavigation."
 ],
 "NAV_INVALID_TARGET": [
  "Izdani cilj nima veljavnega točkovnega položaja.",
  "Ausgegebenes Ziel hat keine gültige Punktposition."
 ],
 "NAV_INVALID_STATE": [
  "Stanje naloge, enote ali navigacije tega ne dovoljuje.",
  "Aufgaben-, Einheits- oder Navigationszustand erlaubt dies nicht."
 ],
 "NAV_POSITION_UNAVAILABLE": [
  "Pooblaščeni položaj ni na voljo.",
  "Autorisierte Position nicht verfügbar."
 ],
 "NAV_SESSION_EXISTS": [
  "Dodelitev že ima odprt navigacijski načrt.",
  "Zuweisung besitzt bereits einen offenen Navigationsplan."
 ],
 "NAV_ACTIVE_EXISTS": [
  "Enota že ima drugo aktivno navigacijo. Najprej jo izrecno ustavite ali nadomestite.",
  "Einheit hat bereits eine andere aktive Navigation. Diese zuerst ausdrücklich stoppen oder ersetzen."
 ],
 "NAV_ACK_REQUIRED": [
  "Najprej uporabite obstoječi postopek potrditve naloge.",
  "Zuerst den bestehenden Ablauf zur Aufgabenbestätigung verwenden."
 ],
 "NAV_LIMIT": [
  "Dosežena je omejitev zahtevkov. Poskusite pozneje.",
  "Anfragelimit erreicht. Später erneut versuchen."
 ],
 "NAV_BUSY": [
  "Izračun je še rezerviran. Isti zahtevek ponovite čez približno dve minuti.",
  "Berechnung noch reserviert. Dieselbe Anfrage in etwa zwei Minuten wiederholen."
 ],
 "ROUTE_LIMIT": [
  "Pot presega omejitev ponudnika ali velikosti.",
  "Route überschreitet Anbieter- oder Größenlimit."
 ],
 "ROUTE_UNREACHABLE": [
  "Ponudnik ne more izračunati prevozne poti.",
  "Anbieter kann keine befahrbare Route berechnen."
 ],
 "ROUTE_CONFIGURATION": [
  "Strežniška konfiguracija usmerjanja ni na voljo.",
  "Serverkonfiguration für Routing nicht verfügbar."
 ],
 "ROUTE_PROVIDER": [
  "Ponudnik poti trenutno ni na voljo. Prejšnja pot je ohranjena.",
  "Routenanbieter derzeit nicht verfügbar. Vorherige Route bleibt erhalten."
 ],
 "ROUTE_COORDINATES": [
  "Koordinate poti niso veljavne.",
  "Routenkoordinaten sind ungültig."
 ]
};
export const navigationText=(locale:Locale)=>(key:string)=>messages[key]?.[locale==='de'?1:0]??key;
