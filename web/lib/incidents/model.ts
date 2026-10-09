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
export type Timeline = {events:{id:string;sequence:string|number;event_code:string;recorded_at:string;actor_name:string|null;actor_organization_name:string;subject_name:string|null;data:{reason?:string|null;user_id?:string;organization_id?:string;unit_assignment_id?:string;resource_allocation_id?:string}}[];high_watermark:string|number};
export type Candidate = {id:string;name:string};
export type Core = {title:string;summary:string;incident_type_id:string;severity:string;priority:string;latitude:string;longitude:string;address:string;unknown_location_reason:string};
export type Receipt = {incident_id:string;operation_id:string;version:string;revision:string;timeline_sequence:string};
export const mutationNames = {
 issue_task:'incident_issue_task',transition_task_assignment:'incident_transition_task_assignment',cancel_task:'incident_cancel_task',
 deploy_unit:'incident_deploy_unit',
 update_unit_status:'incident_update_unit_status',
 assign_unit_sector:'incident_assign_unit_sector',
 add_crew_member:'incident_add_crew_member',
 remove_crew_member:'incident_remove_crew_member',
 allocate_resource:'incident_allocate_resource',
 transition_resource_allocation:'incident_transition_resource_allocation',

 create:'incident_create_draft',edit:'incident_update_summary',nominate:'incident_nominate_initial_command',consent:'incident_accept_initial_command',
 invite:'incident_request_participation',accept:'incident_accept_participation',decline:'incident_decline_participation',
 consent_release:'incident_consent_release',release:'incident_release_participation',activate:'incident_activate',stabilize:'incident_stabilize',
 reactivate:'incident_reactivate',close:'incident_close',cancel:'incident_cancel',
 offer_role:'incident_offer_role',end_role:'incident_end_role',transfer_command:'incident_request_command_transfer',
 recover_command:'incident_request_command_recovery',accept_command:'incident_accept_command_request',
 decline_command:'incident_decline_command_request',cancel_command:'incident_cancel_command_request',consent_lead:'incident_consent_lead_transfer',
 sector_create:'incident_create_sector',sector_update:'incident_update_sector',sector_deactivate:'incident_deactivate_sector',
 object_put:'incident_put_map_object',object_deactivate:'incident_deactivate_map_object',hydrant_link:'incident_link_hydrant',hydrant_unlink:'incident_unlink_hydrant',
} as const;
export type Mutation = keyof typeof mutationNames;
export type CommandRole = {unit_assignment_id:string|null;unit_name:string|null;sector_id:string|null;sector_name:string|null} & {id:string;user_id:string;name:string|null;organization_id:string;organization_name:string;role:string;parent_id:string|null;valid:boolean;can_end:boolean;created_at:string};
export type CommandRequest = {unit_assignment_id:string|null;unit_name:string|null;sector_id:string|null;sector_name:string|null} & InboxItem & {name:string|null;organization_name:string;outgoing_name:string|null;lead_name:string;kind:string;role:string;status:string;reason:string|null;created_at:string;transfer_lead:boolean;lead_consented:boolean;can_accept:boolean;can_cancel:boolean;can_lead_consent:boolean};
export type CommandHistory = {unit_assignment_id:string|null;unit_name:string|null;sector_id:string|null;sector_name:string|null} & {id:string;name:string|null;organization_name:string;role:string;status:string;parent_id:string|null;valid_from:string;ended_at:string|null;reason:string|null;assigned_by:string|null;created_at:string};
export type CommandView = {version:string;valid_commander:boolean;operational:boolean;can_assign:boolean;can_transfer:boolean;can_recover:boolean;units:{id:string;name:string;organization_id:string;parent_id:string}[];sectors:{id:string;code:string;name:string}[];roles:CommandRole[];history:CommandHistory[];requests:CommandRequest[]};
