import { ForbiddenException } from '@nestjs/common';

export const ACCOUNT_TYPES = ['SUPER_ADMIN', 'ADMIN', 'EMPLOYEE'] as const;
export type AccountType = (typeof ACCOUNT_TYPES)[number];

export const PERMISSIONS = [
  'content.manage',
  'employees.manage',
  'accounts.manage',
  'logs.view',
] as const;
export type Permission = (typeof PERMISSIONS)[number];

export type AuthUser = {
  sub?: string;
  employeeCode?: string;
  role?: string;
  accountType?: string;
  permissions?: string[];
};

export function isSuperAdmin(user: AuthUser) {
  return user.accountType === 'SUPER_ADMIN' || user.employeeCode === 'admin';
}

export function hasPermission(user: AuthUser, permission: Permission) {
  return isSuperAdmin(user) || user.permissions?.includes(permission) === true;
}

export function assertPermission(user: AuthUser, permission: Permission) {
  if (!hasPermission(user, permission)) {
    throw new ForbiddenException(`Missing permission: ${permission}`);
  }
}

export function normalizePermissions(values?: string[]) {
  return [...new Set((values ?? []).filter((value): value is Permission =>
    PERMISSIONS.includes(value as Permission),
  ))];
}
