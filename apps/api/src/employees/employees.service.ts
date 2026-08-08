import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { hash } from 'bcryptjs';
import * as ExcelJS from 'exceljs';
import { PrismaService } from '../prisma/prisma.service';
import { assertPermission, AuthUser } from '../auth/permissions';
import { ContentEventsService } from '../dashboard/content-events.service';

type ImportedEmployee = {
  row: number;
  employeeCode: string;
  fullName: string;
  department: string;
  birthDate: Date | null;
  managerFullName: string | null;
  managerEmployeeCode: string | null;
  jobTitle: string;
  hireDate: Date | null;
  contractType: string | null;
  gmailEmail: string | null;
  phoneNumber: string | null;
};

const REQUIRED_IMPORT_HEADERS = [
  'msnv',
  'họ và tên',
  'phòng ban',
  'ngày tháng năm sinh',
  'ngày vào công ty (chính thức)',
  'loại hợp đồng',
  'chức danh',
  'quản lý trực tiếp',
  'msnv quản lý trực tiếp',
  'email',
  'số điện thoại',
];

const normalizeHeader = (value: string) =>
  value
    .trim()
    .toLocaleLowerCase('vi')
    .replace(/\s+/g, ' ');

const parseImportDate = (cell: ExcelJS.Cell, row: number) => {
  if (cell.value === null || cell.value === undefined || cell.text.trim() === '') return null;
  if (cell.value instanceof Date && !Number.isNaN(cell.value.getTime())) {
    return new Date(Date.UTC(cell.value.getFullYear(), cell.value.getMonth(), cell.value.getDate()));
  }

  const value = cell.text.trim();
  const match = value.match(/^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$/);
  const isoMatch = value.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/);
  const day = match ? Number(match[1]) : isoMatch ? Number(isoMatch[3]) : 0;
  const month = match ? Number(match[2]) : isoMatch ? Number(isoMatch[2]) : 0;
  const year = match ? Number(match[3]) : isoMatch ? Number(isoMatch[1]) : 0;
  const result = new Date(Date.UTC(year, month - 1, day));
  if (
    !year ||
    result.getUTCFullYear() !== year ||
    result.getUTCMonth() !== month - 1 ||
    result.getUTCDate() !== day
  ) {
    throw new BadRequestException(
      `Dòng ${row}: Ngày vào làm phải có định dạng dd/mm/yyyy hoặc yyyy-mm-dd.`,
    );
  }
  return result;
};

export async function parseEmployeeWorkbook(buffer: Buffer): Promise<ImportedEmployee[]> {
  const workbook = new ExcelJS.Workbook();
  try {
    await workbook.xlsx.load(buffer as unknown as ExcelJS.Buffer);
  } catch {
    throw new BadRequestException('File Excel không hợp lệ hoặc đã bị hỏng.');
  }

  const sheet = workbook.worksheets[0];
  if (!sheet) throw new BadRequestException('File Excel không có trang dữ liệu.');

  const headers = REQUIRED_IMPORT_HEADERS.map((_, index) =>
    normalizeHeader(sheet.getCell(1, index + 1).text),
  );
  const invalidHeader = REQUIRED_IMPORT_HEADERS.findIndex(
    (header, index) => headers[index] !== header,
  );
  if (invalidHeader >= 0) {
    throw new BadRequestException(
      `Cột ${invalidHeader + 1} phải là "${REQUIRED_IMPORT_HEADERS[invalidHeader]}".`,
    );
  }

  const employees: ImportedEmployee[] = [];
  for (let row = 2; row <= sheet.rowCount; row += 1) {
    const values = Array.from({ length: 11 }, (_, index) =>
      sheet.getCell(row, index + 1).text.trim(),
    );
    if (values.every((value) => !value)) continue;

    const [employeeCode, fullName, department, , , contractType, jobTitle, managerFullName, managerCode, email, phone] = values;
    if (!employeeCode || !fullName || !department || !jobTitle) {
      throw new BadRequestException(
        `Dòng ${row}: MSNV, họ và tên, phòng ban và chức danh là bắt buộc.`,
      );
    }
    employees.push({
      row,
      employeeCode,
      fullName,
      department,
      birthDate: parseImportDate(sheet.getCell(row, 4), row),
      managerFullName: managerFullName || null,
      managerEmployeeCode: managerCode || null,
      jobTitle,
      hireDate: parseImportDate(sheet.getCell(row, 5), row),
      contractType: contractType || null,
      gmailEmail: email ? email.toLocaleLowerCase('vi') : null,
      phoneNumber: phone || null,
    });
  }

  if (!employees.length) throw new BadRequestException('File Excel chưa có nhân viên để nhập.');
  return employees;
}

