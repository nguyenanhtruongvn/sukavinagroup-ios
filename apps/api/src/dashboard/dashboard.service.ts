import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';

@Injectable()
export class DashboardService {
  constructor(private readonly prisma: PrismaService) {}

  async getPublicNews() {
    return this.prisma.contentItem.findMany({
      where: { page: 'employee', published: true },
      orderBy: [{ sortOrder: 'asc' }, { createdAt: 'desc' }],
      select: {
        id: true,
        page: true,
        key: true,
        title: true,
        body: true,
        sortOrder: true,
        published: true,
        createdAt: true,
      },
    });
  }

  async getDashboard(userId: string) {
    const user = await this.prisma.employee.findUnique({
      where: { id: userId },
      select: {
        employeeCode: true,
        fullName: true,
        role: true,
        remainingLeaveDays: true,
        attendanceStatus: true,
        payrollStatus: true,
      },
    });

    if (!user) {
      throw new NotFoundException('User not found');
    }

    const normalizedEmployeeCode = user.employeeCode.replace(/^0+(?=\d)/, '');
    const attendanceCodes = [...new Set([user.employeeCode, normalizedEmployeeCode])];
    const [contentItems, attendanceRecords] = await Promise.all([
      this.getPublicNews(),
      this.prisma.attendanceRecord.findMany({
        where: {
          userEnrollNumber: { in: attendanceCodes },
          attendanceDate: this.getVietnamDate(),
        },
        orderBy: { punchedAt: 'desc' },
        take: 100,
        select: {
          id: true,
          punchedAt: true,
          source: true,
          originType: true,
          machineNo: true,
        },
      }),
    ]);

    const latestPunch = attendanceRecords[0];
    const attendanceStatus = latestPunch
      ? `Đã chấm công lúc ${latestPunch.punchedAt.toLocaleTimeString('vi-VN', {
          timeZone: 'Asia/Ho_Chi_Minh',
          hour: '2-digit',
          minute: '2-digit',
        })}`
      : user.attendanceStatus || 'Chưa có dữ liệu chấm công hôm nay';

    return {
      ...user,
      name: user.fullName,
      attendanceStatus,
      attendanceRecords,
      contentItems,
    };
  }

  async getWidgetAttendance(userId: string) {
    const dashboard = await this.getDashboard(userId);
    return {
      attendanceStatus: dashboard.attendanceStatus,
      attendanceRecords: dashboard.attendanceRecords,
      updatedAt: new Date().toISOString(),
    };
  }

  private getVietnamDate() {
    return new Intl.DateTimeFormat('en-CA', {
      timeZone: 'Asia/Ho_Chi_Minh',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
    }).format(new Date());
  }

  async getMonthlyAttendance(userId: string, requestedMonth?: string) {
    const user = await this.prisma.employee.findUnique({
      where: { id: userId },
      select: { employeeCode: true, department: true, hireDate: true },
    });
    if (!user) throw new NotFoundException('User not found');

    const month = requestedMonth || this.getVietnamDate().slice(0, 7);
    if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(month)) {
      throw new BadRequestException('Tháng không hợp lệ');
    }
    if (!this.getAllowedAttendanceMonths().includes(month)) {
      throw new BadRequestException('Chỉ được xem chấm công tháng hiện tại và tháng trước');
    }

    const normalizedCode = user.employeeCode.replace(/^0+(?=\d)/, '');
    const [records, schedule, approvedLeaves] = await Promise.all([
      this.prisma.attendanceRecord.findMany({
        where: {
          userEnrollNumber: { in: [...new Set([user.employeeCode, normalizedCode])] },
          attendanceDate: { startsWith: month },
        },
        orderBy: { punchedAt: 'asc' },
        select: {
          id: true, attendanceDate: true, punchedAt: true, source: true, machineNo: true,
        },
      }),
      this.prisma.departmentWorkSchedule.findUnique({ where: { department: user.department } }),
      this.prisma.employeeRequest.findMany({
        where: {
          employeeId: userId,
          kind: 'leave',
          status: 'approved',
          startsAt: { lt: new Date(`${month}-31T17:00:00.000Z`) },
          endsAt: { gte: new Date(`${month}-01T00:00:00.000Z`) },
        },
        select: { startsAt: true, endsAt: true },
      }),
    ]);

