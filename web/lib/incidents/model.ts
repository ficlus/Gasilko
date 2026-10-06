export const incidentStates = ['DRAFT','ACTIVE','STABILIZED','CLOSED','CANCELLED'] as const;
export const incidentPriorities = ['LOW','NORMAL','HIGH','CRITICAL'] as const;
export const incidentSeverities = ['UNKNOWN','MINOR','MAJOR','CRITICAL'] as const;
export type IncidentType = {id:string;code:string;names:Record<string,string>};
export type Organization = {id:string;name:string;can_create:boolean};
export type InboxItem = {id:string;incident_id:string;title:string;reference_number:string;organization_id:string;version:string;expires_at?:string};
export type Entry = {organizations:Organization[];types:IncidentType[];invitations:InboxItem[];nominations:InboxItem[]};
export type IncidentRow = {id:string;reference_number:string;title:string;status:string;priority:string;severity:string;created_at:string;address:string|null;lead_name:string;type:IncidentType};
export type Participant = {id:string;organization_id:string;name:string;status:string;agency_role:string;accepted_at:string|null;ended_at:string|null;end_reason:string|null;can_consent_release:boolean;can_release:boolean};
export type Incident = IncidentRow & {summary:string;incident_type_id:string;latitude:number|null;longitude:number|null;timezone:string;unknown_location_reason:string|null;
 version:string;revision:string;timeline_sequence:string;lead_organization_id:string;created_organization_id:string;
 started_at:string|null;declared_at:string|null;stabilized_at:string|null;closed_at:string|null;cancelled_at:string|null;
 actions:Record<string,boolean>;participants:Participant[];
 nomination:{id:string;user_id:string;name:string|null;status:string;expires_at:string}|null;
 commander:{id:string;name:string|null;user_id:string;status:string;valid:boolean;ended_at:string|null}|null};
export type Timeline = {events:{id:string;sequence:string|number;event_code:string;recorded_at:string;actor_name:string|null;actor_organization_name:string;subject_name:string|null;data:{reason?:string|null;user_id?:string;organization_id?:string}}[];high_watermark:string|number};
export type Candidate = {id:string;name:string};
export type Core = {title:string;summary:string;incident_type_id:string;severity:string;priority:string;latitude:string;longitude:string;address:string;unknown_location_reason:string};
export type Receipt = {incident_id:string;operation_id:string;version:string;revision:string;timeline_sequence:string};
export const mutationNames = {
 create:'incident_create_draft',edit:'incident_update_summary',nominate:'incident_nominate_initial_command',consent:'incident_accept_initial_command',
 invite:'incident_request_participation',accept:'incident_accept_participation',decline:'incident_decline_participation',
 consent_release:'incident_consent_release',release:'incident_release_participation',activate:'incident_activate',stabilize:'incident_stabilize',
 reactivate:'incident_reactivate',close:'incident_close',cancel:'incident_cancel',
} as const;
export type Mutation = keyof typeof mutationNames;
