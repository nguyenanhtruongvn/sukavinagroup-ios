import { Module } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { EmployeesController } from './employees.controller';
import { EmployeesService } from './employees.service';
import { DashboardModule } from '../dashboard/dashboard.module';

@Module({
  imports: [DashboardModule],
  controllers: [EmployeesController],
  providers: [EmployeesService, PrismaService],
})
export class EmployeesModule {}
