import { Module } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { DashboardController } from './dashboard.controller';
import { DashboardService } from './dashboard.service';
import { ContentEventsService } from './content-events.service';
import { AttendanceSyncService } from './attendance-sync.service';
import { AuthModule } from '../auth/auth.module';

@Module({
  imports: [AuthModule],
  controllers: [DashboardController],
  providers: [DashboardService, ContentEventsService, PrismaService, AttendanceSyncService],
  exports: [ContentEventsService],
})
export class DashboardModule {}
