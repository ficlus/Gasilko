import type {Locale} from '../i18n';
const sl={
 off:'Deljenje lokacije vozila je izklopljeno',
 blocked:'Pred povezovanjem telefona morajo biti potrjeni pravila zasebnosti, varen dokaz vezave naprave in zanesljiv izbris poteklih koordinat.',
 noCapture:'Ta možnost ne zajema ali pošilja GPS. Dovoljenje za lokacijo telefona ni soglasje za deljenje.',
 check:'Preveri razpoložljivost deljenja',
 checking:'Preverjanje strežnika …',
 serverOff:'Strežnik potrjuje: deljenje je izklopljeno. To ni dovoljenje za zajem ali ogled položaja.',
 unverified:'Razpoložljivosti ni mogoče potrditi. Deljenje ostaja izklopljeno; naloge in zemljevid lahko uporabljate naprej.'
};
const de:typeof sl={
 off:'Fahrzeugstandortfreigabe ist ausgeschaltet',
 blocked:'Vor der Telefonkopplung müssen Datenschutzregeln, ein sicherer Gerätenachweis und die zuverlässige Löschung abgelaufener Koordinaten genehmigt sein.',
 noCapture:'Diese Funktion erfasst oder sendet kein GPS. Die Standortberechtigung des Telefons ist keine Zustimmung zur Freigabe.',
 check:'Verfügbarkeit der Standortfreigabe prüfen',
 checking:'Server wird geprüft …',
 serverOff:'Der Server bestätigt: Freigabe ausgeschaltet. Dies erlaubt weder Erfassung noch Einsicht in Positionen.',
 unverified:'Verfügbarkeit nicht bestätigt. Die Freigabe bleibt ausgeschaltet; Aufträge und Karte können weiter genutzt werden.'
};
export const vehicleLocationText=(locale:Locale)=>(key:keyof typeof sl)=>(locale==='de'?de:sl)[key];