@Injectable()
export class EmployeesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly contentEvents: ContentEventsService,
  ) {}

  async listWorkSchedules(user: AuthUser) {
    assertPermission(user, 'employees.manage');
    const [employees, schedules] = await Promise.all([
      this.prisma.employee.findMany({
        distinct: ['department'],
        select: { department: true },
        orderBy: { department: 'asc' },
      }),
      this.prisma.departmentWorkSchedule.findMany({ orderBy: { department: 'asc' } }),
    ]);
    const configured = new Map(schedules.map((item) => [item.department, item]));
    return employees
      .filter((item) => item.department.trim())
      .map((item) => configured.get(item.department) ?? {
        id: '',
        department: item.department,
        startTime: '07:30',
        endTime: '16:30',
      });
  }

  async saveWorkSchedule(user: AuthUser, data: { department: string; startTime: string; endTime: string }) {
    assertPermission(user, 'employees.manage');
    const department = data.department?.trim();
    if (!department) throw new BadRequestException('Phòng ban không hợp lệ');
    if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(data.startTime)) {
      throw new BadRequestException('Giờ vào làm không hợp lệ');
    }
    if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(data.endTime)) {
      throw new BadRequestException('Giờ ra về không hợp lệ');
    }
    if (data.endTime <= data.startTime) {
      throw new BadRequestException('Giờ ra về phải sau giờ vào làm');
    }
    const schedule = await this.prisma.departmentWorkSchedule.upsert({
      where: { department },
      create: { department, startTime: data.startTime, endTime: data.endTime },
      update: { startTime: data.startTime, endTime: data.endTime },
    });
    this.contentEvents.notify('employee_changed');
    return schedule;
  }

  list(user: AuthUser) {
    assertPermission(user, 'employees.manage');
    return this.prisma.employee.findMany({ orderBy: { createdAt: 'desc' } });
  }

  async import(user: AuthUser, file?: Express.Multer.File) {
    assertPermission(user, 'employees.manage');
    if (!file) throw new BadRequestException('Vui lòng chọn file Excel.');
    if (!file.originalname.toLocaleLowerCase('vi').endsWith('.xlsx')) {
      throw new BadRequestException('Chỉ hỗ trợ file Excel định dạng .xlsx.');
    }

    const rows = await parseEmployeeWorkbook(file.buffer);
    const seenCodes = new Set<string>();
    for (const employee of rows) {
      const codeKey = employee.employeeCode.toLocaleLowerCase('vi');
      if (seenCodes.has(codeKey)) {
        throw new BadRequestException(`Dòng ${employee.row}: MSNV bị trùng trong file.`);
      }
      seenCodes.add(codeKey);
    }

    const existing = await this.prisma.employee.findMany({
      where: {
        employeeCode: { in: rows.map((item) => item.employeeCode) },
      },
      select: { employeeCode: true },
    });
    const existingCodes = new Set(existing.map((item) => item.employeeCode.toLocaleLowerCase('vi')));
    const newRows = rows.filter(
      (item) => !existingCodes.has(item.employeeCode.toLocaleLowerCase('vi')),
    );

    if (newRows.length) {
      const passwordHash = await hash('123456', 10);
      await this.prisma.employee.createMany({
        data: newRows.map(({ row: _row, ...employee }) => ({
          ...employee,
          passwordHash,
          authProvider: 'phone_password',
          role: employee.jobTitle,
          accountType: 'EMPLOYEE',
          gmailVerified: true,
          active: true,
        })),
      });
      this.contentEvents.notify('employee_changed');
    }

    return {
      imported: newRows.length,
      skipped: rows.length - newRows.length,
      total: rows.length,
      defaultPassword: '123456',
    };
  }

  async create(
    user: AuthUser,
    data: {
      employeeCode: string;
      fullName: string;
      jobTitle: string;
      department: string;
      birthDate?: string | null;
      managerFullName?: string | null;
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
    const passwordHash = await hash(data.password?.trim() || '123456', 10);
    const { hireDate } = data;
    const employeeData = { ...data };
    delete employeeData.password;
    delete employeeData.hireDate;
    const employee = await this.prisma.employee
      .create({
        data: {
          ...employeeData,
          birthDate: data.birthDate ? new Date(`${data.birthDate}T00:00:00.000Z`) : null,
          managerFullName: data.managerFullName?.trim() || null,
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
      birthDate: string | null;
      managerFullName: string | null;
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
          birthDate:
            rest.birthDate === undefined
              ? undefined
              : rest.birthDate
                ? new Date(`${rest.birthDate}T00:00:00.000Z`)
                : null,
          managerFullName:
            rest.managerFullName === undefined
              ? undefined
              : rest.managerFullName?.trim() || null,
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
      throw new ConflictException('Thông tin nhân viên đã tồn tại');
    }
    throw error;
  }
}
