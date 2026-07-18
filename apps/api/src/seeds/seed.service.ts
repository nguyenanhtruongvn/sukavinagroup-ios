import { Injectable, OnModuleInit } from '@nestjs/common';
import { hash } from 'bcryptjs';
import { PrismaService } from '../prisma/prisma.service';

@Injectable()
export class SeedService implements OnModuleInit {
  constructor(private readonly prisma: PrismaService) {}

  async onModuleInit() {
const seeds = [
  {
        employeeCode: 'admin',
        fullName: 'Quản trị hệ thống',
        jobTitle: 'Quản trị viên',
        department: 'IT',
        password: 'w2UMweSPYCox.lsc',
        authProvider: 'phone_password',
        phoneNumber: '0900000000',
        remainingLeaveDays: 0,
        attendanceStatus: 'Khu quản trị không hiển thị bảng công nhân viên',
        payrollStatus: 'Khu quản trị không hiển thị bảng lương nhân viên',
      },
    ] as const;

    for (const seed of seeds) {
      const existing = await this.prisma.employee.findUnique({
        where: { employeeCode: seed.employeeCode },
      });

      if (existing) {
        await this.prisma.employee.update({
          where: { employeeCode: seed.employeeCode },
          data: {
            fullName: seed.fullName,
            jobTitle: seed.jobTitle,
            department: seed.department,
            passwordHash: await hash(seed.password, 10),
            phoneNumber: seed.phoneNumber,
            authProvider: seed.authProvider,
            role: seed.employeeCode === 'admin' ? 'Quản trị viên' : seed.jobTitle,
            accountType: seed.employeeCode === 'admin' ? 'SUPER_ADMIN' : 'EMPLOYEE',
            permissions: [],
            protected: seed.employeeCode === 'admin',
            gmailVerified: true,
            remainingLeaveDays: seed.remainingLeaveDays,
            attendanceStatus: seed.attendanceStatus,
            payrollStatus: seed.payrollStatus,
          },
        });
        continue;
      }

      await this.prisma.employee.create({
        data: {
          employeeCode: seed.employeeCode,
          fullName: seed.fullName,
          jobTitle: seed.jobTitle,
          department: seed.department,
          passwordHash: await hash(seed.password, 10),
          phoneNumber: seed.phoneNumber,
          authProvider: seed.authProvider,
          role: seed.employeeCode === 'admin' ? 'Quản trị viên' : seed.jobTitle,
          accountType: seed.employeeCode === 'admin' ? 'SUPER_ADMIN' : 'EMPLOYEE',
          permissions: [],
          protected: seed.employeeCode === 'admin',
          gmailVerified: true,
          remainingLeaveDays: seed.remainingLeaveDays,
          attendanceStatus: seed.attendanceStatus,
          payrollStatus: seed.payrollStatus,
        },
      });
    }

    const contentSeeds = [
      {
        page: 'employee',
        key: 'hero',
        title: 'Thông tin nội bộ',
        body: 'Theo dõi ngày phép, bảng công và bảng lương ngay trên cổng nhân viên.',
        sortOrder: 1,
      },
      {
        page: 'employee',
        key: 'leave-card',
        title: 'Ngày phép còn lại',
        body: 'Dữ liệu này được quản trị viên chỉnh từ khu admin.',
        sortOrder: 2,
      },
      {
        page: 'employee',
        key: 'attendance-card',
        title: 'Bảng công',
        body: 'Thông báo trạng thái chấm công theo tháng.',
        sortOrder: 3,
      },
      {
        page: 'employee',
        key: 'payroll-card',
        title: 'Bảng lương',
        body: 'Thông báo trạng thái phát hành lương.',
        sortOrder: 4,
      },
    ] as const;

    for (const seed of contentSeeds) {
      await this.prisma.contentItem.upsert({
        where: {
          page_key: {
            page: seed.page,
            key: seed.key,
          },
        },
        update: {
          title: seed.title,
          body: seed.body,
          sortOrder: seed.sortOrder,
          published: true,
        },
        create: {
          page: seed.page,
          key: seed.key,
          title: seed.title,
          body: seed.body,
          sortOrder: seed.sortOrder,
          published: true,
        },
      });
    }
  }
}
