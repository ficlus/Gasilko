import type {Locale} from '../../lib/i18n';
import {auditEntity} from '../../lib/operational/auditEntity';
import {EntityLink} from './EntityLink';
export function AuditEntityLink({locale,row}:{locale:Locale;row:Record<string,unknown>}){
 const entity=auditEntity(row);return entity?<EntityLink locale={locale} entity={entity}/>:null;
}
