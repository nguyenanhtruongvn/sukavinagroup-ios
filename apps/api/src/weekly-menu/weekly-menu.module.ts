import { Module } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { EmployeeWeeklyMenuController, WeeklyMenuController } from './weekly-menu.controller';
import { WeeklyMenuService } from './weekly-menu.service';

@Module({
  controllers: [WeeklyMenuController, EmployeeWeeklyMenuController],
  providers: [WeeklyMenuService, PrismaService],
})
export class WeeklyMenuModule {}
