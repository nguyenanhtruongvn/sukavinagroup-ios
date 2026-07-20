import { Module } from '@nestjs/common';
import { DashboardModule } from '../dashboard/dashboard.module';
import { PrismaService } from '../prisma/prisma.service';
import { RequestsController } from './requests.controller';
import { RequestsService } from './requests.service';

@Module({
  imports: [DashboardModule],
  controllers: [RequestsController],
  providers: [RequestsService, PrismaService],
})
export class RequestsModule {}
