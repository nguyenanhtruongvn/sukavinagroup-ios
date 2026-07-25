import {
  ConflictException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { hash } from 'bcryptjs';
import { PrismaService } from '../prisma/prisma.service';
import { assertPermission, AuthUser } from '../auth/permissions';
import { ContentEventsService } from '../dashboard/content-events.service';

@Injectable()
export class EmployeesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly contentEvents: ContentEventsService,
  ) {}

  list(user: AuthUser) {
    assertPermission(user, 'employees.manage');
    return this.prisma.employee.findMany({ orderBy: { createdAt: 'desc' } });
  }

  async create(
    user: AuthUser,
    data: {
      employeeCode: string;
      fullName: string;
      jobTitle: string;
      department: string;
      managerEmployeeCode?: string | null;
      hireDate?: string | null;
      contractType?: string | null;
      phoneNumber?: string | null;
      gmailEmail?: string | null;
      password?: string | null;
      authProvider: string;
      remainingLeaveDays?: number;
      attendanceStatus?: string;
      payrollStatus?: string;
      active?: boolean;
    },
  ) {
    assertPermission(user, 'employees.manage');
    const passwordHash = data.password ? await hash(data.password, 10) : null;
    const { hireDate } = data;
    const employeeData = { ...data };
    delete employeeData.password;
    delete employeeData.hireDate;
    const employee = await this.prisma.employee
      .create({
        data: {
          ...employeeData,
          managerEmployeeCode: data.managerEmployeeCode?.trim() || null,
          hireDate: hireDate ? new Date(`${hireDate}T00:00:00.000Z`) : null,
          contractType: data.contractType?.trim() || null,
          phoneNumber: data.phoneNumber?.trim() || null,
          gmailEmail: data.gmailEmail?.trim().toLowerCase() || null,
          gmailVerified: true,
          emailVerificationCode: null,
          emailVerificationExpiresAt: null,
          passwordHash,
        },
      })
      .catch((error: unknown) => this.rethrowEmployeeWriteError(error));
    this.contentEvents.notify('employee_changed');
    return employee;
  }

  async update(
    user: AuthUser,
    id: string,
    data: Partial<{
      employeeCode: string;
      fullName: string;
      jobTitle: string;
      department: string;
      managerEmployeeCode: string | null;
      hireDate: string | null;
      contractType: string | null;
      phoneNumber: string | null;
      gmailEmail: string | null;
      password: string | null;
      authProvider: string;
      remainingLeaveDays: number;
      attendanceStatus: string;
      payrollStatus: string;
      active: boolean;
    }>,
  ) {
    assertPermission(user, 'employees.manage');
    const existing = await this.prisma.employee.findUnique({ where: { id } });
    if (!existing) throw new NotFoundException('Employee not found');
    const passwordHash = data.password ? await hash(data.password, 10) : undefined;
    const { hireDate } = data;
    const rest = { ...data };
    delete rest.password;
    delete rest.hireDate;
    const employee = await this.prisma.employee
      .update({
        where: { id },
        data: {
          ...rest,
          managerEmployeeCode:
            rest.managerEmployeeCode === undefined
              ? undefined
              : rest.managerEmployeeCode?.trim() || null,
          hireDate:
            hireDate === undefined
              ? undefined
              : hireDate
                ? new Date(`${hireDate}T00:00:00.000Z`)
                : null,
          contractType:
            rest.contractType === undefined ? undefined : rest.contractType?.trim() || null,
          phoneNumber:
            rest.phoneNumber === undefined ? undefined : rest.phoneNumber?.trim() || null,
          gmailEmail:
            rest.gmailEmail === undefined
              ? undefined
              : rest.gmailEmail?.trim().toLowerCase() || null,
          gmailVerified: true,
          emailVerificationCode: null,
          emailVerificationExpiresAt: null,
          ...(passwordHash ? { passwordHash } : {}),
        },
      })
      .catch((error: unknown) => this.rethrowEmployeeWriteError(error));
    this.contentEvents.notify('employee_changed');
    return employee;
  }

  async remove(user: AuthUser, id: string) {
    assertPermission(user, 'employees.manage');
    const existing = await this.prisma.employee.findUnique({ where: { id } });
    if (!existing) throw new NotFoundException('Employee not found');
    if (existing.protected || existing.accountType === 'SUPER_ADMIN') {
      throw new ForbiddenException('Super admin cannot be deleted');
    }
    const employee = await this.prisma.employee.delete({ where: { id } });
    this.contentEvents.notify('employee_changed');
    return employee;
  }

  private rethrowEmployeeWriteError(error: unknown): never {
    const prismaError = error as { code?: string; meta?: { target?: string[] } };
    if (prismaError?.code === 'P2002') {
      const target = prismaError.meta?.target ?? [];
      if (target.includes('employeeCode')) {
        throw new ConflictException('Mã nhân viên đã tồn tại');
      }
      if (target.includes('phoneNumber')) {
        throw new ConflictException('Số điện thoại đã được sử dụng');
      }
      if (target.includes('gmailEmail')) {
        throw new ConflictException('Gmail đã được sử dụng');
      }
      throw new ConflictException('Thông tin nhân viên đã tồn tại');
    }
    throw error;
  }
}
