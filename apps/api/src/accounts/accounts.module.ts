import { Module } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { AccountsController } from './accounts.controller';
import { AccountsService } from './accounts.service';
import { AuthModule } from '../auth/auth.module';
import { DashboardModule } from '../dashboard/dashboard.module';

@Module({
  imports: [AuthModule, DashboardModule],
  controllers: [AccountsController],
  providers: [AccountsService, PrismaService],
})
export class AccountsModule {}
