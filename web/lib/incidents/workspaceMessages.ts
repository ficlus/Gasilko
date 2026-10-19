import type {Locale} from '../i18n';
const messages:Record<string,readonly [string,string]>={
 hideLeft:['◀ Skrij levi panel','◀ Linken Bereich ausblenden'],showLeft:['▶ Prikaži levi panel','▶ Linken Bereich anzeigen'],
 hideRight:['Skrij desni panel ▶','Rechten Bereich ausblenden ▶'],showRight:['Prikaži desni panel ◀','Rechten Bereich anzeigen ◀'],
 leftShort:['Enote','Einheiten'],rightShort:['Podrobnosti','Details'],toolsShort:['Kontrole','Steuerung'],historyShort:['Zgodovina','Verlauf'],
 view:['Pogled intervencije','Einsatzansicht'],
 classic:['Klasični pogled','Klassische Ansicht'],
 command:['Poveljniška karta','Führungskarte'],
 roster:['Enote in operativni pregled','Einheiten und Einsatzübersicht'],
 context:['Izbor in podrobnosti','Auswahl und Details'],
 tools:['Izbor, navigacija in SIM kontrole','Auswahl, Navigation und SIM-Steuerung'],
 history:['Zgodovina in dodatne informacije','Verlauf und weitere Informationen'],
 close:['Zapri panel','Bereich schließen'],
 expand:['Razširi karto','Karte erweitern'],
 exit:['Zapri razširjeni pogled','Erweiterte Ansicht schließen'],
 selected:['Izbrane enote','Ausgewählte Einheiten'],
 empty:['Nič ni izbrano','Keine Auswahl'],
 map:['Operativna karta','Einsatzkarte'],
 controls:['Sloji in podatki karte','Kartenebenen und Informationen'],
 classicHelp:['Vsi obstoječi obrazci so dostopni tudi v klasičnem pogledu.','Alle bestehenden Formulare sind auch in der klassischen Ansicht verfügbar.'],
 focusHelp:['Esc zapre razširjeni pogled.','Esc schließt die erweiterte Ansicht.']
};
export const workspaceText=(locale:Locale)=>(key:string)=>messages[key]?.[locale==='de'?1:0]??key;
