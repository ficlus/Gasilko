'use client';
import type {Locale} from '../../lib/i18n';
import {taskText} from '../../lib/operational/taskMessages';
import {operationalText} from '../../lib/operational/messages';
import {rtsText} from '../../lib/operational/rtsMessages';
import {recipientKey} from '../../lib/operational/rts';
import {useWorkspace} from './workspace';
import {useRts} from './rtsSession';

export function RtsSelectionToolbar({locale}:{locale:Locale}){
 const workspace=useWorkspace(),rts=useRts(),t=rtsText(locale),tt=taskText(locale),ot=operationalText(locale);
 if(!rts||!rts.enabled||rts.blocked)return null;
 const groupsLocked=rts.locked||rts.externalEditing||rts.copEditing||rts.open||rts.mode!=='NORMAL'||rts.groupBusy;
 const unsupported=(type:string)=>!!rts.action&&!rts.action.configuration.recipient_types.includes(type);
 const invalid=rts.recipients.filter(r=>unsupported(r.type)||r.eligibility==='UNAVAILABLE').length;
 const unknown=rts.recipients.filter(r=>!unsupported(r.type)&&r.eligibility==='UNKNOWN').length;
 return <section className="rts-toolbar" aria-label={t('rtsTitle')}>
  <div className="actions"><strong aria-live="polite">{t('selected')}: {rts.recipients.length}/100</strong>
   <button type="button" disabled={(rts.locked||rts.externalEditing)||rts.copEditing||!rts.recipients.length} onClick={rts.openPalette}>{t('chooseAction')}</button>
   <button type="button" disabled={(rts.locked||rts.externalEditing)||!rts.recipients.length} onClick={rts.clear}>{t('clear')}</button>
   <button type="button" aria-pressed={rts.mode==='SELECT_BOX'} disabled={(rts.locked||rts.externalEditing)||rts.copEditing} onClick={()=>rts.requestMode(rts.mode==='SELECT_BOX'?'NORMAL':'SELECT_BOX')}>{t('box')}</button>
   <button type="button" aria-pressed={rts.mode==='SELECT_LASSO'} disabled={(rts.locked||rts.externalEditing)||rts.copEditing} onClick={()=>rts.requestMode(rts.mode==='SELECT_LASSO'?'NORMAL':'SELECT_LASSO')}>{t('lasso')}</button>
   {rts.mode!=='NORMAL'&&<button type="button" onClick={rts.cancelMode}>{t('cancelMode')}</button>}
  </div>
  {workspace?.view==='command'&&<section className="rts-control-groups" aria-label={t('controlGroups')}>
   <strong>{t('controlGroups')}</strong><span>{t('selected')}: {rts.recipients.length}</span>
   <div className="rts-group-buttons">{Array.from({length:9},(_,offset)=>{const number=offset+1,count=rts.groups.get(number)?.length??0;return <span className="rts-group" key={number}><button type="button" title={t('groupRecall')+' '+number} disabled={groupsLocked||!count} onClick={()=>rts.recallGroup(number)}>{number} · {count||'—'}</button><button type="button" aria-label={t('groupSave')+' '+number} title={t('groupSave')+' '+number} disabled={groupsLocked||!rts.recipients.length} onClick={()=>rts.saveGroup(number)}>+</button>{count>0&&<button type="button" aria-label={t('groupClear')+' '+number} title={t('groupClear')+' '+number} disabled={groupsLocked} onClick={()=>rts.clearGroup(number)}>×</button>}</span>;})}</div>
   <small>{t('groupsTemporary')}</small><small>{t('groupShortcuts')}</small>
  </section>}
  <div className="actions"><label><input type="checkbox" checked={rts.multiTouch} disabled={(rts.locked||rts.externalEditing)} onChange={e=>rts.setMultiTouch(e.target.checked)}/>{t('multiTouch')}</label>
   <label><input type="checkbox" checked={rts.merge} disabled={(rts.locked||rts.externalEditing)} onChange={e=>rts.setMerge(e.target.checked)}/>{t('merge')}</label></div>
  <p>{t('eligibleCount')}: {rts.recipients.length-invalid-unknown} · {t('invalidCount')}: {invalid} · {t('unknownCount')}: {unknown}</p>
  {rts.message&&<p role="status">{t(rts.message)}</p>}
  {rts.copEditing&&<p>{t('drawingBusy')}</p>}
  <details><summary>{t('selected')} ({rts.recipients.length})</summary>
   <ul className="rts-selection-summary">{rts.recipients.map(r=><li key={recipientKey(r)} tabIndex={0} onKeyDown={e=>{
    if(e.target===e.currentTarget&&(e.key==='Delete'||e.key==='Backspace')){e.preventDefault();e.stopPropagation();rts.remove(recipientKey(r));}
   }}><strong>{r.name}</strong> · {tt(r.type)} · {r.organization_name}
    {r.sector_name&&<span>{t('sector')}: {r.sector_name}</span>}{r.status&&<span>{t('state')}: {ot(r.status)}</span>}
    <span>{t(unsupported(r.type)?'unsupported':r.eligibility==='ELIGIBLE'?'eligible':r.eligibility==='UNAVAILABLE'?'unavailable':'unknown')}</span>
    <button type="button" disabled={(rts.locked||rts.externalEditing)} onClick={()=>rts.remove(recipientKey(r))}>{t('remove')} · {r.name}</button>
   </li>)}</ul>
  </details>
  <small>{t('eligibilityNotice')}</small><details><summary>{t('shortcuts')}</summary><p>{t('listHints')}</p>{!rts.hasPositionLayers&&<p>{t('noPositions')}</p>}</details>
 </section>;
}
