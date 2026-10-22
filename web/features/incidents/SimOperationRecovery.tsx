'use client';
import type {Locale} from '../../lib/i18n';
import {templateText} from '../../lib/operational/templateMessages';
import {workflowText} from '../../lib/operational/workflowMessages';
import type {useTemplateMutation} from './useTemplateMutation';
export function SimOperationRecovery({locale,mutation}:{locale:Locale;mutation:ReturnType<typeof useTemplateMutation>}){
 const t=templateText(locale),w=workflowText(locale);
 if(!mutation.pending&&!mutation.error)return null;
 return <section className="admin-notice" aria-live="polite">
 <p>{w(mutation.state)}</p>{mutation.error&&<p role="alert">{t(mutation.error)}</p>}
 {mutation.correlation&&<small>{mutation.correlation}</small>}
 {mutation.pendingRequests.map(request=><div key={String(request.args.p_operation)}>
 <small>{String(request.args.p_action??'')} · {String(request.args.p_template_id??request.args.p_incident_id??'')} · {String(request.args.p_operation)}</small><div className="actions">
 {['simulation_template_command','simulation_template_initialize'].includes(request.name)&&<button type="button" disabled={mutation.busy} onClick={()=>mutation.reconcileRequest(request)}>{w('reconcile')}</button>}
 <button type="button" disabled={mutation.busy} onClick={()=>mutation.retryRequest(request)}>{t('retry')}</button></div></div>)}
 </section>;
}
