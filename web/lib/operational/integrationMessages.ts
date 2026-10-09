import type {Locale} from '../i18n';
const text={
 context:['Operativni kontekst','Operativer Kontext'],map:['Pokaži na zemljevidu','Auf Karte zeigen'],
 plans:['Načrti','Pläne'],incidents:['Intervencije','Einsätze'],link:['Poveži z intervencijo','Mit Einsatz verknüpfen'],
 add:['Dodaj v načrt','Zu Plan hinzufügen'],addHere:['Dodaj v ta načrt','Zu diesem Plan hinzufügen'],
 existing:['Že v načrtu','Bereits im Plan'],choose:['Izberi','Auswählen'],open:['Odpri','Öffnen'],
 empty:['Ni dostopnih zapisov','Keine zugänglichen Einträge'],error:['Podatki niso na voljo. Osvežite in poskusite znova.','Daten nicht verfügbar. Aktualisieren und erneut versuchen.'],
 more:['Prikazan je omejen izbor.','Begrenzte Auswahl wird angezeigt.'],loading:['Nalaganje …','Wird geladen …'],
 background:['Kontekstni hidranti: manjši označevalniki; hidranti načrta: poudarjeni.','Kontexthydranten: kleine Marker; Planhydranten: hervorgehoben.'],
 template:['Uporabi ekipo kot predlogo posadke','Team als Besatzungsvorlage verwenden'],
 snapshot:['Predogled trenutne ekipe. Vsakega člana potrdite posebej. Poznejše spremembe ekipe ne spremenijo posadke.','Vorschau des aktuellen Teams. Jede Person einzeln bestätigen. Spätere Teamänderungen ändern die Besatzung nicht.'],
 join:['Potrdi člana','Person bestätigen'],joined:['V posadki','In der Besatzung'],ineligible:['Trenutno ni na voljo za pridružitev','Derzeit nicht für Beitritt verfügbar'],
 memberCheck:['Upravičenost se ponovno preveri ob potrditvi. Vloga je gasilec; poveljniška pooblastila se ne dodelijo.','Berechtigung wird bei Bestätigung erneut geprüft. Rolle: Einsatzkraft; keine Führungsbefugnis wird vergeben.'],
 memberPending:['Izbrani član – rezultat potrditve je prikazan spodaj oziroma v potrditvenem oknu.','Ausgewählte Person – Bestätigungsergebnis unten bzw. im Bestätigungsdialog.'],
 preview:['Pregled in potrditev v izvirnem obrazcu','Prüfen und im ursprünglichen Formular bestätigen'],
 noLocation:['Lokacija ni na voljo','Position nicht verfügbar'],readOnly:['Samo branje','Nur Lesen'],
 manage:['Odpri upravljanje načrta','Planverwaltung öffnen'],next:['Naprej','Weiter'],previous:['Nazaj','Zurück'],
 refresh:['Osveži','Aktualisieren']
} as const;
export const integrationText=(locale:Locale)=>(key:keyof typeof text)=>text[key][locale==='de'?1:0];
