import { Module } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { LogsService } from './logs.service';

@Module({
  controllers: [],
  providers: [LogsService, PrismaService],
  exports: [LogsService],
})
export class LogsModule {}
