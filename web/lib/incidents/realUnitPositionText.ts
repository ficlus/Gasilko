import type {Locale} from '../i18n';
import {realUnitFreshnessPolicy} from './realUnitPosition';
const sl={
 title:'REAL položaji enot',unavailable:'POLOŽAJ NI NA VOLJO',locked:'Dostop do položaja ni na voljo',
 source:'Zanesljiv vir deljenih REAL položajev še ni na voljo. Zato enot ne postavljamo na zemljevid.',
 noTime:'Čas opazovanja: neznan',noAccuracy:'Natančnost: ni podatka',
 distinction:'Položaj ni status enote ali dokaz prihoda, pripravljenosti oziroma zaključka naloge. Pot, cilj in lokalna modra pika niso deljeni položaj enote.',
 sim:'SIM ostaja ločen, izrecno simuliran vir; nikoli ne pomeni REAL GPS.',
 legend:'Pravila svežine — veljajo šele za odobreno REAL opazovanje',
 current:'■ AKTUALNO — zeleno, manj kot {current} minuti, samo s trenutno potrditvijo vira',
 lastKnown:'▧ ZADNJI ZNANI — oranžno, od {current} do manj kot {expiry} minut; brez povezave nikoli aktualno',
 expired:'□ NI NA VOLJO — sivo, pri {expiry} minutah ali brez pravic, vira oziroma zaupanja vrednega časa; brez pina',
 retention:'Veljavno dovoljenje in dovoljena hramba lahko prikaz omejita še prej. Starosti ne računamo iz časa branja ali poti.',
 partial:'Seznam položajev ni popoln. Prikazujemo le že dovoljene enote v trenutnem omejenem pogledu.'
};
const de:typeof sl={
 title:'REALE Einheitenpositionen',unavailable:'POSITION NICHT VERFÜGBAR',locked:'Positionszugriff nicht verfügbar',
 source:'Eine verlässliche Quelle geteilter REALER Positionen ist noch nicht verfügbar. Daher werden keine Einheitenpositionen auf der Karte gesetzt.',
 noTime:'Beobachtungszeit: unbekannt',noAccuracy:'Genauigkeit: nicht angegeben',
 distinction:'Position bedeutet weder Einheitenstatus noch Ankunft, Einsatzbereitschaft oder Auftragsabschluss. Route, Ziel und lokaler blauer Punkt sind keine geteilte Einheitenposition.',
 sim:'SIM bleibt eine getrennte, ausdrücklich simulierte Quelle und bedeutet niemals REAL GPS.',
 legend:'Frischeregeln — erst für eine genehmigte REALE Beobachtung',
 current:'■ AKTUELL — grün, unter {current} Minuten, nur mit aktueller Quellenbestätigung',
 lastKnown:'▧ ZULETZT BEKANNT — orange, ab {current} bis unter {expiry} Minuten; offline niemals aktuell',
 expired:'□ NICHT VERFÜGBAR — grau, ab {expiry} Minuten oder ohne Rechte, Quelle bzw. vertrauenswürdige Zeit; kein Pin',
 retention:'Gültige Berechtigung und erlaubte Aufbewahrung können die Anzeige früher begrenzen. Alter wird nicht aus Lesezeit oder Route berechnet.',
 partial:'Die Positionsliste ist unvollständig. Nur bereits erlaubte Einheiten der aktuellen begrenzten Ansicht werden berücksichtigt.'
};
export const realUnitPositionText=(locale:Locale)=>(key:keyof typeof sl)=>(locale==='de'?de:sl)[key]
 .replace('{current}',String(realUnitFreshnessPolicy.currentUnderSeconds/60))
 .replace('{expiry}',String(realUnitFreshnessPolicy.expiresAtSeconds/60));
