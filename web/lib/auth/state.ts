export type AccountState = 'UNAUTHENTICATED' | 'ACTIVE' | 'PENDING_APPROVAL' | 'SUSPENDED' | 'REJECTED' | 'ERROR';
export function accountState(value: unknown): AccountState {
  return value === 'ACTIVE' || value === 'PENDING_APPROVAL' || value === 'SUSPENDED' || value === 'REJECTED' ? value : 'ERROR';
}
export function canEnterAdmin(state: AccountState, memberships: { user_id: string; organization_id: string; role: string }[], userId: string): boolean {
  return state === 'ACTIVE' && memberships.some(m => m.user_id === userId && m.role === 'ADMIN' && !!m.organization_id);
}
export function errorKey(error: { code?: string; status?: number } | null | undefined) {
  if (error?.code === 'invalid_credentials') return 'invalidCredentials';
  if (error?.code === 'email_not_confirmed') return 'confirmEmail';
  if (error?.code === 'weak_password') return 'weakPassword';
  if (error?.code === 'user_already_exists' || error?.code === 'email_exists') return 'signupNotice';
  if (error?.status === 429) return 'rateLimited';
  return 'authError';
}
