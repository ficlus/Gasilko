import type {Locale} from '../i18n';
const sl:Record<string,string>={
 HAZARD_HISTORY_LIMIT:'Dosežena je omejitev zgodovine modela. Ustvari novo učno sejo.',HAZARD_PROCESSING_FAILED:'Obdelava modela je ustavljena zaradi napake. Inštruktor lahko izrecno ponovi obdelavo.',
 geometrySize:'Prikazne točke geometrije',
 title:'SIM · Požar in nevarnosti',disclaimer:'Učni model; ni napoved resničnega požara ali izmerjena koncentracija dima.',
 STRUCTURE_FIRE:'Požar objekta',WILDFIRE:'Vegetacijski požar',add:'Dodaj model',remove:'Odstrani',name:'Ime',type:'Model',enabled:'Model omogočen',
 visibility:'Razkritje',START:'Vidno od začetka',HIDDEN:'Skrito do izrecnega razkritja',center:'Središče območja',radius_m:'Polmer območja (m)',cell_m:'Celica (m)',
 wind_direction:'Smer širjenja vetra (° od severa)',wind_speed:'Hitrost vetra (m/s)',fuel:'Gorivo (0–1)',moisture:'Vlaga (0–1)',spread:'Učni faktor širjenja (0–2)',decline_seconds:'Začetek upadanja (sim. s; 0 = brez)',
 origins:'Žarišča',addOrigin:'Dodaj žarišče',initial:'Vžgano ob začetku',intensity:'Intenzivnost',place:'Postavi na karto',preview:'Predogled začetne konfiguracije',blocked:'Negorljive celice',blockHelp:'Klik preklopi negorljivo celico; žarišča ne postavljaj v blokirano celico.',
 zones:'Ročne nevarnosti',addZone:'Dodaj območje',HEAT_ZONE:'Toplotna nevarnost',SMOKE_ZONE:'Nevarnost dima',COLLAPSE_RISK:'Nevarnost porušitve',HAZARDOUS_MATERIAL:'Nevarna snov',ACCESS_HAZARD:'Nevaren dostop',
 effects:'Učinki dogodkov',addEffect:'Poveži dogodek',event:'Dogodek B',effect:'Učinek',WIND:'Spremeni veter',SPREAD:'Spremeni širjenje',BOOST:'Povečaj intenzivnost',IGNITE:'Vžgi žarišče',ENABLE:'Omogoči/ustavi rast',REVEAL:'Razkrij model',STOP:'Pogasi aktivna žarišča',RETRY:'Ponovi obdelavo',
 fire:'Prikaži požar',smoke:'Prikaži dim',hazards:'Prikaži nevarna območja',instructor:'Inštruktorski pogled in kontrole',loading:'Nalaganje modelov …',error:'Modelov ni mogoče prebrati. Osveži in preveri dostop ter namestitev migracije.',
 refresh:'Osveži',empty:'Ni razkritih modelov.',step:'Zaključen korak',lag:'Zaostanek (koraki)',burning:'Goreče celice / žarišča',freshness:'Zadnja obdelava',pending:'Čakajoči učinki',processing:'Čas obdelave (ms)',seconds:'Simulacijski čas (s)',confirm:'Potrdi učinek',retry:'Ponovi isti zahtevek',selected:'Podrobnosti modela',queueHelp:'Učinek velja po potrditvi strežnika na naslednji meji koraka. Med premorom počaka na nadaljevanje.',
 limits:'Največ 4 modeli, 1 vegetacijski; polmer do 250 m, 8 žarišč in 8 ročnih nevarnosti na model. Pri vegetaciji postavi žarišča vsaj eno celico znotraj meje.',
 simSmoke:'SIM — modeliran dim',RUNNING:'Simulacija teče',PAUSED:'Simulacija je ustavljena',DRAFT:'Priprava',FINISHED:'Zaključeno',budget:'Dosežena meja 8 simulacijskih ur. Model ne napreduje več.',
 elapsed:'Čas modela (s)',hidden:'Skrito',revealed:'Razkrito',apply:'Preglej in potrdi',phase:'Faza',INITIAL:'Začetna',DEVELOPING:'Razvijajoča',INTENSE:'Intenzivna',DECLINING:'Upadajoča',EXTINGUISHED:'Pogašena',BURNED:'Pogorelo',cancel:'Prekliči'
};
const de:Record<string,string>={
 HAZARD_HISTORY_LIMIT:'Das Modell-Historienlimit ist erreicht. Eine neue Übungssitzung anlegen.',HAZARD_PROCESSING_FAILED:'Die Modellverarbeitung wurde wegen eines Fehlers angehalten. Der Ausbilder kann sie ausdrücklich erneut versuchen.',
 geometrySize:'Geometrie-Anzeigepunkte',
 title:'SIM · Feuer und Gefahren',disclaimer:'Übungsmodell; keine reale Brandvorhersage oder gemessene Rauchkonzentration.',
 STRUCTURE_FIRE:'Gebäudebrand',WILDFIRE:'Vegetationsbrand',add:'Modell hinzufügen',remove:'Entfernen',name:'Name',type:'Modell',enabled:'Modell aktiviert',
 visibility:'Offenlegung',START:'Von Beginn sichtbar',HIDDEN:'Bis zur Freigabe verborgen',center:'Gebietsmittelpunkt',radius_m:'Gebietsradius (m)',cell_m:'Zelle (m)',
 wind_direction:'Wind-Ausbreitungsrichtung (° ab Norden)',wind_speed:'Windgeschwindigkeit (m/s)',fuel:'Brennstoff (0–1)',moisture:'Feuchtigkeit (0–1)',spread:'Übungs-Ausbreitungsfaktor (0–2)',decline_seconds:'Abklingen ab (Sim.-s; 0 = keines)',
 origins:'Brandherde',addOrigin:'Brandherd hinzufügen',initial:'Zu Beginn entzündet',intensity:'Intensität',place:'Auf Karte setzen',preview:'Vorschau der Anfangskonfiguration',blocked:'Nicht brennbare Zellen',blockHelp:'Klick schaltet eine nicht brennbare Zelle um; dort keinen Brandherd platzieren.',
 zones:'Manuelle Gefahren',addZone:'Gefahrenbereich hinzufügen',HEAT_ZONE:'Hitzegefahr',SMOKE_ZONE:'Rauchgefahr',COLLAPSE_RISK:'Einsturzgefahr',HAZARDOUS_MATERIAL:'Gefahrstoff',ACCESS_HAZARD:'Gefährlicher Zugang',
 effects:'Ereigniswirkungen',addEffect:'Ereignis verknüpfen',event:'B-Ereignis',effect:'Wirkung',WIND:'Wind ändern',SPREAD:'Ausbreitung ändern',BOOST:'Intensität erhöhen',IGNITE:'Brandherd entzünden',ENABLE:'Wachstum aktivieren/stoppen',REVEAL:'Modell offenlegen',STOP:'Aktive Brandherde löschen',RETRY:'Verarbeitung erneut versuchen',
 fire:'Feuer anzeigen',smoke:'Rauch anzeigen',hazards:'Gefahrenbereiche anzeigen',instructor:'Ausbilderansicht und Steuerung',loading:'Modelle werden geladen …',error:'Modelle nicht lesbar. Aktualisieren und Zugriff sowie Migration prüfen.',
 refresh:'Aktualisieren',empty:'Keine offengelegten Modelle.',step:'Abgeschlossener Schritt',lag:'Rückstand (Schritte)',burning:'Brennende Zellen / Herde',freshness:'Letzte Verarbeitung',pending:'Ausstehende Wirkungen',processing:'Verarbeitungszeit (ms)',seconds:'Simulationszeit (s)',confirm:'Wirkung bestätigen',retry:'Gleiche Anfrage wiederholen',selected:'Modelldetails',queueHelp:'Die Wirkung gilt nach Serverbestätigung an der nächsten Schrittgrenze. Während einer Pause wartet sie auf die Fortsetzung.',
 limits:'Maximal 4 Modelle, 1 Vegetationsmodell; Radius bis 250 m, 8 Herde und 8 manuelle Gefahren je Modell. Vegetationsherde mindestens eine Zelle innerhalb der Grenze platzieren.',
 simSmoke:'SIM — modellierter Rauch',RUNNING:'Simulation läuft',PAUSED:'Simulation pausiert',DRAFT:'Vorbereitung',FINISHED:'Beendet',budget:'Grenze von 8 simulierten Stunden erreicht. Keine weitere Modellentwicklung.',
 elapsed:'Modellzeit (s)',hidden:'Verborgen',revealed:'Offengelegt',apply:'Prüfen und bestätigen',phase:'Phase',INITIAL:'Anfang',DEVELOPING:'Entwicklung',INTENSE:'Intensiv',DECLINING:'Abklingend',EXTINGUISHED:'Gelöscht',BURNED:'Verbrannt',cancel:'Abbrechen'
};
export const hazardText=(locale:Locale)=>(key:string)=>(locale==='de'?de:sl)[key]??key;
