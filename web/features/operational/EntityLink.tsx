import type {ReactNode} from 'react';
import Link from 'next/link';
import type {Locale} from '../../lib/i18n';
import {entityHref,entityLabel,type EntityRef} from '../../lib/operational/entity';
export function EntityLink({locale,entity,children}:{locale:Locale;entity:EntityRef;children?:ReactNode}){
 const href=entityHref(locale,entity);return href?<Link href={href}>{children??entityLabel(locale,entity)}</Link>:null;
}
