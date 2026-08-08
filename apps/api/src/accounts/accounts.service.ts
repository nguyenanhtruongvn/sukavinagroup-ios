import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import {
  assertPermission,
  AuthUser,
  normalizePermissions,
} from '../auth/permissions';
import { RegistrationEventsService } from '../auth/registration-events.service';
import { MailService } from '../auth/mail.service';
import { ContentEventsService } from '../dashboard/content-events.service';

@Injectable()
export class AccountsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly registrationEvents: RegistrationEventsService,
    private readonly mailService: MailService,
    private readonly contentEvents: ContentEventsService,
  ) {}

  list(user: AuthUser) {
    assertPermission(user, 'accounts.manage');
    return this.prisma.employee.findMany({
      select: {
        id: true,
        employeeCode: true,
        fullName: true,
        jobTitle: true,
        department: true,
        active: true,
        gmailVerified: true,
        accountType: true,
        permissions: true,
        protected: true,
        createdAt: true,
      },
      orderBy: [{ accountType: 'asc' }, { createdAt: 'asc' }],
    });
  }

  async update(
    user: AuthUser,
    id: string,
    data: {
      accountType: 'ADMIN' | 'EMPLOYEE' | 'CANTEEN';
      permissions?: string[];
      active?: boolean;
    },
  ) {
    assertPermission(user, 'accounts.manage');
    const existing = await this.prisma.employee.findUnique({ where: { id } });
    if (!existing) throw new NotFoundException('Account not found');
    if (existing.protected || existing.accountType === 'SUPER_ADMIN') {
      throw new ForbiddenException('Super admin permissions are protected');
    }
    if (user.sub === id && data.accountType !== 'ADMIN') {
      throw new ForbiddenException('You cannot remove your own admin access');
    }
    if (data.active === true && !existing.gmailVerified) {
      throw new BadRequestException('Tài khoản chưa xác minh Gmail');
    }

    const accountType = data.accountType === 'ADMIN'
      ? 'ADMIN'
      : data.accountType === 'CANTEEN' ? 'CANTEEN' : 'EMPLOYEE';
    const updated = await this.prisma.employee.update({
      where: { id },
      data: {
        accountType,
        permissions:
          accountType === 'ADMIN' ? normalizePermissions(data.permissions) : [],
        role: accountType === 'ADMIN'
          ? 'Quản trị viên'
          : accountType === 'CANTEEN' ? 'Nhà ăn' : existing.jobTitle,
        active: typeof data.active === 'boolean' ? data.active : existing.active,
      },
      select: {
        id: true,
        employeeCode: true,
        fullName: true,
        jobTitle: true,
        department: true,
        active: true,
        gmailVerified: true,
        accountType: true,
        permissions: true,
        protected: true,
      },
    });
    this.registrationEvents.notify();
    this.contentEvents.notify('employee_changed');
    if (
      !existing.active &&
      updated.active &&
      existing.gmailVerified &&
      existing.gmailEmail
    ) {
      await this.mailService.sendAccountApproved(
        existing.gmailEmail,
        existing.employeeCode,
      );
    }
    return updated;
  }
}
