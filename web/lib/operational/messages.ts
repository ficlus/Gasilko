import type {Locale} from '../i18n';
const labels:Record<string,readonly [string,string]>={
 "inventory": [
  "Operativna sredstva",
  "Operative Ressourcen"
 ],
 "VEHICLE": [
  "Vozila",
  "Fahrzeuge"
 ],
 "UNIT": [
  "Enote",
  "Einheiten"
 ],
 "RESOURCE": [
  "Sredstva",
  "Ressourcen"
 ],
 "resourcesTitle": [
  "Enote in sredstva",
  "Einheiten und Ressourcen"
 ],
 "callsign": [
  "Klicni znak",
  "Funkrufname"
 ],
 "name": [
  "Ime",
  "Name"
 ],
 "category_code": [
  "Kategorija",
  "Kategorie"
 ],
 "registration": [
  "Registracija",
  "Kennzeichen"
 ],
 "availability": [
  "Razpoložljivost",
  "Verfügbarkeit"
 ],
 "seats": [
  "Sedeži",
  "Sitzplätze"
 ],
 "water_litres": [
  "Voda (l)",
  "Wasser (l)"
 ],
 "capabilities": [
  "Zmogljivosti",
  "Fähigkeiten"
 ],
 "unit_kind": [
  "Vrsta enote",
  "Einheitentyp"
 ],
 "vehicle_id": [
  "Vozilo (neobvezno)",
  "Fahrzeug (optional)"
 ],
 "resource_type_code": [
  "Vrsta sredstva",
  "Ressourcentyp"
 ],
 "unit_of_measure_code": [
  "Merska enota",
  "Maßeinheit"
 ],
 "total_quantity": [
  "Skupna količina",
  "Gesamtmenge"
 ],
 "allocated_quantity": [
  "Dodeljena količina",
  "Zugewiesene Menge"
 ],
 "available_quantity": [
  "Razpoložljiva količina",
  "Verfügbare Menge"
 ],
 "active": [
  "Aktivno",
  "Aktiv"
 ],
 "inactive": [
  "Neaktivno",
  "Inaktiv"
 ],
 "create": [
  "Nov zapis",
  "Neuer Eintrag"
 ],
 "edit": [
  "Uredi",
  "Bearbeiten"
 ],
 "save": [
  "Preglej in shrani",
  "Prüfen und speichern"
 ],
 "confirm": [
  "Potrdi",
  "Bestätigen"
 ],
 "cancel": [
  "Prekliči",
  "Abbrechen"
 ],
 "retry": [
  "Ponovi isti zahtevek",
  "Gleiche Anfrage wiederholen"
 ],
 "refresh": [
  "Osveži",
  "Aktualisieren"
 ],
 "search": [
  "Iskanje",
  "Suche"
 ],
 "find": [
  "Poišči",
  "Suchen"
 ],
 "select": [
  "Izberite",
  "Auswählen"
 ],
 "none": [
  "Brez",
  "Keine"
 ],
 "loading": [
  "Nalaganje …",
  "Wird geladen …"
 ],
 "empty": [
  "Ni zapisov.",
  "Keine Einträge."
 ],
 "previous": [
  "Prejšnja stran",
  "Vorherige Seite"
 ],
 "next": [
  "Naslednja stran",
  "Nächste Seite"
 ],
 "history": [
  "Zgodovina",
  "Verlauf"
 ],
 "version": [
  "Različica",
  "Version"
 ],
 "reason": [
  "Razlog",
  "Grund"
 ],
 "status": [
  "Stanje",
  "Status"
 ],
 "organization": [
  "Organizacija",
  "Organisation"
 ],
 "sector": [
  "Sektor",
  "Sektor"
 ],
 "crew": [
  "Posadka",
  "Besatzung"
 ],
 "crew_role": [
  "Vloga v posadki",
  "Besatzungsrolle"
 ],
 "quantity": [
  "Količina",
  "Menge"
 ],
 "review": [
  "Preverite podatke. Sprememba bo shranjena šele po potrditvi.",
  "Daten prüfen. Die Änderung wird erst nach Bestätigung gespeichert."
 ],
 "manualOnScene": [
  "To je ročni zapis že prisotne enote, ne poziv ali odpošiljanje.",
  "Dies erfasst eine bereits anwesende Einheit, ohne Alarmierung oder Entsendung."
 ],
 "releaseCrew": [
  "Potrjujem konec vseh preostalih članstev posadke te enote. Aktivno vodenje in dodeljena sredstva morajo biti prej zaključena.",
  "Ich bestätige das Ende aller verbleibenden Besatzungszuordnungen. Aktive Führung und Ressourcenzuweisungen müssen zuvor beendet sein."
 ],
 "consumeWarning": [
  "Porabljena količina trajno zmanjša zalogo in ne bo več na voljo za dodelitev.",
  "Die verbrauchte Menge reduziert den Bestand dauerhaft und steht nicht erneut zur Verfügung."
 ],
 "crewAuthority": [
  "Vloga LEADER v posadki sama ne daje poveljniških pooblastil. Vodja enote mora sprejeti izrecno ponudbo v poveljniški strukturi.",
  "Die Besatzungsrolle LEADER erteilt keine Führungsbefugnis. Die Einheitsführung muss ein ausdrückliches Angebot in der Führungsstruktur annehmen."
 ],
 "pending": [
  "Izid še ni potrjen. Ponovite isti zahtevek.",
  "Ergebnis noch nicht bestätigt. Dieselbe Anfrage wiederholen."
 ],
 "stale": [
  "Podatki so se spremenili. Vaš vnos je ohranjen; osvežite, primerjajte in izrecno ponovno uredite z aktualno različico.",
  "Daten wurden geändert. Ihre Eingabe bleibt erhalten; aktualisieren, vergleichen und ausdrücklich mit aktueller Version erneut bearbeiten."
 ],
 "reedit": [
  "Pregledano — uporabi aktualno različico",
  "Geprüft — aktuelle Version verwenden"
 ],
 "current": [
  "Trenutni podatki",
  "Aktuelle Daten"
 ],
 "local": [
  "Vaš vnos",
  "Ihre Eingabe"
 ],
 "readOnly": [
  "Zalogo ureja le MANAGER/ADMIN te organizacije.",
  "Nur MANAGER/ADMIN dieser Organisation verwaltet den Bestand."
 ],
 "bounded": [
  "Prikazane so vse aktivne epizode in stran zaključene zgodovine. Iskanje kandidatov je omejeno; po potrebi zožite iskanje.",
  "Alle aktiven Episoden und eine Seite abgeschlossener Historie werden angezeigt. Kandidatensuche ist begrenzt; bei Bedarf Suche eingrenzen."
 ],
 "deploy_unit": [
  "Zabeleži enoto na kraju",
  "Anwesende Einheit erfassen"
 ],
 "update_unit_status": [
  "Spremeni stanje enote",
  "Einheitsstatus ändern"
 ],
 "assign_unit_sector": [
  "Dodeli sektor",
  "Sektor zuweisen"
 ],
 "add_crew_member": [
  "Dodaj člana posadke",
  "Besatzungsmitglied hinzufügen"
 ],
 "remove_crew_member": [
  "Zaključi članstvo posadke",
  "Besatzungszuordnung beenden"
 ],
 "allocate_resource": [
  "Rezerviraj sredstvo",
  "Ressource reservieren"
 ],
 "transition_resource_allocation": [
  "Spremeni dodelitev sredstva",
  "Ressourcenzuweisung ändern"
 ],
 "UNIT_LEADER": [
  "Vodja enote",
  "Einheitsführung"
 ],
 "VEHICLE_CREW": [
  "Posadka vozila",
  "Fahrzeugbesatzung"
 ],
 "RESCUE_TEAM": [
  "Reševalna enota",
  "Rettungseinheit"
 ],
 "DRONE_TEAM": [
  "Enota dronov",
  "Drohneneinheit"
 ],
 "MEDICAL_TEAM": [
  "Medicinska enota",
  "Medizinische Einheit"
 ],
 "OTHER": [
  "Drugo",
  "Sonstige"
 ],
 "EACH": [
  "Kos",
  "Stück"
 ],
 "AVAILABLE": [
  "Razpoložljivo",
  "Verfügbar"
 ],
 "UNAVAILABLE": [
  "Nerazpoložljivo",
  "Nicht verfügbar"
 ],
 "REQUESTED": [
  "Zahtevano",
  "Angefordert"
 ],
 "DISPATCHED": [
  "Odposlano",
  "Entsendet"
 ],
 "EN_ROUTE": [
  "Na poti",
  "Unterwegs"
 ],
 "ON_SCENE": [
  "Na kraju",
  "Vor Ort"
 ],
 "ASSIGNED": [
  "Dodeljeno nalogi",
  "Aufgabe zugewiesen"
 ],
 "RETURNING": [
  "Vračanje",
  "Rückkehr"
 ],
 "RELEASED": [
  "Zaključeno",
  "Freigegeben"
 ],
 "LEADER": [
  "Vodja posadke (brez pooblastila)",
  "Besatzungsleitung (ohne Befugnis)"
 ],
 "DRIVER": [
  "Voznik",
  "Fahrer"
 ],
 "RESPONDER": [
  "Operativec",
  "Einsatzkraft"
 ],
 "SPECIALIST": [
  "Specialist",
  "Spezialist"
 ],
 "RESERVED": [
  "Rezervirano",
  "Reserviert"
 ],
 "DEPLOYED": [
  "V uporabi",
  "Im Einsatz"
 ],
 "RETURNED": [
  "Vrnjeno",
  "Zurückgegeben"
 ],
 "CONSUMED": [
  "Porabljeno",
  "Verbraucht"
 ],
 "CANCELLED": [
  "Preklicano",
  "Storniert"
 ],
 "NOT_AUTHORIZED": [
  "Dostop ni dovoljen. Preverite račun in organizacijo.",
  "Kein Zugriff. Konto und Organisation prüfen."
 ],
 "EXPIRED": [
  "Seja je potekla. Prijavite se znova.",
  "Sitzung abgelaufen. Erneut anmelden."
 ],
 "SERVER": [
  "Storitev ni dosegljiva. Izid spremembe še ni potrjen.",
  "Dienst nicht erreichbar. Änderung noch nicht bestätigt."
 ],
 "VALIDATION_FAILED": [
  "Preverite obvezna polja, količine in izbrane vrednosti.",
  "Pflichtfelder, Mengen und ausgewählte Werte prüfen."
 ],
 "OPERATION_REUSED": [
  "Identifikator zahtevka je že uporabljen za drugo spremembo.",
  "Anfragekennung wurde bereits für eine andere Änderung verwendet."
 ],
 "DUPLICATE_INVENTORY": [
  "Aktivni klicni znak ali UUID že obstaja.",
  "Aktiver Funkrufname oder UUID bereits vorhanden."
 ],
 "INVALID_VEHICLE": [
  "Vozilo ni aktivno, razpoložljivo ali v pravi organizaciji.",
  "Fahrzeug nicht aktiv, verfügbar oder in der richtigen Organisation."
 ],
 "INVALID_UNIT": [
  "Enota ni več primerna za to dejanje.",
  "Einheit für diese Aktion nicht mehr geeignet."
 ],
 "INVALID_RESOURCE": [
  "Sredstvo ni dostopno ali veljavno.",
  "Ressource nicht zugänglich oder ungültig."
 ],
 "INVALID_CREW_MEMBER": [
  "Oseba ni upravičena ali je že v aktivni posadki.",
  "Person nicht berechtigt oder bereits einer aktiven Besatzung zugeordnet."
 ],
 "INVALID_UNIT_STATUS": [
  "Prehod stanja enote ni dovoljen.",
  "Übergang des Einheitsstatus nicht zulässig."
 ],
 "INVALID_RESOURCE_STATUS": [
  "Prehod stanja sredstva ni dovoljen.",
  "Übergang des Ressourcenstatus nicht zulässig."
 ],
 "UNIT_ALREADY_DEPLOYED": [
  "Enota je že uporabljena. Najprej zaključite njeno uporabo.",
  "Einheit bereits eingesetzt. Einsatz zuerst beenden."
 ],
 "UNIT_HAS_ACTIVE_COMMAND": [
  "Najprej izrecno zaključite vlogo vodje enote.",
  "Rolle der Einheitsführung zuerst ausdrücklich beenden."
 ],
 "UNIT_HAS_ACTIVE_CREW": [
  "Potrdite zaključek posadke pred sprostitvijo enote.",
  "Ende der Besatzungszuordnungen vor Freigabe bestätigen."
 ],
 "VEHICLE_DEPLOYED": [
  "Vozilo je v aktivni uporabi.",
  "Fahrzeug ist aktiv eingesetzt."
 ],
 "RESOURCE_IN_USE": [
  "Najprej zaključite aktivne dodelitve sredstva.",
  "Aktive Ressourcenzuweisungen zuerst beenden."
 ],
 "INSUFFICIENT_RESOURCE_QUANTITY": [
  "Ni dovolj proste zaloge za to spremembo.",
  "Nicht genügend freier Bestand für diese Änderung."
 ],
 "RESOURCE_LIMIT_REACHED": [
  "Dosežena je omejitev aktivnih enot, posadke ali sredstev.",
  "Grenze aktiver Einheiten, Besatzung oder Ressourcen erreicht."
 ],
 "PARTICIPANT_HAS_ACTIVE_RESOURCES": [
  "Organizacija ima še aktivne enote, posadke ali sredstva.",
  "Organisation hat noch aktive Einheiten, Besatzungen oder Ressourcen."
 ],
 "INCIDENT_HAS_ACTIVE_RESOURCES": [
  "Pred zaključkom končajte enote, posadke, vodenje enot in dodelitve sredstev.",
  "Vor Einsatzabschluss Einheiten, Besatzungen, Einheitsführungsrollen und Ressourcenzuweisungen beenden."
 ],
 "SECTOR_HAS_ACTIVE_UNITS": [
  "Sektor ima še aktivne enote. Najprej jih premestite ali sprostite.",
  "Sektor hat noch aktive Einheiten. Zuerst verschieben oder freigeben."
 ],
 "UNIT_ASSIGNED": [
  "Enota zabeležena na kraju",
  "Einheit vor Ort erfasst"
 ],
 "UNIT_STATUS_CHANGED": [
  "Stanje enote spremenjeno",
  "Einheitsstatus geändert"
 ],
 "UNIT_SECTOR_CHANGED": [
  "Sektor enote spremenjen",
  "Sektor der Einheit geändert"
 ],
 "UNIT_RELEASED": [
  "Enota sproščena",
  "Einheit freigegeben"
 ],
 "CREW_JOINED": [
  "Član posadke dodan",
  "Besatzungsmitglied hinzugefügt"
 ],
 "CREW_LEFT": [
  "Članstvo posadke zaključeno",
  "Besatzungszuordnung beendet"
 ],
 "RESOURCE_ALLOCATED": [
  "Sredstvo rezervirano",
  "Ressource reserviert"
 ],
 "RESOURCE_DEPLOYED": [
  "Sredstvo v uporabi",
  "Ressource eingesetzt"
 ],
 "RESOURCE_RETURNED": [
  "Sredstvo vrnjeno",
  "Ressource zurückgegeben"
 ],
 "RESOURCE_CONSUMED": [
  "Sredstvo porabljeno",
  "Ressource verbraucht"
 ],
 "RESOURCE_CANCELLED": [
  "Rezervacija preklicana",
  "Reservierung storniert"
 ],
 "STALE_VERSION": [
  "Podatki so se spremenili. Vaš vnos je ohranjen; osvežite, primerjajte in izrecno ponovno uredite z aktualno različico.",
  "Daten wurden geändert. Ihre Eingabe bleibt erhalten; aktualisieren, vergleichen und ausdrücklich mit aktueller Version erneut bearbeiten."
 ]
};
export const operationalText=(locale:Locale)=>(key:string)=>labels[key]?.[locale==='de'?1:0]??key;
