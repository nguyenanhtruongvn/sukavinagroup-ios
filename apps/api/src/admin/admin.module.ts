import { Module } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { AdminContentController } from './admin-content.controller';
import { AdminContentService } from './admin-content.service';
import { DashboardModule } from '../dashboard/dashboard.module';

@Module({
  imports: [DashboardModule],
  controllers: [AdminContentController],
  providers: [AdminContentService, PrismaService],
})
export class AdminModule {}
