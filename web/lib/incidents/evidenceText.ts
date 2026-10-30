import type {Locale} from '../i18n';
const sl={
 title:'Priloge in dokazi',add:'Dodaj prilogo',file:'Izberi datoteko',upload:'Potrdi in pošlji',retry:'Ponovi z istim ID',download:'Prenesi',preview:'Ogled slike',
 limits:'JPEG/WebP do 10 MiB; PDF do 20 MiB. Priloga ni potrditev ukaza.',scope:'Občinstvo izbranega cilja',confirm:'Potrjujem ciljni incident, nalogo ali sporočilo in njegovo občinstvo.',
 ORGANIZATION:'Organizacija',UNIT:'Enota',INCIDENT:'Incident',TASK:'Naloga',MESSAGE:'Sporočilo',pending:'Čaka / preverjanje',ready:'Potrjeno',rejected:'Potrebna pozornost',empty:'Ni prilog',older:'Starejše',
 denied:'Priloge tega cilja niso na voljo z vašim trenutnim dostopom.',error:'Prenos ni uspel. Datoteka in identiteta ostajata za ponovitev.',
 invalid:'Nepodprta, prevelika ali neveljavna datoteka.',close:'Zapri',cancel:'Prekini prenos',draft:'Datoteka še ni poslana.',
 frozen:'Ponovitev uporablja isto datoteko in UUID. Ob zaprtju zavihka lokalna neposlana datoteka ni trajno shranjena.',
 stale:'Povezava ni na voljo. Za zasebne priloge je potrebna spletna preveritev.',newFile:'Nova priloga'
} as const;
const de:Record<keyof typeof sl,string>={
 title:'Anhänge und Nachweise',add:'Anhang hinzufügen',file:'Datei auswählen',upload:'Bestätigen und senden',retry:'Mit gleicher ID wiederholen',download:'Herunterladen',preview:'Bild ansehen',
 limits:'JPEG/WebP bis 10 MiB; PDF bis 20 MiB. Ein Anhang bestätigt keinen Auftrag.',scope:'Empfängerkreis des gewählten Ziels',confirm:'Ich bestätige Einsatz, Auftrag oder Nachricht und den zugehörigen Empfängerkreis.',
 ORGANIZATION:'Organisation',UNIT:'Einheit',INCIDENT:'Einsatz',TASK:'Auftrag',MESSAGE:'Nachricht',pending:'Ausstehend / Prüfung',ready:'Bestätigt',rejected:'Klärung erforderlich',empty:'Keine Anhänge',older:'Ältere',
 denied:'Anhänge dieses Ziels sind mit Ihrem aktuellen Zugriff nicht verfügbar.',error:'Übertragung fehlgeschlagen. Datei und Identität bleiben für den nächsten Versuch erhalten.',
 invalid:'Nicht unterstützte, zu große oder ungültige Datei.',close:'Schließen',cancel:'Übertragung abbrechen',draft:'Datei noch nicht gesendet.',
 frozen:'Wiederholungen verwenden dieselbe Datei und UUID. Ungesendete Dateien werden beim Schließen des Tabs nicht dauerhaft gespeichert.',
 stale:'Keine Verbindung. Private Anhänge erfordern eine Onlineprüfung.',newFile:'Neuer Anhang'
};
export const evidenceText=(locale:Locale)=>(key:keyof typeof sl)=>(locale==='de'?de:sl)[key];
