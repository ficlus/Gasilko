'use client';
import type {Locale} from '../../lib/i18n';
import {realUnitPositionView,type RealUnitBinding} from '../../lib/incidents/realUnitPosition';
import {realUnitPositionText} from '../../lib/incidents/realUnitPositionText';

/** All current C3 unit views are unavailable; never create a fallback map feature. */
export function RealUnitPositionBadge({locale,binding,authorized}:{locale:Locale;binding:RealUnitBinding;authorized:boolean}) {
 const t=realUnitPositionText(locale),view=realUnitPositionView(binding,authorized);
 return <small style={{display:'block',color:'#4b5563',background:'#f3f4f6',padding:'4px 8px',border:'1px solid #6b7280',borderRadius:4}}>
  □ REAL · {t(view.availability==='LOCKED'?'locked':'unavailable')}
 </small>;
}
export function RealUnitLocationNotice({locale,locked=false}:{locale:Locale;locked?:boolean}) {
 const t=realUnitPositionText(locale);
 return <details className="admin-notice" style={{pointerEvents:'auto'}}><summary>□ {t('title')} · {t(locked?'locked':'unavailable')}</summary>
  {!locked&&<><p>{t('source')}</p><p>{t('noTime')} · {t('noAccuracy')}</p><p>{t('distinction')}</p><p>{t('sim')}</p>
   <h4>{t('legend')}</h4><ul>
    <li style={{color:'#166534'}}>{t('current')}</li>
    <li style={{color:'#92400e',borderLeft:'3px dashed #92400e',paddingLeft:6}}>{t('lastKnown')}</li>
    <li style={{color:'#4b5563'}}>{t('expired')}</li>
   </ul><p>{t('retention')}</p>
  </>}
 </details>;
}
