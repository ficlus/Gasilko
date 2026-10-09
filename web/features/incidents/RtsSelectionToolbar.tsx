'use client';
import type {Locale} from '../../lib/i18n';
import {taskText} from '../../lib/operational/taskMessages';
import {operationalText} from '../../lib/operational/messages';
import {rtsText} from '../../lib/operational/rtsMessages';
import {recipientKey} from '../../lib/operational/rts';
import {useRts} from './rtsSession';

export function RtsSelectionToolbar({locale}:{locale:Locale}){
 const rts=useRts(),t=rtsText(locale),tt=taskText(locale),ot=operationalText(locale);
 if(!rts||!rts.enabled||rts.blocked)return null;
 const unsupported=(type:string)=>!!rts.action&&!rts.action.configuration.recipient_types.includes(type);
 const invalid=rts.recipients.filter(r=>unsupported(r.type)||r.eligibility==='UNAVAILABLE').length;
 const unknown=rts.recipients.filter(r=>!unsupported(r.type)&&r.eligibility==='UNKNOWN').length;
 return <section className="rts-toolbar" aria-label={t('rtsTitle')}>
  <div className="actions"><strong aria-live="polite">{t('selected')}: {rts.recipients.length}/100</strong>
   <button type="button" disabled={rts.locked||rts.copEditing||!rts.recipients.length} onClick={rts.openPalette}>{t('chooseAction')}</button>
   <button type="button" disabled={rts.locked||!rts.recipients.length} onClick={rts.clear}>{t('clear')}</button>
   <button type="button" aria-pressed={rts.mode==='SELECT_BOX'} disabled={rts.locked||rts.copEditing} onClick={()=>rts.requestMode(rts.mode==='SELECT_BOX'?'NORMAL':'SELECT_BOX')}>{t('box')}</button>
   <button type="button" aria-pressed={rts.mode==='SELECT_LASSO'} disabled={rts.locked||rts.copEditing} onClick={()=>rts.requestMode(rts.mode==='SELECT_LASSO'?'NORMAL':'SELECT_LASSO')}>{t('lasso')}</button>
   {rts.mode!=='NORMAL'&&<button type="button" onClick={rts.cancelMode}>{t('cancelMode')}</button>}
  </div>
  <div className="actions"><label><input type="checkbox" checked={rts.multiTouch} disabled={rts.locked} onChange={e=>rts.setMultiTouch(e.target.checked)}/>{t('multiTouch')}</label>
   <label><input type="checkbox" checked={rts.merge} disabled={rts.locked} onChange={e=>rts.setMerge(e.target.checked)}/>{t('merge')}</label></div>
  <p>{t('eligibleCount')}: {rts.recipients.length-invalid-unknown} · {t('invalidCount')}: {invalid} · {t('unknownCount')}: {unknown}</p>
  {rts.message&&<p role="status">{t(rts.message)}</p>}
  {rts.copEditing&&<p>{t('drawingBusy')}</p>}
  <details><summary>{t('selected')} ({rts.recipients.length})</summary>
   <ul className="rts-selection-summary">{rts.recipients.map(r=><li key={recipientKey(r)} tabIndex={0} onKeyDown={e=>{
    if(e.target===e.currentTarget&&(e.key==='Delete'||e.key==='Backspace')){e.preventDefault();e.stopPropagation();rts.remove(recipientKey(r));}
   }}><strong>{r.name}</strong> · {tt(r.type)} · {r.organization_name}
    {r.sector_name&&<span>{t('sector')}: {r.sector_name}</span>}{r.status&&<span>{t('state')}: {ot(r.status)}</span>}
    <span>{t(unsupported(r.type)?'unsupported':r.eligibility==='ELIGIBLE'?'eligible':r.eligibility==='UNAVAILABLE'?'unavailable':'unknown')}</span>
    <button type="button" disabled={rts.locked} onClick={()=>rts.remove(recipientKey(r))}>{t('remove')} · {r.name}</button>
   </li>)}</ul>
  </details>
  <small>{t('eligibilityNotice')}</small><details><summary>{t('shortcuts')}</summary><p>{t('listHints')}</p><p>{t('noPositions')}</p></details>
 </section>;
}
