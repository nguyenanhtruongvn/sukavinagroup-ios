import { Module } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { LogsController } from './logs.controller';
import { LogsService } from './logs.service';

@Module({
  controllers: [LogsController],
  providers: [LogsService, PrismaService],
  exports: [LogsService],
})
export class LogsModule {}