    const grouped = new Map<string, typeof records>();
    for (const record of records) {
      const day = grouped.get(record.attendanceDate) ?? [];
      day.push(record);
      grouped.set(record.attendanceDate, day);
    }

    const [year, monthNumber] = month.split('-').map(Number);
    const dayCount = new Date(Date.UTC(year, monthNumber, 0)).getUTCDate();
    const today = this.getVietnamDate();
    const startTime = schedule?.startTime ?? '07:30';
    const endTime = schedule?.endTime ?? '16:30';
    const leaveDates = new Set<string>();
    for (const leave of approvedLeaves) {
      const cursor = new Date(leave.startsAt);
      const end = new Date(leave.endsAt);
      while (cursor <= end) {
        leaveDates.add(new Intl.DateTimeFormat('en-CA', {
          timeZone: 'Asia/Ho_Chi_Minh', year: 'numeric', month: '2-digit', day: '2-digit',
        }).format(cursor));
        cursor.setUTCDate(cursor.getUTCDate() + 1);
      }
    }
    const days = Array.from({ length: dayCount }, (_, index) => {
      const date = `${month}-${String(index + 1).padStart(2, '0')}`;
      const punches = grouped.get(date) ?? [];
      // Noon UTC stays on the same calendar date in Vietnam and avoids a previous-day shift.
      const weekDay = new Date(`${date}T12:00:00.000Z`).getUTCDay();
      const isSunday = weekDay === 0;
      const isFuture = date > today;
      const isBeforeHireDate = user.hireDate
        ? date < user.hireDate.toISOString().slice(0, 10)
        : false;
      const isLeave = leaveDates.has(date);
      const checkIn = punches[0]?.punchedAt ?? null;
      const checkOut = punches.length > 1 ? punches[punches.length - 1].punchedAt : null;
      const checkInTime = checkIn?.toLocaleTimeString('en-GB', {
        timeZone: 'Asia/Ho_Chi_Minh', hour: '2-digit', minute: '2-digit', hour12: false,
      });
      const checkOutTime = checkOut?.toLocaleTimeString('en-GB', {
        timeZone: 'Asia/Ho_Chi_Minh', hour: '2-digit', minute: '2-digit', hour12: false,
      });
      let statuses: string[];
      if (isSunday) {
        statuses = punches.length ? ['overtime'] : ['weekend'];
      } else if (isLeave) {
        statuses = ['leave'];
      } else if (!punches.length) {
        if (isFuture) {
          statuses = ['upcoming'];
        } else if (isBeforeHireDate) {
          statuses = ['not-started'];
        } else {
          statuses = ['absent'];
        }
      } else {
        statuses = [];
        if (checkInTime! > startTime) statuses.push('late');
        if (checkOutTime && checkOutTime < endTime) statuses.push('early');
        if (!statuses.length) statuses.push('present');
      }
      const status = statuses[0];
      return {
        date,
        checkIn,
        checkOut,
        punchCount: punches.length,
        status,
        statuses,
        startTime,
        endTime,
        sources: [...new Set(punches.map((record) => record.source))],
        punches: punches.map((record) => ({
          id: record.id,
          punchedAt: record.punchedAt,
          source: record.source,
          machineNo: record.machineNo,
        })),
      };
    });

    return { month, startTime, endTime, department: user.department, days };
  }

  private getAllowedAttendanceMonths() {
    const currentMonth = this.getVietnamDate().slice(0, 7);
    const [year, month] = currentMonth.split('-').map(Number);
    const previous = new Date(Date.UTC(year, month - 2, 1));
    const previousMonth = `${previous.getUTCFullYear()}-${String(previous.getUTCMonth() + 1).padStart(2, '0')}`;
    return [currentMonth, previousMonth];
  }
}
