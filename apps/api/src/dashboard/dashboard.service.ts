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
      select: { employeeCode: true },
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
    const records = await this.prisma.attendanceRecord.findMany({
      where: {
        userEnrollNumber: { in: [...new Set([user.employeeCode, normalizedCode])] },
        attendanceDate: { startsWith: month },
      },
      orderBy: { punchedAt: 'asc' },
      select: {
        attendanceDate: true,
        punchedAt: true,
      },
    });

    const grouped = new Map<string, typeof records>();
    for (const record of records) {
      const day = grouped.get(record.attendanceDate) ?? [];
      day.push(record);
      grouped.set(record.attendanceDate, day);
    }

    const days = [...grouped.entries()]
      .map(([date, punches]) => ({
        date,
        checkIn: punches[0]?.punchedAt ?? null,
        checkOut: punches.length > 1 ? punches[punches.length - 1].punchedAt : null,
        punchCount: punches.length,
      }))
      .sort((left, right) => right.date.localeCompare(left.date));

    return { month, days };
  }

  private getAllowedAttendanceMonths() {
    const currentMonth = this.getVietnamDate().slice(0, 7);
    const [year, month] = currentMonth.split('-').map(Number);
    const previous = new Date(Date.UTC(year, month - 2, 1));
    const previousMonth = `${previous.getUTCFullYear()}-${String(previous.getUTCMonth() + 1).padStart(2, '0')}`;
    return [currentMonth, previousMonth];
  }
}
