import type {Locale} from '../i18n';
const sl:Record<string,string>={
 sampleAge:'Najstarejši potrjeni položaj',smooth:'Zgladi prikaz SIM (samo vizualno)',roadEndpoint:'Dosegljivi cestni konec',snapNotice:'Cestna pot se lahko konča pred natančno izbranim ciljem.',currentPosition:'Potrjeni trenutni položaj SIM',
 incomplete:'Branje poti ni popolno; prejšnji potrjeni posnetek je ohranjen.',revoked:'Dostop preklican — podatki so odstranjeni.',
 stack:'Prekrivajoče se oznake',selectAll:'Izberi vse enote',clearSelection:'Počisti izbor',fan:'Razpri / strni',
 stackHelp:'Ctrl/Shift doda ali odstrani enoto. Drugi objekti se samo odprejo za pregled.',
 correction:'Odpri SIM kontrole za popravek / ponovitev',queuedAt:'Čakanje od',

 task:'Naloga',references:'Reference',assignment:'Dodelitev',session:'Navigacijska seja',route:'Pot',revision:'Revizija',originalView:'Pokaži celotno izvorno pot (zgodovinski pregled)',routeReady:'Pot je pripravljena; začetek izvajanja še ni potrjen.',starting:'SIM agent čaka na začetek izvajanja.',
 routes:'Prikaži navigacijske poti',planned:'Načrtovane poti — niso dokaz dejanskega premikanja',
 tasks:'Naloge izbrane enote',empty:'Enota nima aktivne naloge.',loading:'Nalaganje nalog in poti …',
 unavailable:'Trenutnega stanja poti ni mogoče preveriti. Prikazan je zadnji potrjeni posnetek.',stale:'Povezava ni sveža — prikaz je zadnji potrjeni posnetek.',
 limited:'Dosežena je omejitev prikaza; seznam ni popoln. Nadaljnje naloge preverite v seznamu nalog.',
 movement:'Trenutno simulirano izvajanje',waiting:'Druga aktivna ali čakajoča naloga',
 realMovement:'Aktivna navigacija — premik ni potrjen z GPS',origin:'Izvorni načrtovani začetek',
 observed:'Čas opazovanja izvora (ni čas odhoda)',target:'Cilj',original:'Prvotna pot',
 remaining:'Preostanek SIM',eta:'Ocenjeni preostali čas SIM',focusOrigin:'Pokaži izvor',focusTarget:'Pokaži cilj',
 details:'Podrobnosti naloge',overlap:'Več poti ima isti cilj',close:'Zapri',real:'Načrt resnične intervencije',
 automation:'Samodejno izvajanje SIM',on:'VKLOPLJENO',off:'IZKLOPLJENO',unknown:'Stanje ni preverjeno',
 progress:'Potrjeni napredek SIM',noTelemetry:'Ni potrjenega napredka GPS; prikazana je celotna načrtovana pot.',
};
const de:Record<string,string>={
 sampleAge:'Älteste bestätigte Position',smooth:'SIM-Anzeige glätten (nur visuell)',roadEndpoint:'Erreichbares Straßenende',snapNotice:'Die Straßenroute kann vor dem genau gewählten Ziel enden.',currentPosition:'Bestätigte aktuelle SIM-Position',
 incomplete:'Routenabruf unvollständig; der vorherige bestätigte Stand bleibt erhalten.',revoked:'Zugriff entzogen — Daten entfernt.',
 stack:'Überlagerte Markierungen',selectAll:'Alle Einheiten auswählen',clearSelection:'Auswahl löschen',fan:'Auffächern / schließen',
 stackHelp:'Strg/Umschalt fügt eine Einheit hinzu oder entfernt sie. Andere Objekte werden nur angezeigt.',
 correction:'SIM-Steuerung für Korrektur / Wiederholung öffnen',queuedAt:'Wartet seit',

 task:'Auftrag',references:'Referenzen',assignment:'Zuweisung',session:'Navigationssitzung',route:'Route',revision:'Revision',originalView:'Vollständige ursprüngliche Route anzeigen (Historie)',routeReady:'Route bereit; Ausführungsbeginn noch nicht bestätigt.',starting:'SIM-Agent wartet auf den Ausführungsbeginn.',
 routes:'Navigationsrouten anzeigen',planned:'Geplante Routen — kein Nachweis tatsächlicher Bewegung',
 tasks:'Aufträge der ausgewählten Einheit',empty:'Die Einheit hat keinen aktiven Auftrag.',loading:'Aufträge und Routen werden geladen …',
 unavailable:'Der aktuelle Routenzustand ist nicht überprüfbar. Der letzte bestätigte Stand bleibt sichtbar.',stale:'Verbindung nicht aktuell — letzter bestätigter Stand.',
 limited:'Anzeigegrenze erreicht; die Liste ist unvollständig. Weitere Aufträge in der Auftragsliste prüfen.',
 movement:'Aktuelle simulierte Ausführung',waiting:'Weiterer aktiver oder wartender Auftrag',
 realMovement:'Aktive Navigation — Bewegung nicht durch GPS bestätigt',origin:'Ursprünglich geplanter Start',
 observed:'Beobachtungszeit des Ursprungs (keine Abfahrtszeit)',target:'Ziel',original:'Ursprüngliche Route',
 remaining:'SIM Reststrecke',eta:'Geschätzte SIM Restzeit',focusOrigin:'Ursprung anzeigen',focusTarget:'Ziel anzeigen',
 details:'Auftragsdetails',overlap:'Mehrere Routen mit demselben Ziel',close:'Schließen',real:'Plan eines realen Einsatzes',
 automation:'Automatische SIM-Ausführung',on:'EIN',off:'AUS',unknown:'Zustand nicht überprüft',
 progress:'Bestätigter SIM-Fortschritt',noTelemetry:'Kein bestätigter GPS-Fortschritt; vollständige geplante Route angezeigt.',
};
export const commandMapText=(locale:Locale)=>(key:string)=>(locale==='de'?de:sl)[key]??key;
