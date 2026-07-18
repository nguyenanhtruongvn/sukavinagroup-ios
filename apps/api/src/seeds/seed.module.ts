import { Module } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { SeedService } from './seed.service';

@Module({
  providers: [SeedService, PrismaService],
})
export class SeedModule {}
